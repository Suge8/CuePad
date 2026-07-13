#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("DISPATCH_UNSUPPORTED_PLATFORM");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
mod macos {
    use block2::RcBlock;
    use core_graphics::{
        event::{CGEvent, CGEventFlags, KeyCode},
        event_source::{CGEventSource, CGEventSourceStateID},
    };
    use objc2_app_kit::{
        NSApplicationActivationOptions, NSApplicationActivationPolicy, NSRunningApplication,
        NSWorkspace, NSWorkspaceApplicationKey, NSWorkspaceDidActivateApplicationNotification,
    };
    use objc2_foundation::{
        NSDefaultRunLoopMode, NSNotification, NSPort, NSRunLoop, NSString, NSTimer,
    };
    use serde::{Deserialize, Serialize};
    use serde_json::Value;
    use std::{
        collections::HashSet,
        ffi::c_void,
        io::{self, BufRead, Write},
        ptr::NonNull,
        sync::{Arc, Mutex},
    };

    const ACCESSIBILITY_REQUIRED: &str = "ACCESSIBILITY_PERMISSION_REQUIRED";
    const ACTIVATION_TIMEOUT_SECONDS: f64 = 2.0;
    const NO_TARGET: &str = "NO_DISPATCH_TARGET";
    const PASTE_SETTLE_SECONDS: f64 = 0.1;
    const TARGET_UNAVAILABLE: &str = "DISPATCH_TARGET_UNAVAILABLE";

    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct DispatchApp {
        bundle_id: Option<String>,
        name: String,
    }

    #[derive(Clone)]
    struct TargetApp {
        pid: i32,
        bundle_id: Option<String>,
        name: String,
    }

    struct PreparedDispatch {
        selector: Option<String>,
        target: TargetApp,
        key_down: CGEvent,
        key_up: CGEvent,
    }

    struct PendingDispatch {
        request_id: u64,
        target_pid: i32,
        key_down: CGEvent,
        key_up: CGEvent,
    }

    #[derive(Clone, Default)]
    struct Exclusions {
        pid: Option<i32>,
        bundle_id: Option<String>,
    }

    #[derive(Clone, Default)]
    struct DispatchState {
        target: Arc<Mutex<Option<TargetApp>>>,
        exclusions: Exclusions,
    }

    thread_local! {
        static PREPARED_DISPATCH: std::cell::RefCell<Option<PreparedDispatch>> = const { std::cell::RefCell::new(None) };
        static PENDING_DISPATCH: std::cell::RefCell<Option<PendingDispatch>> = const { std::cell::RefCell::new(None) };
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Request {
        id: u64,
        cmd: String,
        bundle_id: Option<String>,
        #[serde(default)]
        prepare: bool,
    }

    #[derive(Serialize)]
    struct Response {
        id: u64,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        data: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn AXIsProcessTrusted() -> u8;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRunLoopGetMain() -> *const c_void;
        fn CFRunLoopRun();
        fn CFRunLoopStop(run_loop: *const c_void);
        fn CFRunLoopWakeUp(run_loop: *const c_void);
    }

    pub fn run() -> Result<(), String> {
        let state = DispatchState {
            exclusions: parse_exclusions()?,
            ..DispatchState::default()
        };
        setup(&state);

        let reader_state = state.clone();
        let reader = std::thread::spawn(move || read_requests(reader_state));
        let run_loop = NSRunLoop::mainRunLoop();
        let keep_alive = NSPort::port();
        unsafe {
            run_loop.addPort_forMode(&keep_alive, NSDefaultRunLoopMode);
            CFRunLoopRun();
        }
        keep_alive.invalidate();
        reader
            .join()
            .map_err(|_| "dispatch stdin reader panicked".to_string())
    }

    fn parse_exclusions() -> Result<Exclusions, String> {
        let mut exclusions = Exclusions::default();
        let mut arguments = std::env::args().skip(1);
        while let Some(argument) = arguments.next() {
            let value = arguments
                .next()
                .ok_or_else(|| format!("missing value for {argument}"))?;
            match argument.as_str() {
                "--exclude-pid" => {
                    exclusions.pid = Some(
                        value
                            .parse::<i32>()
                            .map_err(|_| format!("invalid pid: {value}"))?,
                    );
                }
                "--exclude-bundle-id" => exclusions.bundle_id = Some(value),
                _ => return Err(format!("unknown argument: {argument}")),
            }
        }
        Ok(exclusions)
    }

    fn setup(state: &DispatchState) {
        record_frontmost(state);
        let state = state.clone();
        let block = RcBlock::new(move |notification: NonNull<NSNotification>| {
            let notification = unsafe { notification.as_ref() };
            let Some(user_info) = notification.userInfo() else {
                return;
            };
            let Some(object) = user_info.objectForKey(unsafe { NSWorkspaceApplicationKey }) else {
                return;
            };
            let Ok(application) = object.downcast::<NSRunningApplication>() else {
                return;
            };
            record_application(&state, &application);
        });
        let workspace = NSWorkspace::sharedWorkspace();
        let observer = unsafe {
            workspace
                .notificationCenter()
                .addObserverForName_object_queue_usingBlock(
                    Some(NSWorkspaceDidActivateApplicationNotification),
                    None,
                    None,
                    &block,
                )
        };
        std::mem::forget(observer);
    }

    fn read_requests(state: DispatchState) {
        for line in io::stdin().lock().lines() {
            match line {
                Ok(line) => schedule_request(&state, line),
                Err(error) => {
                    eprintln!("cuepad-dispatch stdin error: {error}");
                    break;
                }
            }
        }
        schedule_stop();
    }

    fn schedule_request(state: &DispatchState, line: String) {
        let state = state.clone();
        let block = RcBlock::new(move || {
            let response = match serde_json::from_str::<Request>(&line) {
                Ok(request) => handle_request(&state, request),
                Err(error) => Some(Response::error(0, format!("INVALID_REQUEST:{error}"))),
            };
            if response.is_some_and(|response| write_response(&response).is_err()) {
                stop_main_run_loop();
            }
        });
        unsafe {
            NSRunLoop::mainRunLoop().performBlock(&block);
            CFRunLoopWakeUp(CFRunLoopGetMain());
        }
    }

    fn schedule_stop() {
        let block = RcBlock::new(stop_main_run_loop);
        unsafe {
            NSRunLoop::mainRunLoop().performBlock(&block);
            CFRunLoopWakeUp(CFRunLoopGetMain());
        }
    }

    fn stop_main_run_loop() {
        unsafe {
            let run_loop = CFRunLoopGetMain();
            CFRunLoopStop(run_loop);
            CFRunLoopWakeUp(run_loop);
        }
    }

    fn handle_request(state: &DispatchState, request: Request) -> Option<Response> {
        let result = match request.cmd.as_str() {
            "target" if request.prepare => {
                prepare_dispatch(state, request.bundle_id).and_then(|target| {
                    serde_json::to_value(target.app()).map_err(|error| error.to_string())
                })
            }
            "target" => {
                serde_json::to_value(dispatch_target(state)).map_err(|error| error.to_string())
            }
            "targets" => {
                serde_json::to_value(dispatch_targets(state)).map_err(|error| error.to_string())
            }
            "dispatch" => match dispatch(state, request.bundle_id, request.id) {
                Ok(()) => return None,
                Err(error) => Err(error),
            },
            _ => Err("UNKNOWN_COMMAND".to_string()),
        };
        Some(match result {
            Ok(data) => Response::success(request.id, data),
            Err(error) => Response::error(request.id, error),
        })
    }

    fn write_response(response: &Response) -> io::Result<()> {
        let mut stdout = io::stdout().lock();
        serde_json::to_writer(&mut stdout, response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()
    }

    impl Response {
        fn success(id: u64, data: Value) -> Self {
            Self {
                id,
                ok: true,
                data: Some(data),
                error: None,
            }
        }

        fn error(id: u64, error: String) -> Self {
            Self {
                id,
                ok: false,
                data: None,
                error: Some(error),
            }
        }
    }

    impl TargetApp {
        fn app(&self) -> DispatchApp {
            DispatchApp {
                bundle_id: self.bundle_id.clone(),
                name: self.name.clone(),
            }
        }
    }

    fn is_cuepad(state: &DispatchState, application: &NSRunningApplication) -> bool {
        if state.exclusions.pid == Some(application.processIdentifier()) {
            return true;
        }
        let bundle_id = application
            .bundleIdentifier()
            .map(|value| value.to_string());
        state.exclusions.bundle_id.is_some() && state.exclusions.bundle_id == bundle_id
    }

    fn record_frontmost(state: &DispatchState) {
        let Some(application) = NSWorkspace::sharedWorkspace().frontmostApplication() else {
            return;
        };
        record_application(state, &application);
    }

    fn record_application(state: &DispatchState, application: &NSRunningApplication) {
        let pid = application.processIdentifier();
        if pid < 0 || is_cuepad(state, application) {
            return;
        }
        *state.target.lock().expect("dispatch target mutex poisoned") =
            Some(target_from(application));
        complete_pending_dispatch(pid);
    }

    fn complete_pending_dispatch(target_pid: i32) {
        let pending = PENDING_DISPATCH.with(|pending| {
            let mut pending = pending.borrow_mut();
            if pending
                .as_ref()
                .is_some_and(|dispatch| dispatch.target_pid == target_pid)
            {
                pending.take()
            } else {
                None
            }
        });
        let Some(pending) = pending else {
            return;
        };
        pending.key_down.post_to_pid(pending.target_pid);
        pending.key_up.post_to_pid(pending.target_pid);
        schedule_dispatch_response(pending.request_id);
    }

    fn schedule_dispatch_response(request_id: u64) {
        let block = RcBlock::new(move |_timer: NonNull<NSTimer>| {
            if write_response(&Response::success(request_id, Value::Null)).is_err() {
                stop_main_run_loop();
            }
        });
        let _timer = unsafe {
            NSTimer::scheduledTimerWithTimeInterval_repeats_block(
                PASTE_SETTLE_SECONDS,
                false,
                &block,
            )
        };
    }

    fn schedule_activation_timeout(request_id: u64) {
        let block = RcBlock::new(move |_timer: NonNull<NSTimer>| {
            let pending = PENDING_DISPATCH.with(|pending| {
                let mut pending = pending.borrow_mut();
                if pending
                    .as_ref()
                    .is_some_and(|dispatch| dispatch.request_id == request_id)
                {
                    pending.take()
                } else {
                    None
                }
            });
            if pending.is_some()
                && write_response(&Response::error(request_id, TARGET_UNAVAILABLE.into())).is_err()
            {
                stop_main_run_loop();
            }
        });
        let _timer = unsafe {
            NSTimer::scheduledTimerWithTimeInterval_repeats_block(
                ACTIVATION_TIMEOUT_SECONDS,
                false,
                &block,
            )
        };
    }

    fn target_from(application: &NSRunningApplication) -> TargetApp {
        let bundle_id = application
            .bundleIdentifier()
            .map(|value| value.to_string());
        let name = application
            .localizedName()
            .map(|value| value.to_string())
            .or_else(|| bundle_id.clone())
            .unwrap_or_else(|| "目标应用".into());
        TargetApp {
            pid: application.processIdentifier(),
            bundle_id,
            name,
        }
    }

    fn target_for_dispatch(
        state: &DispatchState,
        bundle_id: Option<&str>,
    ) -> Result<TargetApp, String> {
        if let Some(bundle_id) = bundle_id {
            let bundle_id = NSString::from_str(bundle_id);
            let application =
                NSRunningApplication::runningApplicationsWithBundleIdentifier(&bundle_id)
                    .iter()
                    .find(|application| !application.isTerminated())
                    .ok_or_else(|| TARGET_UNAVAILABLE.to_string())?;
            return Ok(target_from(&application));
        }

        let target = state
            .target
            .lock()
            .expect("dispatch target mutex poisoned")
            .clone()
            .ok_or_else(|| NO_TARGET.to_string())?;
        application_for_target(&target)?;
        Ok(target)
    }

    fn application_for_target(
        target: &TargetApp,
    ) -> Result<impl std::ops::Deref<Target = NSRunningApplication>, String> {
        let application = NSRunningApplication::runningApplicationWithProcessIdentifier(target.pid)
            .ok_or_else(|| TARGET_UNAVAILABLE.to_string())?;
        if application.isTerminated() {
            return Err(TARGET_UNAVAILABLE.into());
        }
        let bundle_id = application
            .bundleIdentifier()
            .map(|value| value.to_string());
        if target.bundle_id.is_some() && target.bundle_id != bundle_id {
            return Err(TARGET_UNAVAILABLE.into());
        }
        Ok(application)
    }

    fn paste_events() -> Result<(CGEvent, CGEvent), String> {
        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|_| "CG_EVENT_SOURCE_FAILED".to_string())?;
        let down = CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_V, true)
            .map_err(|_| "CG_EVENT_CREATE_FAILED".to_string())?;
        let up = CGEvent::new_keyboard_event(source, KeyCode::ANSI_V, false)
            .map_err(|_| "CG_EVENT_CREATE_FAILED".to_string())?;
        down.set_flags(CGEventFlags::CGEventFlagCommand);
        up.set_flags(CGEventFlags::CGEventFlagCommand);
        Ok((down, up))
    }

    fn prepare_dispatch(
        state: &DispatchState,
        selector: Option<String>,
    ) -> Result<TargetApp, String> {
        if unsafe { AXIsProcessTrusted() } == 0 {
            return Err(ACCESSIBILITY_REQUIRED.into());
        }
        let target = target_for_dispatch(state, selector.as_deref())?;
        let (key_down, key_up) = paste_events()?;
        PREPARED_DISPATCH.with(|prepared| {
            *prepared.borrow_mut() = Some(PreparedDispatch {
                selector,
                target: target.clone(),
                key_down,
                key_up,
            });
        });
        Ok(target)
    }

    fn dispatch(
        state: &DispatchState,
        selector: Option<String>,
        request_id: u64,
    ) -> Result<(), String> {
        let prepared = PREPARED_DISPATCH.with(|prepared| {
            prepared
                .borrow_mut()
                .take()
                .filter(|prepared| prepared.selector == selector)
        });
        let prepared = match prepared {
            Some(prepared) => prepared,
            None => {
                prepare_dispatch(state, selector.clone())?;
                PREPARED_DISPATCH.with(|prepared| {
                    prepared
                        .borrow_mut()
                        .take()
                        .expect("prepared dispatch just created")
                })
            }
        };
        let application = application_for_target(&prepared.target)?;
        if application.isActive() {
            prepared.key_down.post_to_pid(prepared.target.pid);
            prepared.key_up.post_to_pid(prepared.target.pid);
            schedule_dispatch_response(request_id);
            return Ok(());
        }

        PENDING_DISPATCH.with(|pending| {
            *pending.borrow_mut() = Some(PendingDispatch {
                request_id,
                target_pid: prepared.target.pid,
                key_down: prepared.key_down,
                key_up: prepared.key_up,
            });
        });
        if !application.activateWithOptions(NSApplicationActivationOptions::empty()) {
            PENDING_DISPATCH.with(|pending| pending.borrow_mut().take());
            return Err(TARGET_UNAVAILABLE.into());
        }
        schedule_activation_timeout(request_id);
        if application.isActive() {
            complete_pending_dispatch(prepared.target.pid);
        }
        Ok(())
    }

    fn dispatch_target(state: &DispatchState) -> Option<DispatchApp> {
        let target = state
            .target
            .lock()
            .expect("dispatch target mutex poisoned")
            .clone()?;
        application_for_target(&target).ok()?;
        Some(target.app())
    }

    fn dispatch_targets(state: &DispatchState) -> Vec<DispatchApp> {
        let mut seen = HashSet::new();
        let mut targets: Vec<_> = NSWorkspace::sharedWorkspace()
            .runningApplications()
            .iter()
            .filter_map(|application| {
                if application.isTerminated()
                    || is_cuepad(state, &application)
                    || application.activationPolicy() != NSApplicationActivationPolicy::Regular
                {
                    return None;
                }
                let bundle_id = application.bundleIdentifier()?.to_string();
                if !seen.insert(bundle_id.clone()) {
                    return None;
                }
                let name = application
                    .localizedName()
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| bundle_id.clone());
                Some(DispatchApp {
                    bundle_id: Some(bundle_id),
                    name,
                })
            })
            .collect();
        targets.sort_by(|left, right| left.name.cmp(&right.name));
        targets
    }
}

#[cfg(target_os = "macos")]
fn main() {
    if let Err(error) = macos::run() {
        eprintln!("cuepad-dispatch: {error}");
        std::process::exit(2);
    }
}
