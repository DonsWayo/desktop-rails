use tauri::{
    menu::{Menu, MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    Manager, Runtime,
};

/// Build the native menu bar.
///
/// On macOS this provides the full standard menu structure (About, Services, Hide, Quit).
/// On Windows/Linux it provides a simpler menu (File > Quit).
///
/// Bridge components can dynamically add items via the "menu-item" bridge component.
pub fn build_menu<R: Runtime>(app: &tauri::AppHandle<R>) -> Result<Menu<R>, tauri::Error> {
    let app_menu = {
        let mut builder = SubmenuBuilder::new(app, "Desktop Rails");
        #[cfg(target_os = "macos")]
        {
            builder = builder
                .about(None)
                .separator()
                .services()
                .separator()
                .hide()
                .hide_others()
                .show_all()
                .separator();
        }
        // A custom Quit rather than the predefined one: that maps to Cocoa's
        // `terminate:`, which ends the process without Tauri ever raising an exit
        // event, so child processes are never reaped and window preferences are
        // never written. This routes through AppHandle::exit instead.
        let quit = MenuItemBuilder::with_id("quit", "Quit")
            .accelerator("CmdOrCtrl+Q")
            .build(app)?;

        builder.item(&quit).build()?
    };

    let file_menu = SubmenuBuilder::new(app, "File")
        .close_window()
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let view_menu = {
        let reload = MenuItemBuilder::with_id("reload", "Reload")
            .accelerator("CmdOrCtrl+R")
            .build(app)?;
        let devtools = MenuItemBuilder::with_id("devtools", "Developer Tools")
            .accelerator("CmdOrCtrl+Alt+I")
            .build(app)?;
        let actual_size = MenuItemBuilder::with_id("actual-size", "Actual Size")
            .accelerator("CmdOrCtrl+0")
            .build(app)?;
        let zoom_in = MenuItemBuilder::with_id("zoom-in", "Zoom In")
            .accelerator("CmdOrCtrl+=")
            .build(app)?;
        let zoom_out = MenuItemBuilder::with_id("zoom-out", "Zoom Out")
            .accelerator("CmdOrCtrl+-")
            .build(app)?;

        SubmenuBuilder::new(app, "View")
            .item(&reload)
            .item(&devtools)
            .separator()
            .item(&actual_size)
            .item(&zoom_in)
            .item(&zoom_out)
            .separator()
            .fullscreen()
            .build()?
    };

    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .close_window()
        .build()?;

    let navigate_menu = {
        let back = MenuItemBuilder::with_id("nav-back", "Back")
            .accelerator("CmdOrCtrl+[")
            .build(app)?;
        let forward = MenuItemBuilder::with_id("nav-forward", "Forward")
            .accelerator("CmdOrCtrl+]")
            .build(app)?;

        SubmenuBuilder::new(app, "Navigate")
            .item(&back)
            .item(&forward)
            .build()?
    };

    let menu = MenuBuilder::new(app)
        .item(&app_menu)
        .item(&file_menu)
        .item(&edit_menu)
        .item(&view_menu)
        .item(&navigate_menu)
        .item(&window_menu)
        .build()?;

    Ok(menu)
}

/// Ask the main window's page to move.
fn navigate_main<R: Runtime>(app: &tauri::AppHandle<R>, action: &str) {
    if let Some(window) = app.get_webview_window("main") {
        crate::window::deliver_to_page(
            &window,
            "navigate",
            &serde_json::json!({ "action": action }),
        );
    }
}

/// Handle menu item clicks.
/// Called from the main event loop when a menu event fires.
pub fn handle_menu_event<R: Runtime>(app: &tauri::AppHandle<R>, event_id: &str) {
    log::debug!("Menu event: {}", event_id);

    match event_id {
        "quit" => {
            // Goes through Tauri's shutdown so the exit handler runs.
            app.exit(0);
        }
        // Navigation goes through the injected script rather than evaluating
        // statements at it, so the menu, modal dismissal and anything else that
        // moves the page share one path.
        "reload" => navigate_main(app, "reload"),
        "devtools" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval("window.__DESKTOP_RAILS__.toggleDevTools()");
            }
        }
        "nav-back" => navigate_main(app, "back"),
        "nav-forward" => navigate_main(app, "forward"),
        "actual-size" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval("document.body.style.zoom = '100%'");
            }
        }
        "zoom-in" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval(
                    "document.body.style.zoom = (parseFloat(document.body.style.zoom || 1) + 0.1) * 100 + '%'",
                );
            }
        }
        "zoom-out" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.eval(
                    "document.body.style.zoom = (parseFloat(document.body.style.zoom || 1) - 0.1) * 100 + '%'",
                );
            }
        }
        _ => match event_id.strip_prefix(PAGE_ITEM_PREFIX) {
            Some(id) => page_item_clicked(app, id),
            None => log::debug!("Unhandled menu event: {}", event_id),
        },
    }
}

// ─── Items pages add ────────────────────────────────────────────────────────
//
// A page (or the app's Ruby) adds an item under an id of its choosing, into a
// top-level menu named by title: an existing one such as "File", or a new one
// the shell creates before "Window". Clicking it tells every open page, as a
// bridge response and a `desktop-rails:menu-item` DOM event. Items live as long
// as the app does, so a page that registers on every load gets "unchanged"
// rather than a second item.

/// Prefix on the native id of every page item, so a page's "quit" can never be
/// mistaken for the shell's.
pub const PAGE_ITEM_PREFIX: &str = "page:";

/// The menu a page item goes into when the page names none.
pub const DEFAULT_PAGE_MENU: &str = "File";

/// How many items pages may add. Menus are not a place to render a list.
pub const MAX_PAGE_MENU_ITEMS: usize = 50;

/// Accelerators the shell's own menu already uses. A page item with one of
/// these would shadow Quit, Reload, Copy and the like.
const BUILT_IN_ACCELERATORS: &[&str] = &[
    "CmdOrCtrl+Q",
    "CmdOrCtrl+R",
    "CmdOrCtrl+Alt+I",
    "CmdOrCtrl+0",
    "CmdOrCtrl+=",
    "CmdOrCtrl+-",
    "CmdOrCtrl+[",
    "CmdOrCtrl+]",
    "CmdOrCtrl+W",
    "CmdOrCtrl+Z",
    "CmdOrCtrl+Shift+Z",
    "CmdOrCtrl+X",
    "CmdOrCtrl+C",
    "CmdOrCtrl+V",
    "CmdOrCtrl+A",
    "CmdOrCtrl+M",
    "CmdOrCtrl+H",
];

/// An item as a page asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageMenuItem {
    pub id: String,
    pub title: String,
    pub accelerator: Option<String>,
    pub menu: String,
}

impl PageMenuItem {
    fn native_id(&self) -> String {
        format!("{PAGE_ITEM_PREFIX}{}", self.id)
    }
}

/// What registering an item has to do to the native menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuPlan {
    Add,
    /// Exactly this item is already there.
    Unchanged,
    /// The id is there with a different title, accelerator or menu.
    Replace(PageMenuItem),
}

/// The items pages have added, by id.
#[derive(Default)]
pub struct PageMenuRegistry {
    items: std::sync::Mutex<Vec<PageMenuItem>>,
    // Serializes whole add and remove operations. The native menu calls wait
    // on the main thread, and a click handler there only reads `items`.
    operations: tokio::sync::Mutex<()>,
}

impl PageMenuRegistry {
    fn items(&self) -> std::sync::MutexGuard<'_, Vec<PageMenuItem>> {
        self.items
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Decide what adding `item` means, or why it is refused.
    pub fn plan(&self, item: &PageMenuItem) -> Result<MenuPlan, String> {
        let items = self.items();
        if let Some(accelerator) = &item.accelerator {
            let wanted = crate::shortcuts::parse_accelerator(accelerator)?;
            let same = |other: &str| {
                crate::shortcuts::parse_accelerator(other)
                    .is_ok_and(|s| s.mods == wanted.mods && s.key == wanted.key)
            };
            if BUILT_IN_ACCELERATORS.iter().any(|built_in| same(built_in)) {
                return Err(format!(
                    "Refused: {} is one of the app menu's own shortcuts",
                    accelerator
                ));
            }
            if let Some(holder) = items.iter().find(|other| {
                other.id != item.id && other.accelerator.as_deref().is_some_and(same)
            }) {
                return Err(format!(
                    "Refused: {} is already used by the menu item '{}'",
                    accelerator, holder.id
                ));
            }
        }
        match items.iter().find(|other| other.id == item.id) {
            Some(existing) if existing == item => Ok(MenuPlan::Unchanged),
            Some(existing) => Ok(MenuPlan::Replace(existing.clone())),
            None if items.len() >= MAX_PAGE_MENU_ITEMS => Err(format!(
                "Refused: pages may add at most {MAX_PAGE_MENU_ITEMS} menu items"
            )),
            None => Ok(MenuPlan::Add),
        }
    }

    pub fn record(&self, item: PageMenuItem) {
        let mut items = self.items();
        items.retain(|other| other.id != item.id);
        items.push(item);
    }

    pub fn forget(&self, id: &str) -> Option<PageMenuItem> {
        let mut items = self.items();
        let position = items.iter().position(|item| item.id == id)?;
        Some(items.remove(position))
    }

    pub fn contains(&self, id: &str) -> bool {
        self.items().iter().any(|item| item.id == id)
    }

    pub fn list(&self) -> Vec<PageMenuItem> {
        self.items().clone()
    }
}

/// Read an item off the bridge.
pub fn page_item_from(message: &crate::bridge::BridgeMessage) -> Result<PageMenuItem, String> {
    let data = &message.data;
    let id = data["id"].as_str().unwrap_or_default().trim().to_string();
    crate::shortcuts::validate_id(&id)?;

    let title = data["title"].as_str().unwrap_or_default().trim().to_string();
    if title.is_empty() || title.chars().count() > 64 {
        return Err("A menu item needs a 'title' of 1 to 64 characters".to_string());
    }
    let menu = data["menu"]
        .as_str()
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .unwrap_or(DEFAULT_PAGE_MENU)
        .to_string();
    if menu.chars().count() > 32 {
        return Err("A menu name is at most 32 characters".to_string());
    }
    // `shortcut` is what the view helper and earlier examples sent.
    let accelerator = ["accelerator", "shortcut"]
        .iter()
        .find_map(|key| data[*key].as_str())
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(str::to_string);

    Ok(PageMenuItem {
        id,
        title,
        accelerator,
        menu,
    })
}

/// The `menu-item` bridge component.
pub async fn handle_menu_item<R: Runtime>(
    app: &tauri::AppHandle<R>,
    message: &crate::bridge::BridgeMessage,
) -> Result<serde_json::Value, String> {
    let registry = app
        .try_state::<PageMenuRegistry>()
        .ok_or("Menu items are not available in this shell")?;

    match message.event.as_str() {
        "register" | "connect" | "add" => {
            let item = page_item_from(message)?;
            let _operation = registry.operations.lock().await;
            let plan = registry.plan(&item)?;
            match &plan {
                MenuPlan::Unchanged => {}
                MenuPlan::Add => add_native(app, &item)?,
                MenuPlan::Replace(existing) => {
                    remove_native(app, existing)?;
                    add_native(app, &item)?;
                }
            }
            registry.record(item.clone());
            Ok(serde_json::json!({
                "status": "registered",
                "id": item.id,
                "title": item.title,
                "menu": item.menu,
                "accelerator": item.accelerator,
                "alreadyRegistered": plan == MenuPlan::Unchanged,
            }))
        }
        "unregister" | "disconnect" | "remove" => {
            let id = message.data["id"].as_str().unwrap_or_default();
            crate::shortcuts::validate_id(id)?;
            let _operation = registry.operations.lock().await;
            let removed = match registry.forget(id) {
                Some(item) => {
                    remove_native(app, &item)?;
                    true
                }
                None => false,
            };
            Ok(serde_json::json!({ "status": "unregistered", "id": id, "removed": removed }))
        }
        "list" => Ok(serde_json::json!({
            "status": "ok",
            "items": registry.list().iter().map(|item| serde_json::json!({
                "id": item.id, "title": item.title, "menu": item.menu, "accelerator": item.accelerator,
            })).collect::<Vec<_>>(),
        })),
        _ => Ok(serde_json::json!({ "status": "unknown_event" })),
    }
}

/// The top-level submenu titled `title`, created before "Window" if missing.
fn submenu_titled<R: Runtime>(
    app: &tauri::AppHandle<R>,
    menu: &Menu<R>,
    title: &str,
    create: bool,
) -> Result<Option<tauri::menu::Submenu<R>>, String> {
    let items = menu.items().map_err(|e| e.to_string())?;
    let existing = items.iter().find_map(|item| {
        item.as_submenu()
            .filter(|submenu| submenu.text().is_ok_and(|text| text == title))
            .cloned()
    });
    if existing.is_some() || !create {
        return Ok(existing);
    }

    let submenu = tauri::menu::Submenu::with_id(app, format!("page-menu:{title}"), title, true)
        .map_err(|e| e.to_string())?;
    let window_position = items.iter().position(|item| {
        item.as_submenu()
            .is_some_and(|submenu| submenu.text().is_ok_and(|text| text == "Window"))
    });
    match window_position {
        Some(position) => menu.insert(&submenu, position),
        None => menu.append(&submenu),
    }
    .map_err(|e| e.to_string())?;
    Ok(Some(submenu))
}

fn add_native<R: Runtime>(app: &tauri::AppHandle<R>, item: &PageMenuItem) -> Result<(), String> {
    let menu = app.menu().ok_or("This app has no menu bar to add to")?;
    let submenu = submenu_titled(app, &menu, &item.menu, true)?
        .ok_or("The menu could not be created")?;
    let native = tauri::menu::MenuItem::with_id(
        app,
        item.native_id(),
        &item.title,
        true,
        item.accelerator.as_deref(),
    )
    .map_err(|e| format!("Could not create the menu item: {}", e))?;
    submenu
        .append(&native)
        .map_err(|e| format!("Could not add the menu item: {}", e))?;
    log::info!("Menu: added '{}' to {}", item.title, item.menu);
    Ok(())
}

fn remove_native<R: Runtime>(app: &tauri::AppHandle<R>, item: &PageMenuItem) -> Result<(), String> {
    let Some(menu) = app.menu() else {
        return Ok(());
    };
    let Some(submenu) = submenu_titled(app, &menu, &item.menu, false)? else {
        return Ok(());
    };
    let native_id = item.native_id();
    if let Some(native) = submenu.get(native_id.as_str()) {
        if let Some(native) = native.as_menuitem() {
            submenu
                .remove(native)
                .map_err(|e| format!("Could not remove the menu item: {}", e))?;
        }
    }
    // A menu the shell created for page items goes when its last item does.
    let created_by_pages = submenu.id().as_ref().starts_with("page-menu:");
    if created_by_pages && submenu.items().is_ok_and(|items| items.is_empty()) {
        menu.remove(&submenu).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// A page item was clicked.
fn page_item_clicked<R: Runtime>(app: &tauri::AppHandle<R>, id: &str) {
    let Some(registry) = app.try_state::<PageMenuRegistry>() else {
        return;
    };
    if !registry.contains(id) {
        return;
    }
    log::info!("Menu: '{}' clicked", id);
    crate::bridge::broadcast_response(
        app,
        &crate::bridge::BridgeResponse {
            component: "menu-item".into(),
            event: "click".into(),
            data: serde_json::json!({ "id": id }),
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, accelerator: Option<&str>) -> PageMenuItem {
        PageMenuItem {
            id: id.into(),
            title: format!("Title of {id}"),
            accelerator: accelerator.map(str::to_string),
            menu: DEFAULT_PAGE_MENU.into(),
        }
    }

    fn message(data: serde_json::Value) -> crate::bridge::BridgeMessage {
        serde_json::from_value(
            serde_json::json!({ "component": "menu-item", "event": "register", "data": data }),
        )
        .unwrap()
    }

    #[test]
    fn registering_the_same_item_again_changes_nothing() {
        let registry = PageMenuRegistry::default();
        let export = item("export", Some("CmdOrCtrl+Shift+E"));
        assert_eq!(registry.plan(&export), Ok(MenuPlan::Add));
        registry.record(export.clone());

        assert_eq!(registry.plan(&export), Ok(MenuPlan::Unchanged));
        let renamed = PageMenuItem {
            title: "Export as PDF".into(),
            ..export.clone()
        };
        assert_eq!(registry.plan(&renamed), Ok(MenuPlan::Replace(export)));
    }

    #[test]
    fn an_accelerator_another_item_or_the_app_menu_uses_is_refused() {
        let registry = PageMenuRegistry::default();
        registry.record(item("export", Some("CmdOrCtrl+Shift+E")));

        let error = registry
            .plan(&item("print", Some("cmdorctrl+shift+e")))
            .unwrap_err();
        assert!(error.contains("'export'"), "{error}");

        for built_in in ["CmdOrCtrl+Q", "CmdOrCtrl+C", "CmdOrCtrl+R"] {
            let error = registry.plan(&item("mine", Some(built_in))).unwrap_err();
            assert!(error.contains("app menu's own"), "{built_in}: {error}");
        }
    }

    #[test]
    fn a_menu_accelerator_needs_a_modifier_too() {
        // In the window a bare key would take typing away from every text field.
        let registry = PageMenuRegistry::default();
        assert!(registry.plan(&item("mine", Some("K"))).is_err());
        assert_eq!(registry.plan(&item("mine", None)), Ok(MenuPlan::Add));
    }

    #[test]
    fn pages_add_a_bounded_number_of_items() {
        let registry = PageMenuRegistry::default();
        for i in 0..MAX_PAGE_MENU_ITEMS {
            registry.record(item(&format!("item-{i}"), None));
        }
        assert!(registry
            .plan(&item("one-more", None))
            .unwrap_err()
            .contains("at most"));
    }

    #[test]
    fn the_payload_and_its_older_spelling_parse() {
        let parsed = page_item_from(&message(serde_json::json!({
            "id": "export", "title": "Export PDF", "shortcut": "Cmd+E"
        })))
        .unwrap();
        assert_eq!(parsed.accelerator.as_deref(), Some("Cmd+E"));
        assert_eq!(parsed.menu, "File");

        let parsed = page_item_from(&message(serde_json::json!({
            "id": "export", "title": "Export PDF", "accelerator": "CmdOrCtrl+E", "menu": "Tools"
        })))
        .unwrap();
        assert_eq!(parsed.menu, "Tools");

        assert!(page_item_from(&message(serde_json::json!({ "id": "export" }))).is_err());
        assert!(page_item_from(&message(serde_json::json!({ "title": "No id" }))).is_err());
    }

    #[test]
    fn page_items_cannot_collide_with_the_shells_own_ids() {
        assert_eq!(item("quit", None).native_id(), "page:quit");
    }
}
