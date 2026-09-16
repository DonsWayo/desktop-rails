use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    Manager, Runtime,
};

/// Build and register the system tray icon with a context menu.
///
/// The tray provides Show/Hide and Quit actions, and can be updated
/// dynamically via the "tray" bridge component.
pub fn setup_tray<R: Runtime>(app: &tauri::AppHandle<R>) -> Result<(), tauri::Error> {
    if !tray_library_available() {
        log::warn!(
            "No system tray: neither libayatana-appindicator3 nor libappindicator3 is installed"
        );
        return Ok(());
    }

    let show_hide = MenuItemBuilder::with_id("tray-show-hide", "Show/Hide")
        .build(app)?;
    let quit = MenuItemBuilder::with_id("tray-quit", "Quit")
        .build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&show_hide)
        .separator()
        .item(&quit)
        .build()?;

    let _tray = TrayIconBuilder::new()
        .tooltip("Desktop Rails")
        .menu(&menu)
        .on_menu_event(move |app, event: tauri::menu::MenuEvent| {
            handle_tray_menu_event(app, event.id().as_ref());
        })
        .build(app)?;

    Ok(())
}

/// The libraries a Linux tray icon is drawn with, in the order
/// libappindicator-sys tries them.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub const APPINDICATOR_LIBRARIES: [&str; 4] = [
    "libayatana-appindicator3.so.1",
    "libappindicator3.so.1",
    "libayatana-appindicator3.so",
    "libappindicator3.so",
];

/// Whether a tray icon can be created on this machine.
///
/// On Linux the tray library is loaded at runtime, and when none is installed
/// libappindicator-sys panics rather than returning an error — so the whole app
/// died moments after its server announced itself, on any desktop without an
/// appindicator package. The downloaded shell did exactly that on a clean
/// Ubuntu runner with only WebKitGTK installed, which is all the documentation
/// asks for. A tray is a convenience; the window is the app.
pub fn tray_library_available() -> bool {
    #[cfg(target_os = "linux")]
    {
        any_library_loads(&APPINDICATOR_LIBRARIES, |name| {
            // SAFETY: loading a system shared library runs its initialisers;
            // these are the same libraries the tray would load anyway.
            unsafe { libloading::Library::new(name) }.is_ok()
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

/// Split from the loader so the decision can be tested without the libraries.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn any_library_loads(names: &[&str], load: impl Fn(&str) -> bool) -> bool {
    names.iter().any(|name| load(name))
}

/// Handle tray menu item clicks.
fn handle_tray_menu_event<R: Runtime>(app: &tauri::AppHandle<R>, event_id: &str) {
    match event_id {
        "tray-show-hide" => {
            if let Some(window) = app.get_webview_window("main") {
                if window.is_visible().unwrap_or(false) {
                    let _ = window.hide();
                } else {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        }
        "tray-quit" => {
            // Not std::process::exit: that skips Tauri's shutdown, leaving child
            // processes running and window preferences unwritten.
            app.exit(0);
        }
        // The menu bar has its own handler; tray events for anything else are not
        // ours to act on.
        other => log::debug!("Unhandled tray event: {}", other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn no_tray_library_means_no_tray_rather_than_a_crash() {
        assert!(!any_library_loads(&APPINDICATOR_LIBRARIES, |_| false));
    }

    #[test]
    fn every_library_libappindicator_would_try_is_tried() {
        let tried = RefCell::new(Vec::new());
        any_library_loads(&APPINDICATOR_LIBRARIES, |name| {
            tried.borrow_mut().push(name.to_string());
            false
        });
        assert_eq!(*tried.borrow(), APPINDICATOR_LIBRARIES);
    }

    #[test]
    fn any_one_of_them_is_enough() {
        assert!(any_library_loads(&APPINDICATOR_LIBRARIES, |name| name
            == "libappindicator3.so.1"));
    }
}
