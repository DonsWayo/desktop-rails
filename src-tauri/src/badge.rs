//! The dock or taskbar badge: an unread count, or on macOS a short label.
//!
//! - **macOS**: the Dock tile, through Tauri's `set_badge_count` and
//!   `set_badge_label`.
//! - **Linux**: the `com.canonical.Unity.LauncherEntry` signal on the session
//!   bus, which is what Ubuntu's dock, Dash to Dock, KDE Plasma's task manager
//!   and Plank listen for. Emitted directly rather than through Tauri, whose
//!   Linux path needs libunity loaded and Unity itself running, and names the
//!   shell's `.desktop` file rather than the packaged app's, so it does nothing
//!   on most desktops. Whether a count appears is up to the dock; a desktop
//!   without one simply ignores the signal. Labels are not part of the protocol.
//! - **Windows**: no badge API for a desktop app. The call succeeds as a no-op
//!   and says `supported: false`, so a page can tell.

use crate::bridge::BridgeMessage;

/// What a caller asked the badge to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BadgeRequest {
    Count(i64),
    Label(String),
    Clear,
}

/// Read a request off the bridge.
///
/// `set` with a count of 0 clears, matching the platforms, which treat a zero
/// badge as no badge.
pub fn request_from(message: &BridgeMessage) -> Result<BadgeRequest, String> {
    let data = &message.data;
    match message.event.as_str() {
        "clear" => Ok(BadgeRequest::Clear),
        "set" | "update" | "connect" => {
            if let Some(label) = data["label"].as_str() {
                let label = label.trim();
                if label.chars().count() > 16 {
                    return Err("Refused: a badge label is at most 16 characters".into());
                }
                return Ok(if label.is_empty() {
                    BadgeRequest::Clear
                } else {
                    BadgeRequest::Label(label.to_string())
                });
            }
            match &data["count"] {
                serde_json::Value::Null => Err("Missing 'count' (or 'label') for the badge".into()),
                value => {
                    let count = value
                        .as_i64()
                        .filter(|c| *c >= 0)
                        .ok_or_else(|| format!("'{}' is not a usable badge count", value))?;
                    Ok(if count == 0 {
                        BadgeRequest::Clear
                    } else {
                        BadgeRequest::Count(count)
                    })
                }
            }
        }
        other => Err(format!("unknown_event:{other}")),
    }
}

/// Whether this platform can show what was asked, before trying.
pub fn supported(request: &BadgeRequest) -> bool {
    match request {
        BadgeRequest::Label(_) => cfg!(target_os = "macos"),
        _ => cfg!(any(target_os = "macos", target_os = "linux")),
    }
}

/// The `badge` bridge component.
pub async fn handle_badge<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    message: &BridgeMessage,
) -> Result<serde_json::Value, String> {
    let request = match request_from(message) {
        Ok(request) => request,
        Err(e) if e.starts_with("unknown_event:") => {
            return Ok(serde_json::json!({ "status": "unknown_event" }))
        }
        Err(e) => return Err(e),
    };

    let (count, label) = match &request {
        BadgeRequest::Count(count) => (Some(*count), None),
        BadgeRequest::Label(label) => (None, Some(label.clone())),
        BadgeRequest::Clear => (None, None),
    };
    let mut reply = serde_json::json!({
        "status": "ok",
        "count": count,
        "label": label,
        "supported": supported(&request),
    });

    if !supported(&request) {
        reply["reason"] = match request {
            BadgeRequest::Label(_) => "badge labels are macOS only",
            _ => "this platform has no badge for desktop apps",
        }
        .into();
        return Ok(reply);
    }

    apply(app, &request)?;
    log::info!("Badge: {:?}", request);
    Ok(reply)
}

#[cfg(target_os = "macos")]
fn apply<R: tauri::Runtime>(app: &tauri::AppHandle<R>, request: &BadgeRequest) -> Result<(), String> {
    use tauri::Manager;
    let window = app
        .get_webview_window("main")
        .ok_or("No main window to badge")?;
    match request {
        BadgeRequest::Count(count) => window.set_badge_count(Some(*count)),
        BadgeRequest::Label(label) => window.set_badge_label(Some(label.clone())),
        BadgeRequest::Clear => window
            .set_badge_count(None)
            .and_then(|_| window.set_badge_label(None)),
    }
    .map_err(|e| format!("Could not set the badge: {}", e))
}

#[cfg(target_os = "linux")]
fn apply<R: tauri::Runtime>(_app: &tauri::AppHandle<R>, request: &BadgeRequest) -> Result<(), String> {
    let count = match request {
        BadgeRequest::Count(count) => Some(*count),
        _ => None,
    };
    launcher_entry::emit(&launcher_entry::app_uri(), count)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn apply<R: tauri::Runtime>(_app: &tauri::AppHandle<R>, _request: &BadgeRequest) -> Result<(), String> {
    Ok(())
}

/// The Unity launcher entry protocol.
#[cfg(any(target_os = "linux", test))]
pub mod launcher_entry {
    #[cfg(target_os = "linux")]
    use std::collections::HashMap;
    use std::path::Path;

    /// Where the signal is emitted from. The protocol does not care about the
    /// path; docks match on the app URI in the body.
    #[cfg(target_os = "linux")]
    pub const PATH: &str = "/com/desktop_rails/LauncherEntry";
    #[cfg(target_os = "linux")]
    pub const INTERFACE: &str = "com.canonical.Unity.LauncherEntry";

    /// The `.desktop` file id this app is known by.
    ///
    /// A desktop launcher says which file it launched in
    /// `GIO_LAUNCHED_DESKTOP_FILE`. Otherwise, a packaged tree carries its entry
    /// in `share/applications` beside the executable. Failing both, the
    /// executable's own name, which is how an installed package usually names
    /// its entry.
    pub fn desktop_id(launched: Option<&str>, exe: Option<&Path>) -> String {
        if let Some(name) = launched
            .map(Path::new)
            .and_then(Path::file_name)
            .and_then(|n| n.to_str())
            .filter(|n| n.ends_with(".desktop"))
        {
            return name.to_string();
        }
        if let Some(dir) = exe.and_then(Path::parent) {
            if let Ok(entries) = std::fs::read_dir(dir.join("share").join("applications")) {
                let mut names: Vec<String> = entries
                    .flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|n| n.ends_with(".desktop"))
                    .collect();
                names.sort();
                if let Some(first) = names.into_iter().next() {
                    return first;
                }
            }
        }
        let stem = exe
            .and_then(Path::file_stem)
            .and_then(|s| s.to_str())
            .unwrap_or("desktop-rails");
        format!("{stem}.desktop")
    }

    #[cfg(target_os = "linux")]
    pub fn app_uri() -> String {
        let launched = std::env::var("GIO_LAUNCHED_DESKTOP_FILE").ok();
        let exe = std::env::current_exe().ok();
        format!(
            "application://{}",
            desktop_id(launched.as_deref(), exe.as_deref())
        )
    }

    /// The properties of an `Update`: a visible count, or none.
    #[cfg(target_os = "linux")]
    pub fn properties(count: Option<i64>) -> HashMap<&'static str, zbus::zvariant::Value<'static>> {
        let mut properties = HashMap::new();
        properties.insert("count", zbus::zvariant::Value::from(count.unwrap_or(0)));
        properties.insert("count-visible", zbus::zvariant::Value::from(count.is_some()));
        properties
    }

    #[cfg(target_os = "linux")]
    pub fn emit(app_uri: &str, count: Option<i64>) -> Result<(), String> {
        let connection = zbus::blocking::Connection::session()
            .map_err(|e| format!("No session D-Bus to reach the dock on: {}", e))?;
        connection
            .emit_signal(
                None::<&str>,
                PATH,
                INTERFACE,
                "Update",
                &(app_uri, properties(count)),
            )
            .map_err(|e| format!("Could not update the launcher badge: {}", e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(event: &str, data: serde_json::Value) -> BridgeMessage {
        serde_json::from_value(serde_json::json!({ "component": "badge", "event": event, "data": data }))
            .unwrap()
    }

    #[test]
    fn a_count_zero_label_or_clear_parse_to_what_the_platforms_do() {
        assert_eq!(
            request_from(&message("set", serde_json::json!({ "count": 3 }))),
            Ok(BadgeRequest::Count(3))
        );
        assert_eq!(
            request_from(&message("set", serde_json::json!({ "count": 0 }))),
            Ok(BadgeRequest::Clear)
        );
        assert_eq!(
            request_from(&message("set", serde_json::json!({ "label": "new" }))),
            Ok(BadgeRequest::Label("new".into()))
        );
        assert_eq!(request_from(&message("clear", serde_json::json!({}))), Ok(BadgeRequest::Clear));
    }

    #[test]
    fn nonsense_counts_are_refused() {
        for count in [serde_json::json!(-1), serde_json::json!("three"), serde_json::json!(1.5)] {
            assert!(
                request_from(&message("set", serde_json::json!({ "count": count }))).is_err(),
                "{count}"
            );
        }
        assert!(request_from(&message("set", serde_json::json!({}))).is_err());
        assert!(request_from(&message("set", serde_json::json!({ "label": "x".repeat(17) }))).is_err());
    }

    #[test]
    fn what_each_platform_supports() {
        assert_eq!(supported(&BadgeRequest::Count(1)), cfg!(any(target_os = "macos", target_os = "linux")));
        assert_eq!(supported(&BadgeRequest::Label("x".into())), cfg!(target_os = "macos"));
    }

    #[test]
    fn an_unsupported_badge_is_a_no_op_that_says_so() {
        let app = tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .unwrap();
        let reply = tauri::async_runtime::block_on(handle_badge(
            app.handle(),
            &message("set", serde_json::json!({ "label": "x" })),
        ));
        if cfg!(target_os = "macos") {
            // No main window in this mock, so macOS reports that instead.
            assert!(reply.is_err());
        } else {
            let reply = reply.unwrap();
            assert_eq!(reply["supported"], false);
            assert!(reply["reason"].as_str().unwrap().contains("macOS only"));
        }
    }

    #[test]
    fn the_launcher_entry_names_the_packaged_desktop_file() {
        let dir = std::env::temp_dir().join("desktop-rails-launcher-entry");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("share/applications")).unwrap();
        std::fs::write(dir.join("share/applications/dev.desktop-rails.notes.desktop"), "").unwrap();
        let exe = dir.join("notes");

        assert_eq!(
            launcher_entry::desktop_id(None, Some(&exe)),
            "dev.desktop-rails.notes.desktop"
        );
        assert_eq!(
            launcher_entry::desktop_id(Some("/usr/share/applications/org.example.desktop"), Some(&exe)),
            "org.example.desktop",
            "what the launcher says it launched wins"
        );
        assert_eq!(
            launcher_entry::desktop_id(None, Some(&std::env::temp_dir().join("nowhere").join("notes"))),
            "notes.desktop"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_launcher_entry_properties_show_or_hide_the_count() {
        let shown = launcher_entry::properties(Some(7));
        assert_eq!(shown["count"], zbus::zvariant::Value::from(7i64));
        assert_eq!(shown["count-visible"], zbus::zvariant::Value::from(true));
        let hidden = launcher_entry::properties(None);
        assert_eq!(hidden["count-visible"], zbus::zvariant::Value::from(false));
    }
}
