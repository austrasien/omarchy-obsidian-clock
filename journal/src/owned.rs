//! Todos this clock wrote, keyed per vault. Used to heal a daily note when
//! Obsidian Sync replaces it with a virgin Daily template (the other device
//! created the same path while this write had not been uploaded).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::config::Vault;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnedTodo {
    pub heading: String,
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct OwnedFile {
    days: BTreeMap<String, Vec<OwnedTodo>>,
}

fn cache_dir() -> PathBuf {
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    cache.join("obsidian-daily-qs").join("owned")
}

fn path_key(root: &Path) -> String {
    // FNV-1a 64, stable enough to isolate temp vaults from the user's store.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in root.display().to_string().bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn store_path(vault: &Vault) -> PathBuf {
    cache_dir().join(format!("{}.json", path_key(vault.root())))
}

fn load(vault: &Vault) -> OwnedFile {
    let path = store_path(vault);
    let Ok(raw) = fs::read_to_string(&path) else {
        return OwnedFile::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

fn save(vault: &Vault, file: &OwnedFile) {
    let dest = store_path(vault);
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if file.days.values().all(|v| v.is_empty()) {
        let _ = fs::remove_file(&dest);
        return;
    }
    if let Ok(json) = serde_json::to_string_pretty(file) {
        let _ = fs::write(&dest, json);
    }
}

pub fn remember(vault: &Vault, date: NaiveDate, heading: &str, text: &str) {
    let heading = heading.trim();
    let text = text.trim();
    if heading.is_empty() || text.is_empty() {
        return;
    }
    let key = date.format("%Y-%m-%d").to_string();
    let mut file = load(vault);
    let list = file.days.entry(key).or_default();
    if list
        .iter()
        .any(|item| item.heading.eq_ignore_ascii_case(heading) && item.text == text)
    {
        return;
    }
    list.push(OwnedTodo {
        heading: heading.to_string(),
        text: text.to_string(),
    });
    save(vault, &file);
}

pub fn list_for(vault: &Vault, date: NaiveDate) -> Vec<OwnedTodo> {
    let key = date.format("%Y-%m-%d").to_string();
    load(vault).days.get(&key).cloned().unwrap_or_default()
}

pub fn replace_for(vault: &Vault, date: NaiveDate, items: Vec<OwnedTodo>) {
    let key = date.format("%Y-%m-%d").to_string();
    let mut file = load(vault);
    if items.is_empty() {
        file.days.remove(&key);
    } else {
        file.days.insert(key, items);
    }
    save(vault, &file);
}
