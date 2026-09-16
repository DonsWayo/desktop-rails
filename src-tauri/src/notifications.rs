//! OS notifications, for pages and for the app's Ruby.
//!
//! tauri-plugin-notification's desktop `show()` hands the notification to a
//! spawned task and drops the result, so a machine with no notification
//! service reads as success, and it has no way to report a click. This talks to
//! each platform's service with the library that plugin wraps (notify-rust) or
//! the service's own protocol, and answers with what the OS said:
//!
//! - **Linux**: `org.freedesktop.Notifications` on the session bus, over one
//!   connection the shell keeps. The notification carries a `default` action,
//!   which is what a click on its body invokes; the daemon answers with
//!   `ActionInvoked` on that same connection.
//! - **Windows**: a toast, whose activation callback is the click.
//! - **macOS**: `NSUserNotificationCenter`, through notify-rust. Clicking a
//!   notification activates the app, which is the OS's doing; no click event
//!   reaches the page.
//!
//! A click brings the main window forward and tells every page, as a bridge
//! response and a `desktop-rails:notification-click` DOM event.

use crate::bridge::BridgeMessage;
use std::sync::atomic::{AtomicU64, Ordering};

/// Longest title and body accepted. Daemons truncate on their own, but a page
/// sending megabytes should hear no rather than stall the service.
const MAX_TITLE: usize = 256;
const MAX_BODY: usize = 4096;

/// A notification as a caller asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationRequest {
    /// What a click reports back, and what a later notification with the same
    /// id replaces where the platform can.
    pub id: String,
    pub title: String,
    pub body: String,
}

/// What the OS service said about showing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shown {
    /// Whether a click on this notification will be reported to pages.
    pub clickable: bool,
}

/// What the platform says about being allowed to notify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permission {
    /// A notification service answered (Linux). Only Linux can tell.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    Granted,
    /// No notification service to deliver to (Linux without a daemon).
    Unavailable,
    /// The platform offers no way to ask without a prompt or a signed bundle.
    Unknown,
}

impl Permission {
    pub fn as_str(self) -> &'static str {
        match self {
            Permission::Granted => "granted",
            Permission::Unavailable => "unavailable",
            Permission::Unknown => "unknown",
        }
    }
}

/// The platform half, behind a trait so the component can be tested without a
/// notification service.
pub trait Notifier: Send + Sync {
    fn show(&self, request: &NotificationRequest) -> Result<Shown, String>;
    fn permission(&self) -> Permission;
}

/// The notifier the shell uses, managed as state.
pub struct Notifications(pub Box<dyn Notifier>);

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Read a request off the bridge.
pub fn request_from(message: &BridgeMessage) -> Result<NotificationRequest, String> {
    let data = &message.data;
    let title = data["title"].as_str().unwrap_or_default().trim().to_string();
    if title.is_empty() {
        return Err("Missing 'title': a notification needs one".to_string());
    }
    if title.chars().count() > MAX_TITLE {
        return Err(format!("Refused: the title is longer than {MAX_TITLE} characters"));
    }
    let body = data["body"].as_str().unwrap_or_default().to_string();
    if body.chars().count() > MAX_BODY {
        return Err(format!("Refused: the body is longer than {MAX_BODY} characters"));
    }

    let id = match data["id"].as_str().map(str::trim).filter(|id| !id.is_empty()) {
        Some(id) => {
            if id.len() > 128 || id.chars().any(char::is_control) {
                return Err(format!("'{}' is not a usable notification id", id));
            }
            id.to_string()
        }
        None => format!("notification-{}", NEXT_ID.fetch_add(1, Ordering::Relaxed)),
    };

    Ok(NotificationRequest { id, title, body })
}

/// The `notification` bridge component.
pub async fn handle_notification<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    message: &BridgeMessage,
) -> Result<serde_json::Value, String> {
    use tauri::Manager;

    let config = app.state::<crate::window::DesktopRailsConfig>();

    match message.event.as_str() {
        // "connect" and "notify" are what earlier examples sent.
        "show" | "connect" | "notify" => {
            crate::security::authorize_notifications(&config.notifications)?;
            let request = request_from(message)?;
            let app = app.clone();
            let shown_request = request.clone();
            let shown = tauri::async_runtime::spawn_blocking(move || {
                let notifications = app
                    .try_state::<Notifications>()
                    .ok_or("Notifications are not available in this shell")?;
                notifications.0.show(&shown_request)
            })
            .await
            .map_err(|e| format!("Could not show the notification: {}", e))??;

            log::info!("Notification shown: {} ({})", request.title, request.id);
            Ok(serde_json::json!({
                "status": "shown",
                "id": request.id,
                "clickable": shown.clickable,
            }))
        }
        // Desktop platforms do not prompt, so asking is the same as looking.
        "permission" | "request-permission" | "request_permission" => {
            if !config.notifications.enabled {
                return Ok(serde_json::json!({ "status": "ok", "permission": "denied", "reason": "config" }));
            }
            let app = app.clone();
            let permission = tauri::async_runtime::spawn_blocking(move || {
                app.try_state::<Notifications>()
                    .map(|n| n.0.permission())
                    .unwrap_or(Permission::Unavailable)
            })
            .await
            .unwrap_or(Permission::Unknown);
            Ok(serde_json::json!({ "status": "ok", "permission": permission.as_str() }))
        }
        _ => Ok(serde_json::json!({ "status": "unknown_event" })),
    }
}

/// A notification was clicked: bring the window forward and tell the pages.
///
/// Not called on macOS, where the OS activates the app itself and reports
/// nothing back.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub fn on_clicked<R: tauri::Runtime>(app: &tauri::AppHandle<R>, id: &str) {
    log::info!("Notification clicked: {}", id);
    crate::window::summon_main_window(app);
    crate::bridge::broadcast_response(
        app,
        &crate::bridge::BridgeResponse {
            component: "notification".into(),
            event: "click".into(),
            data: serde_json::json!({ "id": id }),
        },
    );
}

/// The notifier for the platform this shell was built for.
pub fn platform_notifier<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    app_name: &str,
) -> Box<dyn Notifier> {
    #[cfg(target_os = "linux")]
    {
        let app = app.clone();
        Box::new(linux::DbusNotifier::new(
            app_name.to_string(),
            std::sync::Arc::new(move |id: String| on_clicked(&app, &id)),
        ))
    }
    #[cfg(target_os = "windows")]
    {
        let _ = app_name;
        let app = app.clone();
        Box::new(windows::ToastNotifier::new(std::sync::Arc::new(move |id: String| {
            on_clicked(&app, &id)
        })))
    }
    #[cfg(target_os = "macos")]
    {
        let _ = (app, app_name);
        Box::new(macos::UserNotificationCenter::default())
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
    {
        let _ = (app, app_name);
        Box::new(Unsupported)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
struct Unsupported;

#[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
impl Notifier for Unsupported {
    fn show(&self, _: &NotificationRequest) -> Result<Shown, String> {
        Err("Notifications are not supported on this platform".into())
    }
    fn permission(&self) -> Permission {
        Permission::Unavailable
    }
}

/// The freedesktop notification protocol, spoken directly over zbus.
#[cfg(target_os = "linux")]
pub mod linux {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use zbus::zvariant::Value;

    const DESTINATION: &str = "org.freedesktop.Notifications";
    const PATH: &str = "/org/freedesktop/Notifications";
    const INTERFACE: &str = "org.freedesktop.Notifications";

    /// The action a click on the notification body invokes, per the spec.
    pub const DEFAULT_ACTION: &str = "default";

    type OnClick = Arc<dyn Fn(String) + Send + Sync>;

    /// Which server-side notification ids belong to which caller ids.
    #[derive(Default)]
    pub struct Ids {
        by_server: HashMap<u32, String>,
        by_caller: HashMap<String, u32>,
    }

    impl Ids {
        /// The server id a notification with this caller id should replace,
        /// or 0 for a new one.
        pub fn replaces(&self, caller: &str) -> u32 {
            self.by_caller.get(caller).copied().unwrap_or(0)
        }

        pub fn record(&mut self, server: u32, caller: &str) {
            if let Some(old) = self.by_caller.insert(caller.to_string(), server) {
                if old != server {
                    self.by_server.remove(&old);
                }
            }
            self.by_server.insert(server, caller.to_string());
        }

        /// A click on `server`, if it is one of ours.
        pub fn clicked(&self, server: u32, action: &str) -> Option<String> {
            (action == DEFAULT_ACTION)
                .then(|| self.by_server.get(&server).cloned())
                .flatten()
        }

        pub fn closed(&mut self, server: u32) {
            if let Some(caller) = self.by_server.remove(&server) {
                if self.by_caller.get(&caller) == Some(&server) {
                    self.by_caller.remove(&caller);
                }
            }
        }
    }

    /// The arguments of `Notify`, in the spec's order.
    pub fn notify_arguments<'a>(
        app_name: &'a str,
        replaces: u32,
        request: &'a NotificationRequest,
    ) -> (
        &'a str,
        u32,
        &'a str,
        &'a str,
        &'a str,
        Vec<&'a str>,
        HashMap<&'a str, Value<'a>>,
        i32,
    ) {
        (
            app_name,
            replaces,
            "",
            request.title.as_str(),
            request.body.as_str(),
            // A key and its label. The default action has no button of its
            // own; it is what clicking the notification does.
            vec![DEFAULT_ACTION, "Open"],
            HashMap::new(),
            // -1: the daemon's own expiry.
            -1,
        )
    }

    pub struct DbusNotifier {
        app_name: String,
        on_click: OnClick,
        connection: Mutex<Option<zbus::blocking::Connection>>,
        ids: Arc<Mutex<Ids>>,
    }

    impl DbusNotifier {
        pub fn new(app_name: String, on_click: OnClick) -> Self {
            Self {
                app_name,
                on_click,
                connection: Mutex::new(None),
                ids: Arc::new(Mutex::new(Ids::default())),
            }
        }

        /// The session bus connection, opened on first use, with the listener
        /// for clicks subscribed before anything is sent on it so none can be
        /// missed.
        fn connection(&self) -> Result<zbus::blocking::Connection, String> {
            let mut slot = self
                .connection
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(connection) = slot.as_ref() {
                return Ok(connection.clone());
            }

            let connection = zbus::blocking::Connection::session()
                .map_err(|e| format!("No session D-Bus to reach a notification service on: {}", e))?;
            let rule = zbus::MatchRule::builder()
                .msg_type(zbus::message::Type::Signal)
                .interface(INTERFACE)
                .map_err(|e| e.to_string())?
                .build();
            let signals = zbus::blocking::MessageIterator::for_match_rule(rule, &connection, None)
                .map_err(|e| format!("Could not listen for notification clicks: {}", e))?;

            let ids = self.ids.clone();
            let on_click = self.on_click.clone();
            std::thread::Builder::new()
                .name("notification-clicks".into())
                .spawn(move || {
                    for message in signals.flatten() {
                        let header = message.header();
                        let member = header.member().map(|m| m.as_str().to_string());
                        match member.as_deref() {
                            Some("ActionInvoked") => {
                                let Ok((server, action)) =
                                    message.body().deserialize::<(u32, String)>()
                                else {
                                    continue;
                                };
                                let clicked = ids
                                    .lock()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                                    .clicked(server, &action);
                                if let Some(id) = clicked {
                                    on_click(id);
                                }
                            }
                            Some("NotificationClosed") => {
                                if let Ok((server, _reason)) =
                                    message.body().deserialize::<(u32, u32)>()
                                {
                                    ids.lock()
                                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                                        .closed(server);
                                }
                            }
                            _ => {}
                        }
                    }
                    log::info!("Notifications: the session bus closed; clicks are no longer reported");
                })
                .map_err(|e| format!("Could not start the notification listener: {}", e))?;

            *slot = Some(connection.clone());
            Ok(connection)
        }
    }

    impl Notifier for DbusNotifier {
        fn show(&self, request: &NotificationRequest) -> Result<Shown, String> {
            let connection = self.connection()?;
            let replaces = self
                .ids
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .replaces(&request.id);
            let reply = connection
                .call_method(
                    Some(DESTINATION),
                    PATH,
                    Some(INTERFACE),
                    "Notify",
                    &notify_arguments(&self.app_name, replaces, request),
                )
                .map_err(|e| format!("The notification service refused or is not running: {}", e))?;
            let server: u32 = reply
                .body()
                .deserialize()
                .map_err(|e| format!("The notification service answered oddly: {}", e))?;
            self.ids
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .record(server, &request.id);
            Ok(Shown { clickable: true })
        }

        fn permission(&self) -> Permission {
            let Ok(connection) = self.connection() else {
                return Permission::Unavailable;
            };
            match connection.call_method(
                Some(DESTINATION),
                PATH,
                Some(INTERFACE),
                "GetServerInformation",
                &(),
            ) {
                Ok(_) => Permission::Granted,
                Err(_) => Permission::Unavailable,
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn a_click_is_reported_for_our_notifications_and_the_default_action_only() {
            let mut ids = Ids::default();
            ids.record(7, "build");
            assert_eq!(ids.clicked(7, "default").as_deref(), Some("build"));
            assert_eq!(ids.clicked(7, "dismiss"), None);
            assert_eq!(ids.clicked(8, "default"), None, "someone else's notification");
        }

        #[test]
        fn the_same_caller_id_replaces_the_earlier_notification() {
            let mut ids = Ids::default();
            assert_eq!(ids.replaces("build"), 0);
            ids.record(7, "build");
            assert_eq!(ids.replaces("build"), 7);
            ids.record(9, "build");
            assert_eq!(ids.clicked(7, "default"), None);
            assert_eq!(ids.clicked(9, "default").as_deref(), Some("build"));
            ids.closed(9);
            assert_eq!(ids.replaces("build"), 0);
        }

        #[test]
        fn notify_carries_title_body_and_a_default_action() {
            let request = NotificationRequest {
                id: "build".into(),
                title: "Build finished".into(),
                body: "3 warnings".into(),
            };
            let (app, replaces, icon, summary, body, actions, hints, expire) =
                notify_arguments("Notes", 4, &request);
            assert_eq!((app, replaces, icon), ("Notes", 4, ""));
            assert_eq!((summary, body), ("Build finished", "3 warnings"));
            assert_eq!(actions, vec!["default", "Open"]);
            assert!(hints.is_empty());
            assert_eq!(expire, -1);
        }
    }
}

/// Toasts, with their activation callback as the click.
#[cfg(target_os = "windows")]
pub mod windows {
    use super::*;
    use std::sync::Arc;
    use tauri_winrt_notification::Toast;

    type OnClick = Arc<dyn Fn(String) + Send + Sync>;

    pub struct ToastNotifier {
        on_click: OnClick,
    }

    impl ToastNotifier {
        pub fn new(on_click: OnClick) -> Self {
            Self { on_click }
        }
    }

    impl Notifier for ToastNotifier {
        fn show(&self, request: &NotificationRequest) -> Result<Shown, String> {
            let on_click = self.on_click.clone();
            let id = request.id.clone();
            // PowerShell's AppUserModelID: a toast under an id no Start menu
            // shortcut registers is dropped by Windows without an error, and
            // the shell cannot know whether an installer registered one.
            Toast::new(Toast::POWERSHELL_APP_ID)
                .title(&request.title)
                .text1(&request.body)
                .on_activated(move |_action| {
                    on_click(id.clone());
                    Ok(())
                })
                .show()
                .map_err(|e| format!("Windows refused the notification: {}", e))?;
            Ok(Shown { clickable: true })
        }

        fn permission(&self) -> Permission {
            Permission::Unknown
        }
    }
}

/// NSUserNotificationCenter, through notify-rust.
#[cfg(target_os = "macos")]
pub mod macos {
    use super::*;
    use std::sync::Once;

    #[derive(Default)]
    pub struct UserNotificationCenter;

    static SENDER: Once = Once::new();

    /// The bundle identifier the process is running under, when it is a
    /// bundled app. The plugin uses the identifier compiled into the shell,
    /// which every app built on the prebuilt shell shares, and which macOS
    /// does not know when that app is not installed; notifications then go
    /// out as Finder's or not at all.
    fn running_bundle_identifier() -> Option<String> {
        // An unbundled binary (`cargo run`) has a main bundle with no
        // identifier, which comes back as None.
        objc2_foundation::NSBundle::mainBundle()
            .bundleIdentifier()
            .map(|identifier| identifier.to_string())
    }

    impl Notifier for UserNotificationCenter {
        fn show(&self, request: &NotificationRequest) -> Result<Shown, String> {
            SENDER.call_once(|| {
                if let Some(identifier) = running_bundle_identifier() {
                    if let Err(e) = notify_rust::set_application(&identifier) {
                        log::warn!(
                            "Notifications: macOS does not know {} yet, so they go out under a default sender: {}",
                            identifier,
                            e
                        );
                    }
                }
            });
            let mut notification = notify_rust::Notification::new();
            notification.summary(&request.title);
            if !request.body.is_empty() {
                notification.body(&request.body);
            }
            notification
                .show()
                .map_err(|e| format!("macOS refused the notification: {}", e))?;
            Ok(Shown { clickable: false })
        }

        fn permission(&self) -> Permission {
            // NSUserNotificationCenter has no authorization API, and the
            // UserNotifications one prompts and needs a signed bundle.
            Permission::Unknown
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn message(event: &str, data: serde_json::Value) -> BridgeMessage {
        serde_json::from_value(serde_json::json!({
            "component": "notification", "event": event, "data": data
        }))
        .unwrap()
    }

    #[test]
    fn a_request_needs_a_title() {
        let error = request_from(&message("show", serde_json::json!({ "body": "x" }))).unwrap_err();
        assert!(error.contains("title"), "{error}");
    }

    #[test]
    fn what_ruby_sends_parses_whole() {
        // Exactly DesktopRails::Native.notify(title:, body:, id:) on the wire,
        // including the null body Ruby sends when none is given.
        let message: BridgeMessage = serde_json::from_str(
            r#"{"component":"notification","event":"show","data":{"title":"Export finished","body":null,"id":"export-42"}}"#,
        )
        .unwrap();
        let request = request_from(&message).unwrap();
        assert_eq!(request.title, "Export finished");
        assert_eq!(request.body, "");
        assert_eq!(request.id, "export-42");
    }

    #[test]
    fn a_notification_without_an_id_gets_a_fresh_one() {
        let a = request_from(&message("show", serde_json::json!({ "title": "a" }))).unwrap();
        let b = request_from(&message("show", serde_json::json!({ "title": "b" }))).unwrap();
        assert_ne!(a.id, b.id);
    }

    #[test]
    fn oversized_or_odd_payloads_are_refused() {
        let long = "x".repeat(MAX_TITLE + 1);
        assert!(request_from(&message("show", serde_json::json!({ "title": long }))).is_err());
        let body = "x".repeat(MAX_BODY + 1);
        assert!(request_from(&message("show", serde_json::json!({ "title": "t", "body": body }))).is_err());
        assert!(request_from(&message("show", serde_json::json!({ "title": "t", "id": "a\nb" }))).is_err());
    }

    /// Records what reached "the OS", or fails like a machine with no service.
    struct FakeService {
        shown: Arc<Mutex<Vec<NotificationRequest>>>,
        running: bool,
    }

    impl Notifier for FakeService {
        fn show(&self, request: &NotificationRequest) -> Result<Shown, String> {
            if !self.running {
                return Err("The notification service refused or is not running: ServiceUnknown".into());
            }
            self.shown.lock().unwrap().push(request.clone());
            Ok(Shown { clickable: true })
        }
        fn permission(&self) -> Permission {
            if self.running {
                Permission::Granted
            } else {
                Permission::Unavailable
            }
        }
    }

    fn mock_app(
        config: &str,
        running: bool,
    ) -> (tauri::App<tauri::test::MockRuntime>, Arc<Mutex<Vec<NotificationRequest>>>) {
        use tauri::Manager;
        let app = tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("the mock shell should build");
        app.manage(crate::window::parse_config(config).unwrap());
        let shown = Arc::new(Mutex::new(Vec::new()));
        app.manage(Notifications(Box::new(FakeService {
            shown: shown.clone(),
            running,
        })));
        (app, shown)
    }

    fn call(app: &tauri::App<tauri::test::MockRuntime>, body: &str) -> Result<serde_json::Value, String> {
        let message: BridgeMessage = serde_json::from_str(body).unwrap();
        tauri::async_runtime::block_on(handle_notification(app.handle(), &message))
    }

    const MINIMAL: &str = r#"{"server_url":"https://app.example.com"}"#;

    #[test]
    fn a_shown_notification_reaches_the_service_and_reports_its_id() {
        let (app, shown) = mock_app(MINIMAL, true);
        let reply = call(
            &app,
            r#"{"component":"notification","event":"show","data":{"title":"Done","body":"invoice.pdf","id":"export"}}"#,
        )
        .unwrap();
        assert_eq!(reply["status"], "shown");
        assert_eq!(reply["id"], "export");
        assert_eq!(reply["clickable"], true);
        assert_eq!(shown.lock().unwrap()[0].body, "invoice.pdf");
    }

    #[test]
    fn no_service_is_an_error_not_a_success() {
        // The plugin's show() said "ok" here. A Ruby job that notifies on
        // completion has to learn nobody saw it.
        let (app, _) = mock_app(MINIMAL, false);
        let error = call(
            &app,
            r#"{"component":"notification","event":"show","data":{"title":"Done"}}"#,
        )
        .unwrap_err();
        assert!(error.contains("not running"), "{error}");

        let permission = call(&app, r#"{"component":"notification","event":"permission","data":{}}"#).unwrap();
        assert_eq!(permission["permission"], "unavailable");
    }

    #[test]
    fn a_config_that_turns_notifications_off_refuses_them() {
        let (app, shown) = mock_app(
            r#"{"server_url":"https://app.example.com","notifications":{"enabled":false}}"#,
            true,
        );
        let error = call(
            &app,
            r#"{"component":"notification","event":"show","data":{"title":"Done"}}"#,
        )
        .unwrap_err();
        assert!(error.contains("notifications"), "{error}");
        assert!(shown.lock().unwrap().is_empty());

        let permission = call(&app, r#"{"component":"notification","event":"permission","data":{}}"#).unwrap();
        assert_eq!(permission["permission"], "denied");
    }

    #[test]
    fn the_older_event_names_still_show_a_notification() {
        let (app, shown) = mock_app(MINIMAL, true);
        for event in ["connect", "notify"] {
            call(
                &app,
                &format!(r#"{{"component":"notification","event":"{event}","data":{{"title":"Hi"}}}}"#),
            )
            .unwrap();
        }
        assert_eq!(shown.lock().unwrap().len(), 2);
    }
}
