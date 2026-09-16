use crate::bridge::BridgeMessage;
use crate::window::{DesktopRailsConfig, UpdaterConfig};
use tauri::Manager;
use tauri_plugin_updater::{Updater, UpdaterExt};

/// Handle bridge messages for the "updater" component.
///
/// Provides update checking and installation from the web layer.
///
/// Events:
///   - "check": Check if an update is available
///   - "download-and-install": Download and install the available update
pub async fn handle_updater(
    app: &tauri::AppHandle,
    message: &BridgeMessage,
) -> Result<serde_json::Value, String> {
    match message.event.as_str() {
        "check" => handle_check(app).await,
        "download-and-install" => handle_download_and_install(app).await,
        _ => Ok(serde_json::json!({ "status": "unknown_event" })),
    }
}

/// The app's updater settings, copied out of the managed configuration.
///
/// Copied rather than borrowed because a `State` guard must not be held across
/// an await, and everything below here is async.
fn settings(app: &tauri::AppHandle) -> UpdaterConfig {
    app.try_state::<DesktopRailsConfig>()
        .map(|config| config.updater.clone())
        .unwrap_or_default()
}

/// Build an updater from the app's own configuration.
///
/// `tauri.conf.json` is compiled into the shell, and this fork ships one shell
/// binary for every app built with it, so the endpoints and the signing key
/// cannot come from there — they belong to the app, not the framework.
/// `UpdaterBuilder` takes both at runtime, which is why the plugin's own config
/// is left empty.
fn updater_for(app: &tauri::AppHandle, config: &UpdaterConfig) -> Result<Updater, String> {
    let endpoints = config
        .endpoints
        .iter()
        .map(|endpoint| {
            endpoint
                .parse::<url::Url>()
                .map_err(|e| format!("Update endpoint {} is not a URL: {}", endpoint, e))
        })
        .collect::<Result<Vec<_>, String>>()?;

    let mut builder = app
        .updater_builder()
        // Trimmed because this value is pasted into a config file by hand, and a
        // stray newline turns into an "invalid signature" at update time with
        // nothing to suggest the key itself was the problem.
        .pubkey(config.pubkey.trim())
        // Endpoints are checked here rather than at check time: a plain http
        // endpoint is refused outright in a release build, and hearing about it
        // now names the actual mistake.
        .endpoints(endpoints)
        .map_err(|e| format!("Update endpoints rejected: {}", e))?;

    // What "up to date" means for this installation. The shell reports its own
    // crate version, which belongs to the framework rather than to the app
    // embedding it, so without this every app would compare releases against
    // the framework's version number.
    if let Some(installed) = &config.current_version {
        let installed: semver::Version = installed
            .trim()
            .trim_start_matches('v')
            .parse()
            .map_err(|e| format!("updater.current_version is not a version: {}", e))?;

        builder =
            builder.version_comparator(move |_shell_version, release| release.version > installed);
    }

    builder
        .build()
        .map_err(|e| format!("Updater not available: {}", e))
}

async fn handle_check(app: &tauri::AppHandle) -> Result<serde_json::Value, String> {
    let config = settings(app);
    if !config.is_configured() {
        return Ok(serde_json::json!({ "status": "not_configured" }));
    }

    let updater = match updater_for(app, &config) {
        Ok(updater) => updater,
        Err(e) => {
            log::warn!("Updater: {}", e);
            return Ok(serde_json::json!({ "status": "error", "error": e }));
        }
    };

    match updater.check().await {
        Ok(Some(update)) => {
            log::info!("Updater: update available — v{}", update.version);
            Ok(serde_json::json!({
                "status": "available",
                "version": update.version,
                "date": update.date.map(|d| d.to_string()),
                "body": update.body,
                "current_version": update.current_version,
            }))
        }
        Ok(None) => {
            log::info!("Updater: no update available");
            Ok(serde_json::json!({ "status": "up_to_date" }))
        }
        Err(e) => {
            log::warn!("Updater: check failed — {}", e);
            Ok(serde_json::json!({ "status": "error", "error": e.to_string() }))
        }
    }
}

async fn handle_download_and_install(app: &tauri::AppHandle) -> Result<serde_json::Value, String> {
    let config = settings(app);
    if !config.is_configured() {
        return Ok(serde_json::json!({ "status": "not_configured" }));
    }

    let updater = match updater_for(app, &config) {
        Ok(updater) => updater,
        Err(e) => {
            log::warn!("Updater: {}", e);
            return Ok(serde_json::json!({ "status": "error", "error": e }));
        }
    };

    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => return Ok(serde_json::json!({ "status": "up_to_date" })),
        Err(e) => return Ok(serde_json::json!({ "status": "error", "error": e.to_string() })),
    };

    let version = update.version.clone();

    // Download and install — this may restart the app. The downloaded bundle is
    // checked against the configured public key before anything is unpacked;
    // that check is the plugin's, and a failure arrives here as an error.
    match update.download_and_install(|_, _| {}, || {}).await {
        Ok(()) => {
            log::info!("Updater: installed v{}", version);
            Ok(serde_json::json!({
                "status": "installed",
                "version": version,
            }))
        }
        Err(e) => {
            log::warn!("Updater: install failed — {}", e);
            Ok(serde_json::json!({ "status": "error", "error": e.to_string() }))
        }
    }
}
