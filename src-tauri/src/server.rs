//! Starting the app server, so the desktop app is something you can just open.
//!
//! Without this, every launch depends on someone having run `rails server` in
//! another terminal first, which is a strange thing to ask of a desktop app.
//!
//! Everything needed was already here: the reachability probe decides whether a
//! server is wanted, ProcessManager owns the child and reaps it on quit, and the
//! connection monitor moves the window off the waiting page once the server
//! answers. This only decides whether to start one and does so.

use crate::window::ServerConfig;
use std::path::{Path, PathBuf};


/// Where the app server is listening, once it has said so.
///
/// A bundled app does not know its own port ahead of time: the server binds
/// 127.0.0.1:0 and the OS picks, which removes the race you get from probing
/// for a free port and then binding it. So the shell learns the address from
/// the server rather than deciding it.
#[derive(Default)]
pub struct ServerAddress(std::sync::Mutex<Option<String>>);

impl ServerAddress {
    pub fn set(&self, url: String) {
        if let Ok(mut guard) = self.0.lock() {
            *guard = Some(url);
        }
    }

    pub fn get(&self) -> Option<String> {
        self.0.lock().ok().and_then(|g| g.clone())
    }

    /// What the app's own server announced, if it has said anything yet.
    ///
    /// Read wherever the configured `server_url` is used as the app's origin: a
    /// bundled config can only carry a placeholder port, so the real origin is
    /// whatever turned up at runtime.
    pub fn announced<R: tauri::Runtime>(app: &tauri::AppHandle<R>) -> Option<String> {
        use tauri::Manager;
        app.try_state::<ServerAddress>().and_then(|a| a.get())
    }
}

/// Hands the server's announced address to the main window, whichever of the
/// two turns up first.
///
/// The server is started before the window is built, and building a window is
/// not quick everywhere: on a Windows runner the window took between 3 and 12
/// seconds, and the app's server was sometimes quicker. An announcement that arrived
/// while there was no window to move was dropped, and the window sat on the
/// waiting page until the connection monitor's next probe noticed the server
/// and sent it on. So an early announcement is kept until the window exists.
///
/// One lock around both facts, so an announcement racing the window's arrival
/// is delivered exactly once rather than never or twice.
#[derive(Default)]
pub struct WindowArrival(std::sync::Mutex<ArrivalState>);

#[derive(Default)]
struct ArrivalState {
    window_ready: bool,
    pending: Option<url::Url>,
}

impl WindowArrival {
    /// The server has said where it is. Returns the address to move the window
    /// to now, or `None` when there is no window yet and it has been kept.
    pub fn announced(&self, address: url::Url) -> Option<url::Url> {
        let Ok(mut state) = self.0.lock() else {
            return Some(address);
        };
        if state.window_ready {
            return Some(address);
        }
        state.pending = Some(address);
        None
    }

    /// The window exists. Returns an address announced before it did, which
    /// the window should move to now.
    pub fn window_ready(&self) -> Option<url::Url> {
        let Ok(mut state) = self.0.lock() else {
            return None;
        };
        state.window_ready = true;
        state.pending.take()
    }
}

/// The one line of handshake a bundled server writes before anything else.
///
/// Parsed rather than matched loosely: a line that is not a handshake is
/// ordinary output, which a developer running `bin/rails server` by hand
/// produces plenty of.
pub fn handshake_url(line: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let url = value.get("url")?.as_str()?;
    url.starts_with("http").then(|| url.to_string())
}

/// Whether to start a server, and why not when we won't.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Start,
    /// Something is already listening — very likely a server the developer is
    /// running themselves, which we must not duplicate or later kill.
    AlreadyRunning,
    /// No command configured, so the app expects a server it does not own.
    NotConfigured,
}

pub fn decide(config: &ServerConfig, reachable: bool) -> Decision {
    if config.command.as_deref().unwrap_or("").trim().is_empty() {
        return Decision::NotConfigured;
    }
    if reachable {
        return Decision::AlreadyRunning;
    }
    Decision::Start
}

/// Where the command runs, resolved against the directory the config was read from.
///
/// The scaffold puts the config in `desktop/` and the Rails app one level up, so
/// `..` is the usual answer and the default.
pub fn working_directory(config: &ServerConfig, config_dir: Option<&Path>) -> Option<PathBuf> {
    let base = config_dir?;
    let relative = config.directory.as_deref().unwrap_or("..");
    let joined = base.join(relative);

    // Fall back to the lexical path when the directory does not exist yet, so the
    // failure is reported by the spawn rather than swallowed here.
    Some(joined.canonicalize().unwrap_or(joined))
}


/// How to run the configured server command.
///
/// The login shell exists so a version manager can set itself up — rbenv and
/// mise only configure themselves in a configured shell, and a developer's
/// `bin/rails server` needs that. A packaged app needs none of it: the
/// interpreter is inside the bundle.
///
/// Two things follow, and both were measured:
///
///   * A login shell costs ~2.3s per launch here against ~0.02s for a direct
///     exec. That is the whole budget an app icon gets before it feels broken,
///     spent on nothing.
///   * `$SHELL -l -c "<command>"` word-splits, so an absolute path containing a
///     space dies with `no such file or directory: /private/tmp/space` and exit
///     127. `/Applications/My App.app` is an entirely ordinary path.
///
/// So: when the command names an executable that exists, run it directly. When
/// it is a command line — `bin/rails server -p 3000` — it needs a shell, and a
/// developer running that has a version manager to set up anyway.
pub fn server_invocation(
    command: &str,
    working_dir: Option<&Path>,
) -> (String, Vec<String>) {
    let trimmed = command.trim();
    let candidate = match working_dir {
        Some(dir) => dir.join(trimmed),
        None => PathBuf::from(trimmed),
    };

    let is_executable_file = candidate.is_file()
        && {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                candidate
                    .metadata()
                    .map(|m| m.permissions().mode() & 0o111 != 0)
                    .unwrap_or(false)
            }
            #[cfg(not(unix))]
            {
                // Windows has no execute bit; what makes a file runnable is its
                // extension. Returning true for any file would hand a .txt to
                // CreateProcess instead of falling back to the shell.
                candidate
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|e| {
                        let e = e.to_ascii_lowercase();
                        matches!(e.as_str(), "exe" | "cmd" | "bat" | "com")
                    })
                    .unwrap_or(false)
            }
        };

    if is_executable_file {
        // The path is passed as one argument, so spaces in it are not special.
        return (candidate.to_string_lossy().into_owned(), Vec::new());
    }

    crate::shell_bridge::shell_invocation(trimmed)
}

/// Start the configured server and hand it to ProcessManager.
///
/// The command runs the way the platform runs commands — through a login shell
/// on Unix (a version manager only sets itself up in a configured shell),
/// through `cmd` on Windows. See [`crate::shell_bridge::shell_invocation`].
pub async fn start(
    app: &tauri::AppHandle,
    config: &ServerConfig,
    config_dir: Option<&Path>,
    control: Option<&crate::control::ControlChannel>,
) -> Result<(), String> {
    use std::process::Stdio;
    use tauri::Manager;
    use tokio::io::{AsyncBufReadExt, BufReader};

    let Some(command) = config.command.as_deref() else {
        return Ok(());
    };
    let directory = working_directory(config, config_dir);

    let (program, args) = server_invocation(command, directory.as_deref());
    let mut spawner = tokio::process::Command::new(&program);
    spawner
        // Tells the child a handshake is coming on stdin. Without this the
        // child cannot tell a shell that will write from any other process
        // holding a silent pipe, and waiting for a line that never arrives
        // hangs it forever.
        .env("DESKTOP_RAILS_HANDSHAKE", "stdin")
        .args(&args)
        .stdin(Stdio::piped()) // the handshake goes in here, and EOF reaps the child
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // A backstop for the orphan rule: if the task that owns the child ever
        // goes away without stopping it, kill it rather than leave a server
        // running with nothing attached to it.
        .kill_on_drop(true);

    if let Some(dir) = &directory {
        spawner.current_dir(dir);
    }

    log::info!(
        "Starting the app server: {} (in {})",
        command,
        directory
            .as_ref()
            .map(|d| d.display().to_string())
            .unwrap_or_else(|| "the working directory".into())
    );

    let mut child = spawner
        .spawn()
        .map_err(|e| format!("Could not start the app server: {}", e))?;

    // One line of handshake, then the pipe stays open. The token travels here
    // rather than in the environment or the command line so another process on
    // the machine cannot read it out of `ps`.
    //
    // Holding the pipe open is also what reaps the server: a backend that reads
    // stdin exits on EOF, which is the only layer that survives the shell being
    // force-quit, since no Rust code runs then.
    let mut stdin = child.stdin.take();
    if let (Some(pipe), Some(control)) = (stdin.as_mut(), control) {
        use tokio::io::AsyncWriteExt;
        let line = serde_json::json!({
            "protocol": "1.0",
            "control": control.url,
            "token": control.token,
            "header": crate::control::TOKEN_HEADER,
        });
        if let Err(e) = pipe.write_all(format!("{}\n", line).as_bytes()).await {
            log::warn!("Could not hand the app server its handshake: {}", e);
        } else {
            let _ = pipe.flush().await;
            log::info!(
                "Handed the app server the control channel at {}",
                control.url
            );
        }
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // Registered so quitting the app stops the server it started.
    let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
    app.state::<crate::process_manager::ProcessManager>()
        .register(
            SERVER_PROCESS_ID.to_string(),
            command.to_string(),
            Vec::new(),
            kill_tx,
        )
        .await?;

    // Two tasks, not one. The child and its stdin are kept away from anything
    // that parses output: closing that pipe is how the server is told to exit,
    // so it must only ever happen deliberately. When both lived in the same
    // task, a panic while handling a line of output unwound the task, dropped
    // the pipe, and the server quit — moments after announcing its address.
    tauri::async_runtime::spawn(supervise(child, stdin, kill_rx));

    let app_for_output = app.clone();
    tauri::async_runtime::spawn(async move {
        use tauri::{Emitter, Manager};

        // The server's own output is the only clue when it fails to boot, so it
        // goes to the log rather than into a pipe nobody reads.
        let mut out = stdout.map(|s| BufReader::new(s).lines());
        let mut err = stderr.map(|s| BufReader::new(s).lines());

        while out.is_some() || err.is_some() {
            tokio::select! {
                line = async { match out.as_mut() { Some(l) => l.next_line().await, None => std::future::pending().await } } => {
                    match line {
                        Ok(Some(l)) => {
                            // The first line a bundled server writes says where
                            // it is listening. Anything else is ordinary output.
                            if let Some(url) = handshake_url(&l) {
                                log::info!("The app server is listening at {}", url);
                                // Announced first: moving the window to the app
                                // is the point, and it must not be lost to a
                                // failure in the bookkeeping below it.
                                let _ = app_for_output.emit("desktop-rails://server-ready", url.clone());
                                match app_for_output.try_state::<ServerAddress>() {
                                    Some(address) => address.set(url),
                                    // `state()` would panic here, and a panic in
                                    // this task used to cost us the server.
                                    None => log::warn!(
                                        "Nowhere to record the app server's address: ServerAddress was never managed"
                                    ),
                                }
                            } else {
                                log::info!("[server] {}", l);
                            }
                        }
                        _ => out = None,
                    }
                }
                line = async { match err.as_mut() { Some(l) => l.next_line().await, None => std::future::pending().await } } => {
                    match line { Ok(Some(l)) => log::warn!("[server] {}", l), _ => err = None }
                }
            }
        }
    });

    Ok(())
}

/// Own the app server until it is asked to stop, holding its stdin open.
///
/// The open pipe is the orphan rule: a backend that reads stdin exits when it
/// reaches EOF, which is the only layer that survives the shell being
/// force-quit, since no Rust code runs then. So this task holds the write end
/// and does nothing else that could fail.
async fn supervise(
    mut child: tokio::process::Child,
    stdin: Option<tokio::process::ChildStdin>,
    kill_rx: tokio::sync::oneshot::Receiver<()>,
) {
    let _stdin = stdin;
    let mut kill_rx = kill_rx;

    tokio::select! {
        _ = &mut kill_rx => {
            log::info!("Stopping the app server");
            let _ = child.kill().await;
        }
        status = child.wait() => {
            log::warn!("The app server exited: {:?}", status.ok().and_then(|s| s.code()));
        }
    }
}

/// ProcessManager id for the server, so it is distinguishable from anything the
/// web layer spawns through the shell bridge.
pub const SERVER_PROCESS_ID: &str = "desktop-rails:app-server";

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory holding one runnable launcher and one file that is not.
    ///
    /// What "runnable" means is platform-specific, and the fixture has to say
    /// so rather than assume unix: a permission bit there, an extension on
    /// Windows. Getting this wrong made two tests pass on macOS and fail on
    /// Windows for reasons that had nothing to do with the code under test.
    fn scratch_with_launcher(name: &str) -> (PathBuf, String) {
        let dir = std::env::temp_dir().join(format!("desktop-rails-invocation-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let launcher_name = if cfg!(unix) { "launch" } else { "launch.cmd" };
        let launcher = dir.join(launcher_name);
        std::fs::write(&launcher, if cfg!(unix) { "#!/bin/sh\nexit 0\n" } else { "@echo off\r\n" })
            .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        // Not runnable on either platform: no exec bit, and no runnable extension.
        std::fs::write(dir.join("not-executable"), "plain").unwrap();

        (dir, launcher_name.to_string())
    }

    #[test]
    fn an_executable_launcher_runs_without_a_shell() {
        // A login shell costs ~2.3s per launch, which is the entire budget an
        // app icon gets. A packaged app has its interpreter inside the bundle
        // and needs none of what the shell was for.
        let (dir, launcher) = scratch_with_launcher("plain");
        let (program, args) = server_invocation(&launcher, Some(&dir));

        assert!(args.is_empty(), "a direct exec takes no shell arguments");
        assert_eq!(PathBuf::from(&program), dir.join(&launcher));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_path_containing_a_space_is_passed_as_one_argument() {
        // Through `$SHELL -l -c` this word-splits and dies with exit 127:
        // "no such file or directory: /private/tmp/space". /Applications/My App.app
        // is an ordinary path, so this is not a corner case.
        let (dir, launcher) = scratch_with_launcher("with space");
        let (program, args) = server_invocation(&launcher, Some(&dir));

        assert!(program.contains(' '), "the fixture must actually contain a space");
        assert!(args.is_empty(), "the path must not be handed to a shell to re-split");
        assert!(PathBuf::from(&program).is_file());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_command_line_still_goes_through_a_shell() {
        // `bin/rails server -p 3000` is not a file, and a developer running it
        // has a version manager the login shell exists to set up.
        let (dir, _) = scratch_with_launcher("commandline");
        let (program, args) = server_invocation("bin/rails server -p 3000", Some(&dir));

        assert!(!args.is_empty(), "a command line needs a shell");
        assert!(args.iter().any(|a| a.contains("bin/rails server")));
        assert_ne!(program, "bin/rails server -p 3000");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_file_that_is_not_executable_is_not_run_directly() {
        // "Not executable" means different things per platform: a missing
        // permission bit on unix, a non-runnable extension on Windows. Either
        // way it must fall back to the shell rather than be handed to
        // CreateProcess or exec.
        let (dir, _) = scratch_with_launcher("notexec");
        let (_, args) = server_invocation("not-executable", Some(&dir));
        assert!(
            !args.is_empty(),
            "a non-executable falls back to the shell rather than failing"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[cfg(not(unix))]
    #[test]
    fn on_windows_a_runnable_extension_is_what_counts() {
        let (dir, _) = scratch_with_launcher("windows-ext");
        for (name, direct) in [("launch.cmd", true), ("launch.bat", true), ("launch.txt", false)] {
            std::fs::write(dir.join(name), "@echo off\r\n").unwrap();
            let (_, args) = server_invocation(name, Some(&dir));
            assert_eq!(
                args.is_empty(),
                direct,
                "{name} should {} run directly",
                if direct { "" } else { "not" }
            );
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_handshake_gives_up_the_address() {
        let line = r#"{"protocol":"1.0","url":"http://127.0.0.1:53411","pid":9}"#;
        assert_eq!(
            handshake_url(line),
            Some("http://127.0.0.1:53411".to_string())
        );
    }

    #[test]
    fn ordinary_server_output_is_not_a_handshake() {
        // A developer running `bin/rails server` by hand produces plenty of
        // this, and none of it should be mistaken for an address.
        for line in [
            "Puma starting in single mode...",
            "* Listening on http://127.0.0.1:3000",
            "",
            "{}",
            r#"{"url":"not-a-url"}"#,
            r#"{"url":42}"#,
            "{ broken json",
        ] {
            assert_eq!(handshake_url(line), None, "{line:?} should not parse as a handshake");
        }
    }

    fn configured() -> ServerConfig {
        ServerConfig {
            command: Some("bin/rails server".into()),
            directory: None,
        }
    }

    #[test]
    fn nothing_to_start_without_a_command() {
        assert_eq!(
            decide(&ServerConfig::default(), false),
            Decision::NotConfigured
        );
        assert_eq!(
            decide(
                &ServerConfig {
                    command: Some("   ".into()),
                    directory: None
                },
                false
            ),
            Decision::NotConfigured
        );
    }

    #[test]
    fn starts_when_nothing_is_listening() {
        assert_eq!(decide(&configured(), false), Decision::Start);
    }

    #[test]
    fn leaves_a_server_someone_else_is_running_alone() {
        // Starting a second one would fail on the port, and quitting the app
        // would kill a server the developer started by hand.
        assert_eq!(decide(&configured(), true), Decision::AlreadyRunning);
    }

    #[test]
    fn the_rails_app_is_a_level_above_the_config_by_default() {
        let dir = std::env::temp_dir().join("desktop-rails-server-default");
        let desktop = dir.join("desktop");
        std::fs::create_dir_all(&desktop).unwrap();

        let resolved = working_directory(&configured(), Some(&desktop)).unwrap();

        assert_eq!(resolved, dir.canonicalize().unwrap());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_explicit_directory_wins() {
        let dir = std::env::temp_dir().join("desktop-rails-server-explicit");
        let api = dir.join("api");
        std::fs::create_dir_all(&api).unwrap();

        let config = ServerConfig {
            command: Some("bin/rails server".into()),
            directory: Some("api".into()),
        };

        assert_eq!(
            working_directory(&config, Some(&dir)).unwrap(),
            api.canonicalize().unwrap()
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A stand-in for the bundled server: it exits when stdin reaches EOF, the
    /// way `packaging/templates/boot.rb` does, and leaves a file behind when it
    /// goes so the test can tell without racing on a pid.
    #[cfg(unix)]
    fn a_server_that_exits_on_eof(
        marker: &Path,
    ) -> (tokio::process::Child, tokio::process::ChildStdin) {
        let mut child = tokio::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("cat > /dev/null; : > '{}'", marker.display()))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("could not start the stand-in server");
        let stdin = child.stdin.take().expect("no stdin on the stand-in server");
        (child, stdin)
    }

    /// The regression. The task that parsed the server's output used to hold
    /// the child's stdin as well, so a panic while handling a line closed the
    /// pipe, and the server exited on EOF seconds after announcing its address.
    /// Supervision owns the pipe now, and nothing that parses can reach it.
    #[cfg(unix)]
    #[tokio::test]
    async fn the_server_outlives_a_panic_in_the_code_that_reads_its_output() {
        let marker = std::env::temp_dir().join("desktop-rails-supervise-panic");
        std::fs::remove_file(&marker).ok();
        let (child, stdin) = a_server_that_exits_on_eof(&marker);

        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
        let supervisor = tokio::spawn(supervise(child, Some(stdin), kill_rx));

        // What `state()` on unmanaged state did, in the task next door.
        let reader = tokio::spawn(async { panic!("something in the reader") });
        assert!(reader.await.is_err(), "the reader was supposed to panic");

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(
            !marker.exists(),
            "the app server saw EOF and exited when the output reader panicked"
        );

        // And it still stops when it is told to.
        kill_tx.send(()).ok();
        supervisor.await.ok();
        std::fs::remove_file(&marker).ok();
    }

    /// The other half of the contract: quitting the app stops the server it
    /// started, rather than leaving it behind on a port nobody remembers.
    #[cfg(unix)]
    #[tokio::test]
    async fn the_kill_signal_stops_the_server() {
        let marker = std::env::temp_dir().join("desktop-rails-supervise-kill");
        std::fs::remove_file(&marker).ok();
        let (child, stdin) = a_server_that_exits_on_eof(&marker);

        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
        let supervisor = tokio::spawn(supervise(child, Some(stdin), kill_rx));

        kill_tx.send(()).expect("nothing was listening for the kill");
        let stopped = tokio::time::timeout(std::time::Duration::from_secs(5), supervisor).await;
        assert!(stopped.is_ok(), "supervision did not return after the kill");
        std::fs::remove_file(&marker).ok();
    }

    fn address() -> url::Url {
        "http://127.0.0.1:51061".parse().unwrap()
    }

    /// The regression, seen on Windows: the server announced itself three
    /// seconds before WebView2 had a window up, the move was dropped, and the
    /// window waited on the error page for the connection monitor instead.
    #[test]
    fn an_announcement_before_the_window_exists_is_delivered_when_it_does() {
        let arrival = WindowArrival::default();

        assert_eq!(arrival.announced(address()), None, "there is no window to move yet");
        assert_eq!(arrival.window_ready(), Some(address()));
        assert_eq!(arrival.window_ready(), None, "delivered once, not on every call");
    }

    #[test]
    fn an_announcement_after_the_window_exists_is_delivered_at_once() {
        let arrival = WindowArrival::default();

        assert_eq!(arrival.window_ready(), None, "nothing was announced yet");
        assert_eq!(arrival.announced(address()), Some(address()));
        assert_eq!(arrival.window_ready(), None, "and it is not delivered a second time");
    }

    /// Both orders at once, many times: whichever wins, the window is moved
    /// exactly once.
    #[test]
    fn a_race_between_the_two_delivers_exactly_once() {
        for _ in 0..500 {
            let arrival = std::sync::Arc::new(WindowArrival::default());
            let announcer = {
                let arrival = arrival.clone();
                std::thread::spawn(move || arrival.announced(address()).is_some() as u8)
            };
            let from_window = arrival.window_ready().is_some() as u8;
            let from_announcement = announcer.join().unwrap();
            assert_eq!(from_window + from_announcement, 1);
        }
    }

    #[test]
    fn a_missing_directory_is_left_for_the_spawn_to_report() {
        let dir = std::env::temp_dir().join("desktop-rails-server-missing");
        let config = ServerConfig {
            command: Some("bin/rails server".into()),
            directory: Some("nope".into()),
        };

        assert_eq!(
            working_directory(&config, Some(&dir)).unwrap(),
            dir.join("nope")
        );
    }
}
