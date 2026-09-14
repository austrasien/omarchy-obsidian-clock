//! Obsidian URI helpers and launching the desktop app.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::config::VaultError;

const TRAY_PLUGIN_IDS: &[&str] = &["background-tray", "obsidian-tray"];
const WAIT_RUNNING: Duration = Duration::from_secs(20);
const WAIT_WINDOW: Duration = Duration::from_secs(15);
const HIDE_GRACE: Duration = Duration::from_millis(100);
const POLL: Duration = Duration::from_millis(50);

/// Build `obsidian://open?path=…` for an absolute note path.
pub fn open_uri(path: &Path) -> String {
    let abs = path.display().to_string();
    let encoded = percent_encode_path(&abs);
    format!("obsidian://open?path={encoded}")
}

fn percent_encode_path(value: &str) -> String {
    let mut out = String::with_capacity(value.len() * 3);
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(b as char);
            }
            _ => {
                out.push('%');
                out.push(hex(b >> 4));
                out.push(hex(b & 0xf));
            }
        }
    }
    out
}

fn hex(n: u8) -> char {
    char::from(if n < 10 { b'0' + n } else { b'A' + (n - 10) })
}

/// Launch the URI via `xdg-open` (Omarchy / Wayland desktop).
pub fn launch(uri: &str) -> Result<(), VaultError> {
    let status = Command::new("xdg-open")
        .arg(uri)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| VaultError::Io(format!("failed to spawn xdg-open: {e}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(VaultError::Io(format!(
            "xdg-open exited with {}",
            status.code().unwrap_or(-1)
        )))
    }
}

fn spawn_xdg_open(uri: &str) {
    let _ = Command::new("xdg-open")
        .arg(uri)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// True when the Obsidian desktop app is already running.
///
/// Official Sync has no CLI. If the app is up, it watches the vault and
/// uploads by itself — we must not `xdg-open` on every checkbox (that steals
/// focus). If it is down, a write never leaves this machine.
pub fn is_running() -> bool {
    let Ok(entries) = fs::read_dir("/proc") else {
        return false;
    };
    for ent in entries.flatten() {
        let cmd = fs::read_to_string(ent.path().join("cmdline")).unwrap_or_default();
        if cmdline_is_obsidian_app(&cmd) {
            return true;
        }
    }
    false
}

fn cmdline_is_obsidian_app(cmdline: &str) -> bool {
    let cmd = cmdline.replace('\0', " ");
    if cmd.contains("--help") {
        return false;
    }
    cmd.contains("/usr/lib/obsidian/app.asar")
        || cmd.contains("/usr/lib/obsidian/obsidian.asar")
        || cmd.contains("md.obsidian.Obsidian")
        || cmd.contains("/opt/Obsidian/obsidian")
}

/// True when a close-to-tray community plugin is enabled for this vault.
pub fn tray_plugin_enabled(vault_root: &Path) -> bool {
    let list_path = vault_root.join(".obsidian").join("community-plugins.json");
    let Ok(text) = fs::read_to_string(list_path) else {
        return false;
    };
    let Ok(ids) = serde_json::from_str::<Vec<String>>(&text) else {
        return false;
    };
    ids.iter().any(|id| {
        TRAY_PLUGIN_IDS.contains(&id.as_str())
            && vault_root
                .join(".obsidian")
                .join("plugins")
                .join(id)
                .join("manifest.json")
                .is_file()
    })
}

/// After a clock write: start Obsidian if the app is closed, so Sync can
/// upload. When Background Tray (or Tray) is enabled, hide the window once
/// the plugin can intercept close. Short-lived CLI commands spawn a child
/// so they can return a snapshot immediately.
pub fn nudge_sync(vault_root: &Path) {
    if skip_ensure() || is_running() {
        return;
    }
    if spawn_ensure_child(vault_root).is_some() {
        return;
    }
    spawn_xdg_open(&open_uri(vault_root));
}

fn spawn_ensure_child(vault_root: &Path) -> Option<()> {
    let exe = std::env::current_exe().ok()?;
    Command::new(exe)
        .arg("--vault")
        .arg(vault_root)
        .arg("ensure-obsidian")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()
        .map(|_| ())
}

fn skip_ensure() -> bool {
    cfg!(test) || std::env::var_os("OBSIDIAN_DAILY_QS_NO_SYNC_NUDGE").is_some()
}

/// Start Obsidian when it is down. If a tray plugin is enabled, close the
/// window after it loads so the process stays in the tray for Sync.
pub fn ensure_obsidian(vault_root: &Path) {
    if skip_ensure() {
        return;
    }
    let Some(_lock) = EnsureLock::acquire() else {
        return;
    };
    if is_running() {
        return;
    }
    let hide = tray_plugin_enabled(vault_root);
    let uri = open_uri(vault_root);
    spawn_xdg_open(&uri);
    if !hide {
        return;
    }
    if !wait_until(WAIT_RUNNING, is_running) {
        return;
    }
    hide_to_tray(&uri);
}

/// Close as soon as the window exists. If that quits Obsidian (tray plugin
/// not hooked yet), relaunch and wait a bit longer before the next close.
fn hide_to_tray(uri: &str) {
    let delays_ms = [hide_grace().as_millis() as u64, 400, 800];
    for delay_ms in delays_ms {
        if !is_running() {
            spawn_xdg_open(uri);
            if !wait_until(WAIT_RUNNING, is_running) {
                return;
            }
        }
        if !wait_until(WAIT_WINDOW, || obsidian_window_address().is_some()) {
            return;
        }
        thread::sleep(Duration::from_millis(delay_ms));
        if !is_running() {
            continue;
        }
        close_obsidian_window();
        if hide_succeeded() {
            return;
        }
        if !is_running() {
            spawn_xdg_open(uri);
            continue;
        }
    }
}

fn hide_succeeded() -> bool {
    let deadline = Instant::now() + Duration::from_millis(300);
    while Instant::now() < deadline {
        thread::sleep(POLL);
        if !is_running() {
            return false;
        }
        if obsidian_window_address().is_none() {
            return true;
        }
    }
    is_running() && obsidian_window_address().is_none()
}

fn hide_grace() -> Duration {
    std::env::var("OBSIDIAN_DAILY_QS_TRAY_GRACE_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(HIDE_GRACE)
}

fn wait_until(limit: Duration, pred: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < limit {
        if pred() {
            return true;
        }
        thread::sleep(POLL);
    }
    pred()
}

fn class_is_obsidian(class: &str) -> bool {
    let c = class.to_ascii_lowercase();
    if c.contains("cursor") {
        return false;
    }
    c.contains("obsidian")
}

fn client_is_obsidian(class: &str, initial: &str, title: &str) -> bool {
    let class_l = class.to_ascii_lowercase();
    let initial_l = initial.to_ascii_lowercase();
    if class_l.contains("cursor") || initial_l.contains("cursor") {
        return false;
    }
    if class_is_obsidian(class) || class_is_obsidian(initial) {
        return true;
    }
    let title = title.to_ascii_lowercase();
    title.contains("obsidian")
}

fn parse_obsidian_window_address(clients_json: &str) -> Option<String> {
    let clients: Value = serde_json::from_str(clients_json).ok()?;
    for client in clients.as_array()? {
        let class = client.get("class").and_then(Value::as_str).unwrap_or("");
        let initial = client
            .get("initialClass")
            .and_then(Value::as_str)
            .unwrap_or("");
        let title = client.get("title").and_then(Value::as_str).unwrap_or("");
        if client_is_obsidian(class, initial, title) {
            return client
                .get("address")
                .and_then(Value::as_str)
                .map(str::to_string);
        }
    }
    None
}

fn obsidian_window_address() -> Option<String> {
    let mut cmd = hyprctl();
    let out = cmd.args(["clients", "-j"]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    parse_obsidian_window_address(&String::from_utf8_lossy(&out.stdout))
}

/// Omarchy's Hyprland is Lua-config: `hyprctl dispatch closewindow address:…`
/// is parsed as `hl.dispatch(closewindow address:…)` and fails. Close must be
/// a dispatcher object: `hl.dsp.window.close({ window = "address:0x…" })`.
fn close_lua_expr(window: &str) -> String {
    format!(r#"hl.dsp.window.close({{ window = "{window}" }})"#)
}

fn close_obsidian_window() {
    let window = obsidian_window_address()
        .map(|address| format!("address:{address}"))
        .unwrap_or_else(|| "class:md.obsidian.Obsidian".to_string());
    let expr = close_lua_expr(&window);
    let _ = hyprctl()
        .args(["dispatch", &expr])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn hyprctl() -> Command {
    let mut cmd = Command::new("hyprctl");
    if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none()
        && let Some(sig) = discover_hypr_signature()
    {
        cmd.env("HYPRLAND_INSTANCE_SIGNATURE", sig);
    }
    cmd
}

fn discover_hypr_signature() -> Option<String> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/user/1000"));
    let hypr = runtime.join("hypr");
    let mut names: Vec<String> = fs::read_dir(&hypr)
        .ok()?
        .flatten()
        .filter(|ent| ent.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|ent| ent.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names.into_iter().rev().find(|name| {
        let dir = hypr.join(name);
        dir.join(".socket.sock").exists() || dir.join("hyprland.lock").exists()
    })
}

struct EnsureLock {
    path: PathBuf,
}

impl EnsureLock {
    fn acquire() -> Option<Self> {
        let path = lock_path();
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        for _ in 0..2 {
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    let _ = writeln!(file, "{}", std::process::id());
                    return Some(Self { path });
                }
                Err(_) => {
                    if lock_is_stale(&path) {
                        let _ = fs::remove_file(&path);
                        continue;
                    }
                    return None;
                }
            }
        }
        None
    }
}

impl Drop for EnsureLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn lock_path() -> PathBuf {
    if let Ok(override_path) = std::env::var("OBSIDIAN_DAILY_QS_ENSURE_LOCK") {
        let trimmed = override_path.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    cache.join("obsidian-daily-qs").join("ensure-obsidian.lock")
}

fn lock_is_stale(path: &Path) -> bool {
    let Ok(text) = fs::read_to_string(path) else {
        return true;
    };
    let Ok(pid) = text.trim().parse::<u32>() else {
        return true;
    };
    !Path::new("/proc").join(pid.to_string()).exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn encodes_spaces_in_path() {
        let uri = open_uri(Path::new("/vault/Daily Notes/2026-08-20.md"));
        assert!(uri.starts_with("obsidian://open?path="));
        assert!(uri.contains("Daily%20Notes"));
        assert!(uri.contains("/2026-08-20.md"));
    }

    #[test]
    fn keeps_slashes() {
        let uri = open_uri(&PathBuf::from("/home/u/vault/a/b.md"));
        assert_eq!(uri, "obsidian://open?path=/home/u/vault/a/b.md");
    }

    #[test]
    fn detects_packaged_obsidian_electron() {
        let cmd = "/usr/lib/electron43/electron --disable-gpu /usr/lib/obsidian/app.asar";
        assert!(cmdline_is_obsidian_app(cmd));
        assert!(!cmdline_is_obsidian_app(
            "/usr/lib/electron43/electron --help /usr/lib/obsidian/app.asar"
        ));
        assert!(!cmdline_is_obsidian_app(
            "cursor-agent --worker-dir /home/u/Documents/Obsidian"
        ));
    }

    fn tmp_vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "obsidian-daily-qs-tray-{}-{}-{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(".obsidian")).unwrap();
        dir
    }

    #[test]
    fn tray_plugin_requires_enabled_id_and_manifest() {
        let root = tmp_vault("enabled");
        fs::write(
            root.join(".obsidian/community-plugins.json"),
            r#"["markdown-minimap","background-tray"]"#,
        )
        .unwrap();
        assert!(!tray_plugin_enabled(&root));
        fs::create_dir_all(root.join(".obsidian/plugins/background-tray")).unwrap();
        fs::write(
            root.join(".obsidian/plugins/background-tray/manifest.json"),
            "{}",
        )
        .unwrap();
        assert!(tray_plugin_enabled(&root));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn tray_plugin_ignores_disabled_install() {
        let root = tmp_vault("disabled");
        fs::create_dir_all(root.join(".obsidian/plugins/background-tray")).unwrap();
        fs::write(
            root.join(".obsidian/plugins/background-tray/manifest.json"),
            "{}",
        )
        .unwrap();
        fs::write(
            root.join(".obsidian/community-plugins.json"),
            r#"["markdown-minimap"]"#,
        )
        .unwrap();
        assert!(!tray_plugin_enabled(&root));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parses_hyprland_obsidian_client() {
        let json = r#"[{"address":"0xabc","class":"cursor","title":"Cursor"},{"address":"0xdef","class":"md.obsidian.Obsidian","title":"austrobs - Obsidian"}]"#;
        assert_eq!(
            parse_obsidian_window_address(json).as_deref(),
            Some("0xdef")
        );
        assert!(parse_obsidian_window_address(
            r#"[{"address":"0x1","class":"cursor","title":"obsidian-clock"}]"#
        )
        .is_none());
        assert_eq!(
            parse_obsidian_window_address(
                r#"[{"address":"0xeee","class":"electron","title":"austrobs - Obsidian 1.13.7"}]"#
            )
            .as_deref(),
            Some("0xeee")
        );
    }

    #[test]
    fn lua_close_expr_is_hyprctl_dispatchable() {
        assert_eq!(
            close_lua_expr("address:0xabc"),
            r#"hl.dsp.window.close({ window = "address:0xabc" })"#
        );
    }
}
