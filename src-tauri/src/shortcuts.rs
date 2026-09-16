//! Global keyboard shortcuts: combinations that reach the app while another
//! application has focus.
//!
//! Two kinds share one registry. A page (or the app's Ruby, over the control
//! channel) registers a shortcut under an id of its choosing, and when it fires
//! every open page hears about it as a bridge response and a
//! `desktop-rails:shortcut` DOM event. The config's `shortcuts.summon` is
//! registered by the shell itself at startup, needs no page code, and brings the
//! main window forward.
//!
//! The OS keeps the actual grabs through tauri-plugin-global-shortcut. The
//! registry exists for what the plugin does not track: which id owns which
//! combination, so a page that reloads and registers the same thing again gets
//! an answer rather than a second grab, and a combination another application
//! already holds comes back as an error rather than as success.

use crate::bridge::BridgeMessage;
use std::sync::Mutex;
use tauri_plugin_global_shortcut::{Modifiers, Shortcut};

/// The owner of the config's summon shortcut. Page ids may not use the prefix,
/// so a page can neither take this one over nor unregister it.
pub const SUMMON_ID: &str = "desktop-rails:summon";

/// How many shortcuts pages may hold at once.
///
/// Registering every letter behind a modifier, one id each, is how a hostile
/// page would learn what is typed in other applications with that modifier
/// held. No real app needs more than a handful.
pub const MAX_PAGE_SHORTCUTS: usize = 20;

/// One registered combination and who owns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Registration {
    pub id: String,
    /// As the caller wrote it, so it can be reported back in their terms.
    pub accelerator: String,
    pub shortcut: Shortcut,
    /// Show and focus the main window before telling the page.
    pub focus: bool,
}

/// What registering did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// A new grab.
    Registered,
    /// This id already held exactly this combination. The usual case after a
    /// page reload, and deliberately not an error: the page cannot know
    /// whether the shell kept its shortcut from the last load.
    AlreadyRegistered,
    /// This id held a different combination, which was released for this one.
    Replaced,
}

impl Outcome {
    pub fn already_registered(self) -> bool {
        self == Outcome::AlreadyRegistered
    }
}

/// Why the OS layer refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendError {
    /// Another application (or the system) holds the combination.
    Taken(String),
    /// Anything else the OS layer reported.
    Failed(String),
}

/// The part that talks to the OS, behind a trait so the registry's decisions
/// can be tested without a display server.
pub trait HotkeyBackend: Send + Sync {
    fn register(&self, shortcut: Shortcut) -> Result<(), BackendError>;
    fn unregister(&self, shortcut: Shortcut) -> Result<(), BackendError>;
}

/// Every shortcut the shell holds, by owner.
pub struct ShortcutRegistry {
    backend: Box<dyn HotkeyBackend>,
    entries: Mutex<Vec<Registration>>,
    // Held across a whole register or unregister, but never by `lookup`: the
    // backend waits on the main thread, and on macOS the handler that calls
    // `lookup` runs there. Holding `entries` across the backend call would
    // deadlock the first time a shortcut fired during a registration.
    operations: Mutex<()>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl ShortcutRegistry {
    pub fn new(backend: Box<dyn HotkeyBackend>) -> Self {
        Self {
            backend,
            entries: Mutex::new(Vec::new()),
            operations: Mutex::new(()),
        }
    }

    /// Grab `request.shortcut` for `request.id`.
    pub fn register(&self, request: Registration) -> Result<Outcome, String> {
        let _operation = lock(&self.operations);

        let (previous, page_count) = {
            let entries = lock(&self.entries);
            if let Some(holder) = entries
                .iter()
                .find(|e| e.shortcut == request.shortcut && e.id != request.id)
            {
                return Err(if holder.id == SUMMON_ID {
                    format!(
                        "Refused: {} is the app's summon shortcut (shortcuts.summon in the config)",
                        request.accelerator
                    )
                } else {
                    format!(
                        "Refused: {} is already registered by '{}'. Unregister it first, or pick another combination",
                        request.accelerator, holder.id
                    )
                });
            }
            let previous = entries.iter().find(|e| e.id == request.id).cloned();
            let page_count = entries.iter().filter(|e| e.id != SUMMON_ID).count();
            (previous, page_count)
        };

        match &previous {
            Some(existing) if existing.shortcut == request.shortcut => {
                // Same combination: keep the grab, take the latest options.
                let mut entries = lock(&self.entries);
                if let Some(entry) = entries.iter_mut().find(|e| e.id == request.id) {
                    entry.focus = request.focus;
                    entry.accelerator = request.accelerator;
                }
                return Ok(Outcome::AlreadyRegistered);
            }
            None if request.id != SUMMON_ID && page_count >= MAX_PAGE_SHORTCUTS => {
                return Err(format!(
                    "Refused: pages may hold at most {MAX_PAGE_SHORTCUTS} global shortcuts"
                ));
            }
            _ => {}
        }

        // Grab the new combination before releasing the old one, so a refusal
        // leaves the page with the shortcut it had rather than with none.
        self.backend.register(request.shortcut).map_err(|e| match e {
            BackendError::Taken(reason) => format!(
                "Could not register {}: another application or the system already uses it ({})",
                request.accelerator, reason
            ),
            BackendError::Failed(reason) => {
                format!("Could not register {}: {}", request.accelerator, reason)
            }
        })?;

        if let Some(existing) = &previous {
            if let Err(e) = self.backend.unregister(existing.shortcut) {
                log::warn!(
                    "Shortcuts: could not release {} while replacing it: {:?}",
                    existing.accelerator,
                    e
                );
            }
        }

        let mut entries = lock(&self.entries);
        entries.retain(|e| e.id != request.id);
        entries.push(request);
        Ok(if previous.is_some() {
            Outcome::Replaced
        } else {
            Outcome::Registered
        })
    }

    /// Release whatever `id` holds. `false` when it held nothing, which is not
    /// an error: unregistering is what a page does on its way out, whether or
    /// not the shell still had the shortcut.
    pub fn unregister(&self, id: &str) -> Result<bool, String> {
        let _operation = lock(&self.operations);
        let Some(existing) = lock(&self.entries).iter().find(|e| e.id == id).cloned() else {
            return Ok(false);
        };
        self.backend
            .unregister(existing.shortcut)
            .map_err(|e| format!("Could not unregister {}: {:?}", existing.accelerator, e))?;
        lock(&self.entries).retain(|e| e.id != id);
        Ok(true)
    }

    /// Release every shortcut a page or Ruby registered. The summon shortcut
    /// belongs to the config and stays.
    pub fn unregister_all_from_pages(&self) -> Result<usize, String> {
        let ids: Vec<String> = self
            .list()
            .into_iter()
            .filter(|e| e.id != SUMMON_ID)
            .map(|e| e.id)
            .collect();
        let mut released = 0;
        for id in ids {
            if self.unregister(&id)? {
                released += 1;
            }
        }
        Ok(released)
    }

    pub fn list(&self) -> Vec<Registration> {
        lock(&self.entries).clone()
    }

    /// Who owns a combination that just fired.
    pub fn lookup(&self, shortcut: &Shortcut) -> Option<Registration> {
        lock(&self.entries)
            .iter()
            .find(|e| e.shortcut.mods == shortcut.mods && e.shortcut.key == shortcut.key)
            .cloned()
    }
}

/// Parse an accelerator, and refuse one a page should not be able to hold.
///
/// A global shortcut takes the keystroke away from whichever application has
/// focus. Without a modifier that is ordinary typing, so combinations need
/// Control, Alt/Option or Command/Super; Shift alone is still typing.
pub fn parse_accelerator(accelerator: &str) -> Result<Shortcut, String> {
    let trimmed = accelerator.trim();
    if trimmed.is_empty() {
        return Err("Missing 'accelerator' (for example \"CmdOrCtrl+Shift+K\")".to_string());
    }
    let shortcut: Shortcut = trimmed
        .parse()
        .map_err(|e| format!("'{}' is not an accelerator this shell understands: {}", trimmed, e))?;

    let required = Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER | Modifiers::META;
    if !shortcut.mods.intersects(required) {
        return Err(format!(
            "Refused: '{}' has no Control, Alt/Option or Command/Super modifier, so it would take ordinary typing away from every other application",
            trimmed
        ));
    }
    Ok(shortcut)
}

/// A page-supplied id: short, printable, and outside the shell's own namespace.
pub fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("Missing 'id': name the shortcut so its events can be told apart".to_string());
    }
    if id.len() > 64
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
    {
        return Err(format!(
            "'{}' is not a usable id: up to 64 letters, digits, '-', '_', '.' or ':'",
            id
        ));
    }
    if id.starts_with("desktop-rails:") {
        return Err(format!("Refused: '{}' is reserved for the shell", id));
    }
    Ok(())
}

/// A registration request as it arrives over the bridge.
pub fn registration_from(message: &BridgeMessage) -> Result<Registration, String> {
    let data = &message.data;
    let id = data["id"].as_str().unwrap_or_default().trim().to_string();
    validate_id(&id)?;
    // `keys` and `shortcut` are what earlier examples sent; accepting them keeps
    // those working now that the call does something.
    let accelerator = ["accelerator", "keys", "shortcut"]
        .iter()
        .find_map(|key| data[*key].as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    let shortcut = parse_accelerator(&accelerator)?;
    Ok(Registration {
        id,
        accelerator,
        shortcut,
        focus: data["focus"].as_bool().unwrap_or(false),
    })
}

fn describe(registration: &Registration) -> serde_json::Value {
    serde_json::json!({
        "id": registration.id,
        "accelerator": registration.accelerator,
        "focus": registration.focus,
    })
}

/// A warning for combinations the OS layer cannot honour as global.
///
/// On Linux the grab goes through X11. Under a Wayland session that means
/// XWayland, where a grab only sees keys while an X11 window has focus, so the
/// shortcut is not global there. Nothing reports this as a failure, so it is
/// said here.
pub fn platform_warning() -> Option<&'static str> {
    #[cfg(target_os = "linux")]
    {
        if std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t.eq_ignore_ascii_case("wayland")) {
            return Some(
                "Wayland session: the shortcut goes through XWayland and only fires while an X11 window has focus",
            );
        }
    }
    None
}

/// Whether the OS layer can grab anything at all.
///
/// On Linux the plugin's X11 thread gives up silently without a display, and
/// every registration after that reports success. Refusing here is what keeps
/// that from being a silent success.
pub fn platform_available() -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("DISPLAY").is_none_or(|d| d.is_empty()) {
            return Err(
                "Global shortcuts need an X11 display (DISPLAY is not set), and this session has none".to_string(),
            );
        }
    }
    Ok(())
}

/// The `shortcut` bridge component.
pub async fn handle_shortcut<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    message: &BridgeMessage,
) -> Result<serde_json::Value, String> {
    use tauri::Manager;

    let registry = app
        .try_state::<ShortcutRegistry>()
        .ok_or("Global shortcuts are not available in this shell")?;

    match message.event.as_str() {
        "register" | "connect" => {
            let config = app.state::<crate::window::DesktopRailsConfig>();
            crate::security::authorize_shortcut_registration(&config.shortcuts)?;
            platform_available()?;
            let request = registration_from(message)?;
            let described = describe(&request);
            let outcome = registry.register(request)?;
            let mut reply = serde_json::json!({
                "status": "registered",
                "alreadyRegistered": outcome.already_registered(),
                "replaced": outcome == Outcome::Replaced,
            });
            merge(&mut reply, described);
            if let Some(warning) = platform_warning() {
                reply["warning"] = warning.into();
            }
            Ok(reply)
        }
        "unregister" | "disconnect" => {
            let id = message.data["id"].as_str().unwrap_or_default();
            validate_id(id)?;
            let released = registry.unregister(id)?;
            Ok(serde_json::json!({ "status": "unregistered", "id": id, "released": released }))
        }
        "unregister-all" | "unregister_all" => {
            let released = registry.unregister_all_from_pages()?;
            Ok(serde_json::json!({ "status": "unregistered", "released": released }))
        }
        "list" => Ok(serde_json::json!({
            "status": "ok",
            "shortcuts": registry
                .list()
                .iter()
                .filter(|e| e.id != SUMMON_ID)
                .map(describe)
                .collect::<Vec<_>>(),
            "summon": registry
                .list()
                .iter()
                .find(|e| e.id == SUMMON_ID)
                .map(|e| e.accelerator.clone()),
        })),
        _ => Ok(serde_json::json!({ "status": "unknown_event" })),
    }
}

fn merge(target: &mut serde_json::Value, extra: serde_json::Value) {
    if let (Some(target), serde_json::Value::Object(extra)) = (target.as_object_mut(), extra) {
        target.extend(extra);
    }
}

/// A shortcut fired. Called from the plugin's handler, on key press only.
pub fn on_pressed<R: tauri::Runtime>(app: &tauri::AppHandle<R>, shortcut: &Shortcut) {
    use tauri::Manager;

    let Some(registration) = app
        .try_state::<ShortcutRegistry>()
        .and_then(|registry| registry.lookup(shortcut))
    else {
        return;
    };
    log::info!("Shortcuts: {} fired for '{}'", registration.accelerator, registration.id);

    if registration.id == SUMMON_ID {
        crate::window::summon_main_window(app);
        crate::bridge::broadcast_response(
            app,
            &crate::bridge::BridgeResponse {
                component: "shortcut".into(),
                event: "summon".into(),
                data: serde_json::json!({ "accelerator": registration.accelerator }),
            },
        );
        return;
    }

    if registration.focus {
        crate::window::summon_main_window(app);
    }
    crate::bridge::broadcast_response(
        app,
        &crate::bridge::BridgeResponse {
            component: "shortcut".into(),
            event: "triggered".into(),
            data: serde_json::json!({ "id": registration.id, "accelerator": registration.accelerator }),
        },
    );
}

/// The OS layer: tauri-plugin-global-shortcut.
pub struct PluginBackend<R: tauri::Runtime>(pub tauri::AppHandle<R>);

impl<R: tauri::Runtime> HotkeyBackend for PluginBackend<R> {
    fn register(&self, shortcut: Shortcut) -> Result<(), BackendError> {
        use tauri_plugin_global_shortcut::GlobalShortcutExt;
        self.0
            .global_shortcut()
            .register(shortcut)
            .map_err(|e| classify(e.to_string()))
    }

    fn unregister(&self, shortcut: Shortcut) -> Result<(), BackendError> {
        use tauri_plugin_global_shortcut::GlobalShortcutExt;
        self.0
            .global_shortcut()
            .unregister(shortcut)
            .map_err(|e| classify(e.to_string()))
    }
}

/// global-hotkey reports a combination another X11 client (or, on Windows,
/// another process) grabbed as "already registered"; everything else is a
/// plain failure.
fn classify(message: String) -> BackendError {
    if message.to_ascii_lowercase().contains("already registered") {
        BackendError::Taken(message)
    } else {
        BackendError::Failed(message)
    }
}

/// Register the config's summon shortcut, if it has one.
///
/// A bad accelerator or a taken combination is logged rather than fatal: the
/// app is still usable without it, and refusing to start would be a worse
/// failure than a shortcut that does nothing.
pub fn register_summon<R: tauri::Runtime>(app: &tauri::AppHandle<R>, config: &crate::window::ShortcutsConfig) {
    use tauri::Manager;

    let Some(accelerator) = config.summon.as_deref().map(str::trim).filter(|a| !a.is_empty()) else {
        return;
    };
    let Some(registry) = app.try_state::<ShortcutRegistry>() else {
        return;
    };
    let result = platform_available()
        .and_then(|_| parse_accelerator(accelerator))
        .and_then(|shortcut| {
            registry.register(Registration {
                id: SUMMON_ID.to_string(),
                accelerator: accelerator.to_string(),
                shortcut,
                focus: true,
            })
        });
    match result {
        Ok(_) => log::info!("Shortcuts: {} summons the window", accelerator),
        Err(e) => log::warn!("Shortcuts: the summon shortcut is not active: {}", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Stands in for the OS: records grabs, and refuses combinations "another
    /// application" holds.
    #[derive(Default)]
    struct FakeOs {
        grabbed: Mutex<Vec<Shortcut>>,
        taken_elsewhere: Mutex<Vec<Shortcut>>,
    }

    struct Backend(Arc<FakeOs>);

    impl HotkeyBackend for Backend {
        fn register(&self, shortcut: Shortcut) -> Result<(), BackendError> {
            if lock(&self.0.taken_elsewhere).contains(&shortcut) {
                return Err(BackendError::Taken("HotKey already registered".into()));
            }
            let mut grabbed = lock(&self.0.grabbed);
            if grabbed.contains(&shortcut) {
                // The real OS layer refuses a second grab by the same process
                // too; the registry must never ask for one.
                return Err(BackendError::Failed("grabbed twice".into()));
            }
            grabbed.push(shortcut);
            Ok(())
        }

        fn unregister(&self, shortcut: Shortcut) -> Result<(), BackendError> {
            lock(&self.0.grabbed).retain(|s| *s != shortcut);
            Ok(())
        }
    }

    fn registry() -> (ShortcutRegistry, Arc<FakeOs>) {
        let os = Arc::new(FakeOs::default());
        (ShortcutRegistry::new(Box::new(Backend(os.clone()))), os)
    }

    fn request(id: &str, accelerator: &str) -> Registration {
        Registration {
            id: id.into(),
            accelerator: accelerator.into(),
            shortcut: parse_accelerator(accelerator).expect("a valid accelerator"),
            focus: false,
        }
    }

    fn message(event: &str, data: serde_json::Value) -> BridgeMessage {
        serde_json::from_value(serde_json::json!({
            "component": "shortcut", "event": event, "data": data
        }))
        .unwrap()
    }

    #[test]
    fn a_registration_grabs_the_combination_once() {
        let (registry, os) = registry();
        assert_eq!(
            registry.register(request("palette", "Ctrl+Alt+J")),
            Ok(Outcome::Registered)
        );
        assert_eq!(lock(&os.grabbed).len(), 1);
    }

    #[test]
    fn registering_again_after_a_reload_does_not_grab_twice() {
        // The page cannot tell whether the shell kept its shortcut from the
        // last load, so it registers on every load. That must be answered, not
        // turned into a second grab or an error.
        let (registry, os) = registry();
        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();

        assert_eq!(
            registry.register(request("palette", "Ctrl+Alt+J")),
            Ok(Outcome::AlreadyRegistered)
        );
        assert_eq!(lock(&os.grabbed).len(), 1);
        assert_eq!(registry.list().len(), 1);
    }

    #[test]
    fn the_same_id_with_a_new_combination_replaces_the_old_one() {
        let (registry, os) = registry();
        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();

        assert_eq!(
            registry.register(request("palette", "Ctrl+Alt+L")),
            Ok(Outcome::Replaced)
        );
        let grabbed = lock(&os.grabbed).clone();
        assert_eq!(grabbed, vec![parse_accelerator("Ctrl+Alt+L").unwrap()]);
        let pressed = parse_accelerator("Ctrl+Alt+J").unwrap();
        assert!(registry.lookup(&pressed).is_none(), "the old combination is released");
    }

    #[test]
    fn a_combination_another_id_holds_is_refused_by_name() {
        let (registry, _) = registry();
        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();

        let error = registry.register(request("search", "ctrl+alt+j")).unwrap_err();
        assert!(error.contains("already registered by 'palette'"), "{error}");
    }

    #[test]
    fn a_combination_another_application_holds_is_an_error_not_a_success() {
        let (registry, os) = registry();
        lock(&os.taken_elsewhere).push(parse_accelerator("Ctrl+Alt+K").unwrap());

        let error = registry.register(request("palette", "Ctrl+Alt+K")).unwrap_err();
        assert!(error.contains("another application or the system"), "{error}");
        assert!(registry.list().is_empty(), "a refused grab is not recorded");
    }

    #[test]
    fn a_refused_replacement_keeps_the_shortcut_the_page_had() {
        let (registry, os) = registry();
        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();
        lock(&os.taken_elsewhere).push(parse_accelerator("Ctrl+Alt+K").unwrap());

        assert!(registry.register(request("palette", "Ctrl+Alt+K")).is_err());
        let kept = registry.lookup(&parse_accelerator("Ctrl+Alt+J").unwrap());
        assert_eq!(kept.map(|r| r.id).as_deref(), Some("palette"));
        assert_eq!(lock(&os.grabbed).len(), 1);
    }

    #[test]
    fn the_summon_shortcut_cannot_be_taken_or_released_by_a_page() {
        let (registry, _) = registry();
        registry.register(request(SUMMON_ID, "Ctrl+Alt+Space")).unwrap();

        let error = registry.register(request("mine", "Ctrl+Alt+Space")).unwrap_err();
        assert!(error.contains("summon shortcut"), "{error}");
        assert!(validate_id(SUMMON_ID).is_err(), "a page cannot name it to unregister it");

        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();
        assert_eq!(registry.unregister_all_from_pages(), Ok(1));
        assert_eq!(registry.list().len(), 1, "the summon shortcut stays");
    }

    #[test]
    fn unregistering_releases_the_grab_and_is_quiet_about_nothing() {
        let (registry, os) = registry();
        registry.register(request("palette", "Ctrl+Alt+J")).unwrap();

        assert_eq!(registry.unregister("palette"), Ok(true));
        assert!(lock(&os.grabbed).is_empty());
        assert_eq!(registry.unregister("palette"), Ok(false));
    }

    #[test]
    fn pages_hold_a_bounded_number_of_shortcuts() {
        let (registry, _) = registry();
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        for (i, letter) in letters.chars().take(MAX_PAGE_SHORTCUTS).enumerate() {
            registry
                .register(request(&format!("s{i}"), &format!("Ctrl+Alt+{letter}")))
                .unwrap();
        }
        let error = registry.register(request("one-more", "Ctrl+Alt+Z")).unwrap_err();
        assert!(error.contains("at most"), "{error}");
    }

    #[test]
    fn plain_typing_cannot_be_grabbed() {
        for accelerator in ["K", "Shift+K", "Space", "Shift+Digit1"] {
            let error = parse_accelerator(accelerator).unwrap_err();
            assert!(error.contains("modifier"), "{accelerator}: {error}");
        }
        for accelerator in ["CmdOrCtrl+Shift+Space", "Alt+F1", "Super+K", "Ctrl+Alt+J"] {
            assert!(parse_accelerator(accelerator).is_ok(), "{accelerator}");
        }
    }

    #[test]
    fn nonsense_is_refused_with_the_reason() {
        let error = parse_accelerator("Ctrl+Banana").unwrap_err();
        assert!(error.contains("not an accelerator"), "{error}");
        assert!(parse_accelerator("  ").unwrap_err().contains("Missing"));
    }

    #[test]
    fn the_payload_carries_id_accelerator_and_focus() {
        let registration = registration_from(&message(
            "register",
            serde_json::json!({ "id": "palette", "accelerator": "CmdOrCtrl+Shift+K", "focus": true }),
        ))
        .unwrap();
        assert_eq!(registration.id, "palette");
        assert_eq!(registration.accelerator, "CmdOrCtrl+Shift+K");
        assert!(registration.focus);
    }

    #[test]
    fn the_older_payload_names_still_parse() {
        let registration = registration_from(&message(
            "connect",
            serde_json::json!({ "id": "palette", "keys": "Ctrl+Alt+K" }),
        ))
        .unwrap();
        assert_eq!(registration.accelerator, "Ctrl+Alt+K");
        assert!(!registration.focus, "focusing the window is opt-in");
    }

    #[test]
    fn ids_are_validated() {
        assert!(validate_id("").unwrap_err().contains("Missing"));
        assert!(validate_id("has space").is_err());
        assert!(validate_id(&"x".repeat(65)).is_err());
        assert!(validate_id("desktop-rails:anything").unwrap_err().contains("reserved"));
        assert!(validate_id("app:palette-1").is_ok());
    }

    #[test]
    fn os_errors_are_classified() {
        assert!(matches!(
            classify("HotKey already registered: HotKey { .. }".into()),
            BackendError::Taken(_)
        ));
        assert!(matches!(
            classify("Unable to register hotkey: no keycode".into()),
            BackendError::Failed(_)
        ));
    }

    // ─── through the component, as a page or Ruby reaches it ───────────────

    fn mock_app(config: &str) -> (tauri::App<tauri::test::MockRuntime>, Arc<FakeOs>) {
        use tauri::Manager;
        let app = tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("the mock shell should build");
        app.manage(crate::window::parse_config(config).expect("a config"));
        let os = Arc::new(FakeOs::default());
        app.manage(ShortcutRegistry::new(Box::new(Backend(os.clone()))));
        (app, os)
    }

    fn call(
        app: &tauri::App<tauri::test::MockRuntime>,
        body: &str,
    ) -> Result<serde_json::Value, String> {
        let message: BridgeMessage = serde_json::from_str(body).unwrap();
        tauri::async_runtime::block_on(handle_shortcut(app.handle(), &message))
    }

    /// DISPLAY is what the Linux check reads; the tests stand in a display so
    /// they exercise the registry on a headless CI runner too.
    fn with_display() {
        #[cfg(target_os = "linux")]
        if std::env::var_os("DISPLAY").is_none() {
            // Every test that needs it sets the same value, so the order the
            // tests run in cannot matter.
            std::env::set_var("DISPLAY", ":0");
        }
    }

    #[test]
    fn register_list_and_unregister_through_the_component() {
        with_display();
        let (app, os) = mock_app(r#"{"server_url":"https://app.example.com"}"#);

        let reply = call(
            &app,
            r#"{"component":"shortcut","event":"register","data":{"id":"palette","accelerator":"Ctrl+Alt+J"}}"#,
        )
        .unwrap();
        assert_eq!(reply["status"], "registered");
        assert_eq!(reply["alreadyRegistered"], false);
        assert_eq!(reply["id"], "palette");

        let again = call(
            &app,
            r#"{"component":"shortcut","event":"register","data":{"id":"palette","accelerator":"Ctrl+Alt+J"}}"#,
        )
        .unwrap();
        assert_eq!(again["alreadyRegistered"], true);

        let listed = call(&app, r#"{"component":"shortcut","event":"list","data":{}}"#).unwrap();
        assert_eq!(listed["shortcuts"][0]["accelerator"], "Ctrl+Alt+J");

        let gone = call(
            &app,
            r#"{"component":"shortcut","event":"unregister","data":{"id":"palette"}}"#,
        )
        .unwrap();
        assert_eq!(gone["released"], true);
        assert!(lock(&os.grabbed).is_empty());
    }

    #[test]
    fn a_config_that_turns_shortcuts_off_refuses_registration() {
        with_display();
        let (app, os) = mock_app(r#"{"server_url":"https://app.example.com","shortcuts":{"enabled":false}}"#);
        let error = call(
            &app,
            r#"{"component":"shortcut","event":"register","data":{"id":"palette","accelerator":"Ctrl+Alt+J"}}"#,
        )
        .unwrap_err();
        assert!(error.contains("shortcuts"), "{error}");
        assert!(lock(&os.grabbed).is_empty());
    }

    #[test]
    fn the_summon_shortcut_comes_from_the_config_alone() {
        with_display();
        let (app, os) = mock_app(
            r#"{"server_url":"https://app.example.com","shortcuts":{"enabled":false,"summon":"CmdOrCtrl+Shift+Space"}}"#,
        );
        let config = crate::window::parse_config(
            r#"{"server_url":"https://app.example.com","shortcuts":{"enabled":false,"summon":"CmdOrCtrl+Shift+Space"}}"#,
        )
        .unwrap();
        register_summon(app.handle(), &config.shortcuts);

        // Pages may not register, and the summon shortcut is held regardless.
        assert_eq!(lock(&os.grabbed).len(), 1);
        let listed = call(&app, r#"{"component":"shortcut","event":"list","data":{}}"#).unwrap();
        assert_eq!(listed["summon"], "CmdOrCtrl+Shift+Space");
        assert_eq!(listed["shortcuts"].as_array().map(Vec::len), Some(0));
    }

    #[test]
    fn a_bad_summon_accelerator_is_logged_not_fatal() {
        with_display();
        let (app, os) = mock_app(r#"{"server_url":"https://app.example.com"}"#);
        register_summon(
            app.handle(),
            &crate::window::ShortcutsConfig {
                enabled: true,
                summon: Some("Space".into()),
            },
        );
        assert!(lock(&os.grabbed).is_empty());
    }
}
