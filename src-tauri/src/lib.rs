use tauri::{
  menu::{Menu, MenuItem},
  tray::TrayIconBuilder,
  AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, WindowEvent,
};
use tauri_plugin_sql::{Migration, MigrationKind};

mod dispatch;

const DATABASE_URL: &str = "sqlite:cuepad.db";
const OPEN_SETTINGS_EVENT: &str = "cuepad://open-settings";
/// 默认全局快捷键在 Rust 侧注册：启动即可用，不依赖 webview 活性；
/// 与前端 DEFAULT_GLOBAL_SHORTCUT 保持一致（单一默认值，两侧各自声明）。
const DEFAULT_SHORTCUT: &str = "Alt+Space";

fn migrations() -> Vec<Migration> {
  vec![
    Migration {
      version: 1,
      description: "create_cuepad_core_tables",
      sql: include_str!("../migrations/001_init.sql"),
      kind: MigrationKind::Up,
    },
    Migration {
      version: 2,
      description: "allow_empty_card_title_and_body",
      sql: include_str!("../migrations/002_nullable_card_text.sql"),
      kind: MigrationKind::Up,
    },
    Migration {
      version: 3,
      description: "add_card_numbering",
      sql: include_str!("../migrations/003_card_numbering.sql"),
      kind: MigrationKind::Up,
    },
    Migration {
      version: 4,
      description: "rename_project_favorite_to_pinned",
      sql: include_str!("../migrations/004_project_pinning.sql"),
      kind: MigrationKind::Up,
    },
    Migration {
      version: 5,
      description: "create_tasks",
      sql: include_str!("../migrations/005_tasks.sql"),
      kind: MigrationKind::Up,
    },
  ]
}

fn show_main_window(app: &AppHandle) {
  if let Some(window) = app.get_webview_window("main") {
    let _ = window.show();
    let _ = window.set_focus();
  }
}

// 点托盘菜单时主窗口必然失焦，所以只看可见性。
fn tray_toggle_main_window(app: &AppHandle) {
  let Some(window) = app.get_webview_window("main") else {
    return;
  };
  if window.is_visible().unwrap_or(false) {
    let _ = window.hide();
  } else {
    let _ = window.show();
    let _ = window.set_focus();
  }
}

// 全局快捷键语义：可见且聚焦 → 隐藏；可见未聚焦 → 聚焦；隐藏 → 显示并聚焦。
// 处理器必须在 Rust 侧：窗口隐藏后 webview 可能被 App Nap/WebKit 冻结，
// JS 侧 handler 不保证执行，后台呼出不能依赖 webview 活性（运行时实测）。
fn hotkey_toggle_main_window(app: &AppHandle) {
  let Some(window) = app.get_webview_window("main") else {
    return;
  };
  let visible = window.is_visible().unwrap_or(false);
  let focused = window.is_focused().unwrap_or(false);
  if visible && focused {
    let _ = window.hide();
  } else {
    let _ = window.show();
    let _ = window.set_focus();
  }
}

/// 设置页「数据文件」→ 在系统文件管理器中定位数据库文件。
#[tauri::command]
fn reveal_data_file(app: AppHandle) -> Result<(), String> {
  let path = app
    .path()
    .app_config_dir()
    .map_err(|error| error.to_string())?
    .join("cuepad.db");
  let path = path.to_string_lossy().to_string();
  #[cfg(target_os = "macos")]
  let result = std::process::Command::new("open").args(["-R", &path]).spawn();
  #[cfg(target_os = "windows")]
  let result = std::process::Command::new("explorer")
    .arg(format!("/select,{path}"))
    .spawn();
  #[cfg(not(any(target_os = "macos", target_os = "windows")))]
  let result = std::process::Command::new("xdg-open")
    .arg(std::path::Path::new(&path).parent().unwrap_or(std::path::Path::new("/")))
    .spawn();
  result.map(|_| ()).map_err(|error| error.to_string())
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
  let toggle = MenuItem::with_id(app, "toggle", "显示 / 隐藏", true, None::<&str>)?;
  let settings = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
  let quit = MenuItem::with_id(app, "quit", "退出 CuePad", true, None::<&str>)?;
  let menu = Menu::with_items(app, &[&toggle, &settings, &quit])?;

  // 单色模板图标：macOS 菜单栏自动适配浅/深色外观
  let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?;
  TrayIconBuilder::with_id("main")
    .icon(tray_icon)
    .icon_as_template(true)
    .tooltip("CuePad")
    .menu(&menu)
    .show_menu_on_left_click(true)
    .on_menu_event(|app, event| match event.id.as_ref() {
      "toggle" => tray_toggle_main_window(app),
      "settings" => {
        show_main_window(app);
        let _ = app.emit(OPEN_SETTINGS_EVENT, ());
      }
      "quit" => app.exit(0),
      _ => {}
    })
    .build(app)?;
  Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  let builder = tauri::Builder::default();
  // WebDriver server 仅在 WDIO 测试环境启动；普通 debug/dev 不监听任何端口
  #[cfg(debug_assertions)]
  let builder = if std::env::var_os("TAURI_WEBDRIVER_PORT").is_some() {
    builder.plugin(tauri_plugin_wdio_webdriver::init())
  } else {
    builder
  };

  builder
    .plugin(tauri_plugin_clipboard_manager::init())
    .plugin(
      // with_handler 对所有已注册快捷键（含 JS 侧 register 的）触发
      tauri_plugin_global_shortcut::Builder::new()
        .with_shortcut(DEFAULT_SHORTCUT)
        .expect("default shortcut must parse")
        .with_handler(|app, _shortcut, event| {
          if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
            hotkey_toggle_main_window(app);
          }
        })
        .build(),
    )
    .plugin(
      tauri_plugin_sql::Builder::default()
        .add_migrations(DATABASE_URL, migrations())
        .build(),
    )
    .manage(dispatch::DispatchState::default())
    .invoke_handler(tauri::generate_handler![
      reveal_data_file,
      dispatch::dispatch_text,
      dispatch::dispatch_target,
      dispatch::dispatch_targets
    ])
    .setup(|app| {
      // WDIO 的 1×1 窗口保持可见以免 WebKit 挂起任务队列，但不可聚焦、不可命中鼠标
      if cfg!(debug_assertions) && std::env::var_os("TAURI_WEBDRIVER_PORT").is_some() {
        if let Some(window) = app.get_webview_window("main") {
          window.set_focusable(false)?;
          window.set_ignore_cursor_events(true)?;
          window.set_size(LogicalSize::new(1.0, 1.0))?;
          window.set_position(LogicalPosition::new(1.0, 1.0))?;
        }
      } else {
        setup_tray(app)?;
      }
      dispatch::setup(app.state::<dispatch::DispatchState>().inner());
      Ok(())
    })
    // 关闭窗口 = 隐藏到后台；只有托盘/设置页的显式退出才终止进程
    .on_window_event(|window, event| {
      if let WindowEvent::CloseRequested { api, .. } = event {
        api.prevent_close();
        let _ = window.hide();
      }
    })
    .build(tauri::generate_context!())
    .expect("error while building tauri application")
    .run(|_app, _event| {
      // macOS：窗口隐藏后点击 Dock 图标重新显示
      #[cfg(target_os = "macos")]
      if let tauri::RunEvent::Reopen { .. } = _event {
        show_main_window(_app);
      }
    });
}
