use serde::Serialize;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchApp {
  bundle_id: Option<String>,
  name: String,
}

#[derive(Clone, Default)]
pub struct DispatchState {
  #[cfg(target_os = "macos")]
  target: std::sync::Arc<std::sync::Mutex<Option<TargetApp>>>,
  /// 串行化投送全链路：剪贴板→隐藏→激活→粘贴不可交错，否则并发调用会粘贴错文本
  #[cfg(target_os = "macos")]
  dispatch_lock: std::sync::Arc<std::sync::Mutex<()>>,
}

#[cfg(target_os = "macos")]
#[derive(Clone)]
struct TargetApp {
  pid: i32,
  bundle_id: Option<String>,
  name: String,
}

#[cfg(target_os = "macos")]
mod macos {
  use super::{DispatchApp, DispatchState, TargetApp};
  use block2::RcBlock;
  use core_graphics::{
    event::{CGEvent, CGEventFlags, KeyCode},
    event_source::{CGEventSource, CGEventSourceStateID},
  };
  use objc2_app_kit::{
    NSApplicationActivationOptions, NSApplicationActivationPolicy, NSRunningApplication,
    NSWorkspace, NSWorkspaceApplicationKey, NSWorkspaceDidActivateApplicationNotification,
  };
  use objc2_foundation::{NSNotification, NSString};
  use std::{collections::HashSet, ptr::NonNull};
  use tauri::{AppHandle, Manager, State};
  use tauri_plugin_clipboard_manager::ClipboardExt;

  const ACCESSIBILITY_REQUIRED: &str = "ACCESSIBILITY_PERMISSION_REQUIRED";
  const NO_TARGET: &str = "NO_DISPATCH_TARGET";
  const TARGET_UNAVAILABLE: &str = "DISPATCH_TARGET_UNAVAILABLE";

  #[link(name = "ApplicationServices", kind = "framework")]
  unsafe extern "C" {
    fn AXIsProcessTrusted() -> u8;
  }

  pub fn setup(state: &DispatchState) {
    record_frontmost(state);
    let state = state.clone();
    // 权威事实源是通知携带的应用对象；回调时刻的全局 frontmost 在快速切换下会丢事件
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
      workspace.notificationCenter().addObserverForName_object_queue_usingBlock(
        Some(NSWorkspaceDidActivateApplicationNotification),
        None,
        None,
        &block,
      )
    };
    // 观察者与应用同寿命；NSNotificationCenter 持有回调，进程退出时由系统回收。
    std::mem::forget(observer);
  }

  fn is_cuepad(application: &NSRunningApplication) -> bool {
    let current_pid = std::process::id() as i32;
    if application.processIdentifier() == current_pid {
      return true;
    }
    let Some(current) = NSRunningApplication::runningApplicationWithProcessIdentifier(current_pid)
    else {
      return false;
    };
    let current_bundle_id = current.bundleIdentifier();
    if current_bundle_id.is_some() && current_bundle_id == application.bundleIdentifier() {
      return true;
    }
    let current_executable = current
      .executableURL()
      .and_then(|url| url.path())
      .map(|path| path.to_string());
    let executable = application
      .executableURL()
      .and_then(|url| url.path())
      .map(|path| path.to_string());
    current_executable.is_some() && current_executable == executable
  }

  /// 仅启动时初始快照；后续更新全部来自激活通知携带的应用对象
  fn record_frontmost(state: &DispatchState) {
    let Some(application) = NSWorkspace::sharedWorkspace().frontmostApplication() else {
      return;
    };
    record_application(state, &application);
  }

  fn record_application(state: &DispatchState, application: &NSRunningApplication) {
    let pid = application.processIdentifier();
    if pid < 0 || is_cuepad(application) {
      return;
    }
    let bundle_id = application.bundleIdentifier().map(|value| value.to_string());
    let name = application
      .localizedName()
      .map(|value| value.to_string())
      .or_else(|| bundle_id.clone())
      .unwrap_or_else(|| "目标应用".into());
    *state.target.lock().expect("dispatch target mutex poisoned") = Some(TargetApp {
      pid,
      bundle_id,
      name,
    });
  }

  fn application_for_dispatch(
    state: &DispatchState,
    bundle_id: Option<&str>,
  ) -> Result<impl std::ops::Deref<Target = NSRunningApplication>, String> {
    if let Some(bundle_id) = bundle_id {
      let bundle_id = NSString::from_str(bundle_id);
      return NSRunningApplication::runningApplicationsWithBundleIdentifier(&bundle_id)
        .iter()
        .find(|application| !application.isTerminated())
        .ok_or_else(|| TARGET_UNAVAILABLE.to_string());
    }

    let target = state
      .target
      .lock()
      .expect("dispatch target mutex poisoned")
      .clone()
      .ok_or_else(|| NO_TARGET.to_string())?;
    let application = NSRunningApplication::runningApplicationWithProcessIdentifier(target.pid)
      .ok_or_else(|| TARGET_UNAVAILABLE.to_string())?;
    if application.isTerminated() {
      return Err(TARGET_UNAVAILABLE.into());
    }
    let current_bundle_id = application.bundleIdentifier().map(|value| value.to_string());
    if target.bundle_id.is_some() && target.bundle_id != current_bundle_id {
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

  pub fn dispatch_text(
    app: AppHandle,
    state: State<'_, DispatchState>,
    text: String,
    bundle_id: Option<String>,
  ) -> Result<(), String> {
    let _serialized = state
      .dispatch_lock
      .lock()
      .unwrap_or_else(std::sync::PoisonError::into_inner);
    if unsafe { AXIsProcessTrusted() } == 0 {
      return Err(ACCESSIBILITY_REQUIRED.into());
    }
    let application = application_for_dispatch(&state, bundle_id.as_deref())?;
    let target_pid = application.processIdentifier();
    let (key_down, key_up) = paste_events()?;
    app
      .clipboard()
      .write_text(text)
      .map_err(|error| format!("CLIPBOARD_WRITE_FAILED:{error}"))?;

    let window = app
      .get_webview_window("main")
      .ok_or_else(|| "MAIN_WINDOW_UNAVAILABLE".to_string())?;
    window.hide().map_err(|error| error.to_string())?;
    if !application.activateWithOptions(NSApplicationActivationOptions::empty()) {
      let _ = window.show();
      let _ = window.set_focus();
      return Err(TARGET_UNAVAILABLE.into());
    }
    key_down.post_to_pid(target_pid);
    key_up.post_to_pid(target_pid);
    Ok(())
  }

  pub fn dispatch_target(state: State<'_, DispatchState>) -> Option<DispatchApp> {
    let target = state
      .target
      .lock()
      .expect("dispatch target mutex poisoned")
      .clone()?;
    application_for_dispatch(&state, None).ok()?;
    Some(DispatchApp {
      bundle_id: target.bundle_id,
      name: target.name,
    })
  }

  pub fn dispatch_targets() -> Vec<DispatchApp> {
    let mut seen = HashSet::new();
    let mut targets: Vec<_> = NSWorkspace::sharedWorkspace()
      .runningApplications()
      .iter()
      .filter_map(|application| {
        if application.isTerminated()
          || is_cuepad(&application)
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
pub use macos::setup;

#[cfg(target_os = "macos")]
#[tauri::command]
pub fn dispatch_text(
  app: tauri::AppHandle,
  state: tauri::State<'_, DispatchState>,
  text: String,
  bundle_id: Option<String>,
) -> Result<(), String> {
  macos::dispatch_text(app, state, text, bundle_id)
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub fn dispatch_target(state: tauri::State<'_, DispatchState>) -> Option<DispatchApp> {
  macos::dispatch_target(state)
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub fn dispatch_targets() -> Vec<DispatchApp> {
  macos::dispatch_targets()
}

#[cfg(not(target_os = "macos"))]
pub fn setup(_state: &DispatchState) {}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn dispatch_text(_text: String, _bundle_id: Option<String>) -> Result<(), String> {
  Err("DISPATCH_UNSUPPORTED_PLATFORM".into())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn dispatch_target() -> Option<DispatchApp> {
  None
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn dispatch_targets() -> Vec<DispatchApp> {
  Vec::new()
}
