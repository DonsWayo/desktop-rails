use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

/// Status of a tracked process.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum ProcessStatus {
    Running,
    Exited { code: Option<i32> },
    Killed,
    Failed { error: String },
}

/// Public metadata about a tracked process.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessInfo {
    pub id: String,
    pub command: String,
    pub args: Vec<String>,
    pub status: ProcessStatus,
    pub started_at: u64,
}

/// Internal entry holding metadata and the kill channel sender.
struct ProcessEntry {
    info: ProcessInfo,
    kill_sender: Option<tokio::sync::oneshot::Sender<()>>,
}

/// Ceiling on processes running at once, so a runaway caller cannot spawn
/// without bound. Exited entries stay in the map for status queries and do not
/// count against it.
const MAX_RUNNING_PROCESSES: usize = 64;

/// Shared state for tracking active child processes.
/// Registered via `app.manage()` in main.rs.
pub struct ProcessManager {
    processes: Arc<Mutex<HashMap<String, ProcessEntry>>>,
}

impl ProcessManager {
    pub fn new() -> Self {
        Self {
            processes: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Number of processes currently in the Running state.
    #[cfg(test)]
    pub async fn running_count(&self) -> usize {
        self.processes
            .lock()
            .await
            .values()
            .filter(|e| matches!(e.info.status, ProcessStatus::Running))
            .count()
    }

    /// Register a new process with status Running.
    ///
    /// Fails once `MAX_RUNNING_PROCESSES` are already running.
    pub async fn register(
        &self,
        id: String,
        command: String,
        args: Vec<String>,
        kill_sender: tokio::sync::oneshot::Sender<()>,
    ) -> Result<(), String> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        let mut procs = self.processes.lock().await;

        let running = procs
            .values()
            .filter(|e| matches!(e.info.status, ProcessStatus::Running))
            .count();
        if running >= MAX_RUNNING_PROCESSES {
            return Err(format!(
                "Refused: {} processes are already running (limit {})",
                running, MAX_RUNNING_PROCESSES
            ));
        }

        let entry = ProcessEntry {
            info: ProcessInfo {
                id: id.clone(),
                command,
                args,
                status: ProcessStatus::Running,
                started_at: now,
            },
            kill_sender: Some(kill_sender),
        };

        procs.insert(id, entry);
        Ok(())
    }

    /// Send a kill signal to a running process.
    pub async fn kill(&self, id: &str) -> Result<(), String> {
        let mut procs = self.processes.lock().await;
        let entry = procs.get_mut(id).ok_or_else(|| format!("Process '{}' not found", id))?;

        if let Some(sender) = entry.kill_sender.take() {
            sender.send(()).map_err(|_| format!("Process '{}' already exited", id))?;
            entry.info.status = ProcessStatus::Killed;
            Ok(())
        } else {
            Err(format!("Process '{}' is not running", id))
        }
    }

    /// Mark a process as exited with the given code.
    pub async fn mark_exited(&self, id: &str, code: Option<i32>) {
        if let Some(entry) = self.processes.lock().await.get_mut(id) {
            entry.info.status = ProcessStatus::Exited { code };
            entry.kill_sender = None;
        }
    }

    /// Mark a process as failed with an error message.
    pub async fn mark_failed(&self, id: &str, error: String) {
        if let Some(entry) = self.processes.lock().await.get_mut(id) {
            entry.info.status = ProcessStatus::Failed { error };
            entry.kill_sender = None;
        }
    }

    /// Get the status of a specific process.
    pub async fn status(&self, id: &str) -> Option<ProcessInfo> {
        self.processes.lock().await.get(id).map(|e| e.info.clone())
    }

    /// List all tracked processes.
    pub async fn list(&self) -> Vec<ProcessInfo> {
        self.processes
            .lock()
            .await
            .values()
            .map(|e| e.info.clone())
            .collect()
    }

    /// Kill all running processes (called on app exit).
    pub async fn kill_all(&self) {
        let mut procs = self.processes.lock().await;
        for entry in procs.values_mut() {
            if let Some(sender) = entry.kill_sender.take() {
                let _ = sender.send(());
                entry.info.status = ProcessStatus::Killed;
            }
        }
    }
}

/// Start a console program without giving it a console window.
///
/// The shell is a GUI program with no console. A console program it starts —
/// cmd.exe running a .cmd launcher, a shell command — would otherwise get a
/// console of its own, which Windows shows as a window over the app. Its
/// output still arrives through the pipes the caller sets up. Nothing to do
/// elsewhere, where there are no console windows.
pub fn without_console_window(command: &mut tokio::process::Command) -> &mut tokio::process::Command {
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What GetConsoleWindow says inside a child started with `command`: "0"
    /// when it has no console window.
    #[cfg(windows)]
    async fn console_window_of(mut command: tokio::process::Command) -> String {
        use base64::Engine;
        let script = "(Add-Type -Name Console -Namespace DesktopRails -PassThru -MemberDefinition \
            '[DllImport(\"kernel32.dll\")] public static extern IntPtr GetConsoleWindow();')::GetConsoleWindow()";
        let utf16: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let encoded = base64::engine::general_purpose::STANDARD.encode(utf16);
        command
            .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded.as_str()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let output = command.output().await.expect("powershell did not run");
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    /// The regression, from the Windows GUI job's screenshot: a cmd.exe console
    /// window over the app on every launch.
    ///
    /// The shell has no console, so a console child gets a new one. A test
    /// runner does have one, which a plain child would share, so the contrast
    /// is made with CREATE_NEW_CONSOLE: that is the shell's situation, and it
    /// shows the check can see a window at all.
    #[cfg(windows)]
    #[tokio::test]
    async fn a_console_program_started_by_the_shell_gets_no_console_window() {
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        let mut as_the_shell_did = tokio::process::Command::new("powershell");
        as_the_shell_did.creation_flags(CREATE_NEW_CONSOLE);
        assert_ne!(
            console_window_of(as_the_shell_did).await,
            "0",
            "a child with a console of its own was expected to have a window"
        );

        let mut hidden = tokio::process::Command::new("powershell");
        without_console_window(&mut hidden);
        assert_eq!(console_window_of(hidden).await, "0");
    }

    /// And the app server is started that way, not just able to be.
    #[cfg(windows)]
    #[tokio::test]
    async fn the_app_server_gets_no_console_window() {
        let server = crate::server::server_command("powershell", &[], None);
        assert_eq!(console_window_of(server).await, "0");
    }

    async fn register(pm: &ProcessManager, id: &str) -> Result<(), String> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        // Keep the receiver alive so the entry looks like a live process.
        std::mem::forget(rx);
        pm.register(id.to_string(), "sleep".into(), vec!["1".into()], tx)
            .await
    }

    #[tokio::test]
    async fn refuses_to_exceed_the_running_limit() {
        let pm = ProcessManager::new();

        for i in 0..MAX_RUNNING_PROCESSES {
            register(&pm, &format!("p{i}"))
                .await
                .expect("registration below the limit should succeed");
        }
        assert_eq!(pm.running_count().await, MAX_RUNNING_PROCESSES);

        let err = register(&pm, "one-too-many")
            .await
            .expect_err("registration past the limit should be refused");
        assert!(err.contains("already running"), "unexpected error: {err}");
    }

    #[tokio::test]
    async fn exited_processes_free_up_capacity() {
        let pm = ProcessManager::new();

        for i in 0..MAX_RUNNING_PROCESSES {
            register(&pm, &format!("p{i}")).await.unwrap();
        }
        pm.mark_exited("p0", Some(0)).await;

        assert_eq!(pm.running_count().await, MAX_RUNNING_PROCESSES - 1);
        register(&pm, "replacement")
            .await
            .expect("a finished process should free a slot");
    }
}
