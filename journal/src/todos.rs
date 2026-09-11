//! Parse and mutate markdown checkbox todos in a daily note.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use regex::Regex;

use crate::config::{DailyNotesConfig, Vault, VaultError};
use crate::notes::{
    extract_first_h2_sections, extract_h2_sections, extract_section, h2_titles,
    replace_first_h2_sections, replace_or_append_section,
};
use crate::open;
use crate::status::{NoteSection, Snapshot, TodoItem};

/// Default notes heading: empty means the whole daily note is the journal.
pub const DEFAULT_NOTES_HEADING: &str = "";

/// How to pick todos and the free-form notes pane for a snapshot.
#[derive(Clone, Copy, Default)]
pub struct SnapshotFilter<'a> {
    /// Only todos under this `##` heading (e.g. `Tasks`). `None` = every checkbox.
    pub todo_heading: Option<&'a str>,
    /// Named notes heading. Ignored when [`Self::notes_h2_count`] is set.
    pub notes_heading: Option<&'a str>,
    /// First N `##` sections, headings included. Overrides `notes_heading`.
    pub notes_h2_count: Option<usize>,
}

impl SnapshotFilter<'_> {
    fn notes_from(&self, content: &str) -> String {
        if let Some(n) = self.notes_h2_count.filter(|n| *n > 0) {
            extract_first_h2_sections(content, n)
        } else {
            let notes_h = self
                .notes_heading
                .map(str::trim)
                .unwrap_or(DEFAULT_NOTES_HEADING);
            extract_section(content, notes_h)
        }
    }
}

fn checkbox_re() -> Regex {
    Regex::new(r"^(\s*)([-*+])\s+\[([ xX])\](\s+)(.*)$").expect("checkbox regex")
}

fn tasks_heading_re() -> Regex {
    // Accept both "Tasks" and "Todos" headings (case-insensitive).
    Regex::new(r"(?i)^#{1,6}\s+(tasks|todos)\s*$").expect("tasks heading regex")
}

/// Count indentation levels of a checkbox prefix: every tab is one level,
/// every two spaces one level (matches Obsidian's list indentation).
fn indent_level(indent: &str) -> usize {
    let tabs = indent.chars().filter(|c| *c == '\t').count();
    let spaces = indent.chars().filter(|c| *c == ' ').count();
    tabs + spaces / 2
}

/// Parse all checkbox todos from note body. Line numbers are 1-based.
///
/// Nested list items are normalized: each todo's `depth` is at most one level
/// deeper than the previous todo's, and `parent_line` points to the nearest
/// preceding todo at a shallower depth. An indented first todo has no parent
/// and is treated as top-level.
pub fn parse_todos(content: &str) -> Vec<TodoItem> {
    let re = checkbox_re();
    let mut todos = Vec::new();
    // Line numbers of open ancestors, indexed by depth (stack[d] has depth d).
    let mut stack: Vec<usize> = Vec::new();
    let mut last_depth = 0usize;
    for (idx, line) in content.lines().enumerate() {
        let Some(caps) = re.captures(line) else {
            continue;
        };
        let line_no = idx + 1;
        let checked = !caps[3].eq(" ");
        let text = caps[5].to_string();
        let raw = indent_level(&caps[1]);
        let depth = if stack.is_empty() {
            0
        } else {
            raw.min(last_depth + 1)
        };
        while stack.len() > depth {
            stack.pop();
        }
        let parent_line = stack.last().copied();
        stack.push(line_no);
        last_depth = depth;
        todos.push(TodoItem {
            line: line_no,
            checked,
            text,
            depth,
            parent_line,
        });
    }
    todos
}

pub fn read_snapshot(vault: &Vault, date: NaiveDate) -> Result<Snapshot, VaultError> {
    read_snapshot_with(vault, date, SnapshotFilter::default())
}

/// Resolve the path of `date`'s note: the live daily-notes folder wins, but a
/// note manually moved into the archive folder configured via
/// `--archive-folder` / the `archiveFolder` bar setting is still found.
fn resolved_note_path(
    vault: &Vault,
    config: &DailyNotesConfig,
    date: NaiveDate,
) -> Result<PathBuf, VaultError> {
    Ok(vault.daily_note_paths(config, date)?.resolved)
}

/// Like [`read_snapshot`], but when `heading` is set only todos under a
/// matching markdown heading (until the next same-or-higher heading) are
/// included. `notes_heading` selects the free-form notes section (default
/// [`DEFAULT_NOTES_HEADING`]).
pub fn read_snapshot_filtered(
    vault: &Vault,
    date: NaiveDate,
    heading: Option<&str>,
    notes_heading: Option<&str>,
) -> Result<Snapshot, VaultError> {
    read_snapshot_with(
        vault,
        date,
        SnapshotFilter {
            todo_heading: heading,
            notes_heading,
            notes_h2_count: None,
        },
    )
}

pub fn read_snapshot_with(
    vault: &Vault,
    date: NaiveDate,
    filter: SnapshotFilter<'_>,
) -> Result<Snapshot, VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    let date_str = date.format("%Y-%m-%d").to_string();
    let path_str = path.display().to_string();
    let (todos, notes, sections) = if path.exists() {
        let content = fs::read_to_string(&path)
            .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
        let all = parse_todos(&content);
        (
            filter_todos_by_heading(&content, all, filter.todo_heading),
            filter.notes_from(&content),
            extract_h2_sections(&content)
                .into_iter()
                .map(|(heading, body)| NoteSection { heading, body })
                .collect::<Vec<_>>(),
        )
    } else {
        (Vec::new(), String::new(), Vec::new())
    };
    let exists = path.exists();
    let mut snap = Snapshot::ok(date_str, path_str, exists, todos);
    snap.notes = Some(notes);
    snap.sections = Some(sections);
    enrich_snapshot(vault, date, &path, &config, &mut snap)?;
    Ok(snap)
}

/// Replace the notes section body for `date` (creating the note / heading
/// when needed) and return a fresh snapshot.
pub fn set_notes(
    vault: &Vault,
    date: NaiveDate,
    notes_heading: Option<&str>,
    body: &str,
) -> Result<Snapshot, VaultError> {
    set_notes_with(
        vault,
        date,
        SnapshotFilter {
            notes_heading,
            ..SnapshotFilter::default()
        },
        body,
    )
}

pub fn set_notes_with(
    vault: &Vault,
    date: NaiveDate,
    filter: SnapshotFilter<'_>,
    body: &str,
) -> Result<Snapshot, VaultError> {
    let notes_h = filter
        .notes_heading
        .map(str::trim)
        .unwrap_or(DEFAULT_NOTES_HEADING);
    if notes_h.contains('\n') || notes_h.contains('\r') {
        return Err(VaultError::Io("notes heading must be a single line".into()));
    }
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    ensure_note(vault, &config, &path, date)?;
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    let next = if let Some(n) = filter.notes_h2_count.filter(|n| *n > 0) {
        replace_first_h2_sections(&content, n, body)
    } else {
        replace_or_append_section(&content, notes_h, body)
    };
    write_atomic_with_undo(vault, date, &path, &content, &next)?;
    read_snapshot_with(vault, date, filter)
}

fn filter_todos_by_heading(
    content: &str,
    todos: Vec<TodoItem>,
    heading: Option<&str>,
) -> Vec<TodoItem> {
    let Some(want) = heading.map(str::trim).filter(|s| !s.is_empty()) else {
        return todos;
    };
    let want_l = want.to_lowercase();
    let lines: Vec<&str> = content.lines().collect();
    let heading_re = Regex::new(r"^(#{1,6})\s+(.+?)\s*$").expect("heading regex");
    // Inclusive start / exclusive end as 1-based file line numbers.
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        if let Some(caps) = heading_re.captures(lines[i]) {
            let level = caps[1].len();
            let title = caps[2].trim().to_lowercase();
            if title == want_l || title.contains(&want_l) {
                // Content under heading starts at the next line (1-based: i+2).
                let start = i + 2;
                let mut j = i + 1;
                while j < lines.len() {
                    if let Some(next) = heading_re.captures(lines[j])
                        && next[1].len() <= level
                    {
                        break;
                    }
                    j += 1;
                }
                // j is 0-based exclusive end index → 1-based exclusive = j+1
                ranges.push((start, j + 1));
            }
        }
        i += 1;
    }
    if ranges.is_empty() {
        return Vec::new();
    }
    todos
        .into_iter()
        .filter(|t| ranges.iter().any(|(a, b)| t.line >= *a && t.line < *b))
        .collect()
}

fn enrich_snapshot(
    vault: &Vault,
    date: NaiveDate,
    path: &Path,
    config: &DailyNotesConfig,
    snap: &mut Snapshot,
) -> Result<(), VaultError> {
    snap.obsidian_uri = Some(open::open_uri(path));
    let today = chrono::Local::now().date_naive();
    snap.is_today = Some(date == today);
    let prev = date.checked_sub_days(chrono::Days::new(1)).unwrap_or(date);
    snap.carry_over_count = Some(open_todo_count(vault, prev)?);
    if let Some(name) = config.template.clone() {
        snap.template_name = Some(name);
        let has_template = vault.template_path(config).is_some_and(|p| p.exists());
        snap.created_from_template = Some(has_template && path.exists());
    }
    let from_template = vault
        .template_path(config)
        .and_then(|p| fs::read_to_string(p).ok())
        .map(|body| h2_titles(&body, 16));
    let from_day = snap
        .sections
        .as_ref()
        .map(|secs| {
            secs.iter()
                .map(|s| s.heading.clone())
                .take(16)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    snap.template_headings = Some(match from_template {
        Some(heads) if !heads.is_empty() => heads,
        _ => from_day,
    });
    Ok(())
}

fn open_todo_count(vault: &Vault, date: NaiveDate) -> Result<usize, VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Ok(0);
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    Ok(parse_todos(&content).iter().filter(|t| !t.checked).count())
}

struct OpenTodo {
    depth: usize,
    text: String,
}

fn open_todo_items(vault: &Vault, date: NaiveDate) -> Result<Vec<OpenTodo>, VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    Ok(parse_todos(&content)
        .into_iter()
        .filter(|t| !t.checked)
        .map(|t| OpenTodo {
            depth: t.depth,
            text: t.text,
        })
        .collect())
}

/// Move yesterday's still-open todos into `date` (usually today), preserving
/// their nesting, and remove them from the previous note so it is left with
/// only its done todos. Todos whose parent was not carried are re-parented
/// under the nearest carried ancestor (depth is clamped to previous depth + 1).
/// Open todos that already exist in `date` are not duplicated and also stay
/// in the previous note. Returns the number of moved todos.
fn move_open_from_previous(vault: &Vault, date: NaiveDate) -> Result<usize, VaultError> {
    let prev = date
        .checked_sub_days(chrono::Days::new(1))
        .ok_or_else(|| VaultError::Io("date underflow".into()))?;
    // Create the target note up front without rolling over: otherwise
    // add_todo_lines's ensure_note would create it here and re-enter this
    // function. That nested run finished completely (appending the items and
    // emptying the previous note) before the outer add_todo_lines appended
    // the same lines again — duplicating every carried todo.
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    create_note_if_missing(vault, &config, &path, date)?;
    let items = open_todo_items(vault, prev)?;
    if items.is_empty() {
        return Ok(0);
    }
    let existing: std::collections::HashSet<String> = {
        let snap = read_snapshot(vault, date)?;
        snap.todos
            .unwrap_or_default()
            .into_iter()
            .filter(|t| !t.checked)
            .map(|t| t.text)
            .collect()
    };
    let to_move: Vec<(usize, String)> = items
        .into_iter()
        .filter(|item| !existing.contains(&item.text))
        .map(|item| (item.depth, item.text))
        .collect();
    if !to_move.is_empty() {
        add_todo_lines(vault, date, &to_move)?;
    }
    // Reconcile against the target's current open todos instead of only the
    // lines added above: if an earlier run added to the target but failed
    // before removing from the previous note (crash, write error), the
    // stranded items are still open in both notes and complete here.
    let target_open: Vec<(usize, String)> = {
        let snap = read_snapshot(vault, date)?;
        snap.todos
            .unwrap_or_default()
            .into_iter()
            .filter(|t| !t.checked)
            .map(|t| (t.depth, t.text))
            .collect()
    };
    remove_todos(vault, prev, &target_open)?;
    Ok(to_move.len())
}

/// Remove the given still-open todos (matched by text) from `date`'s note.
fn remove_todos(
    vault: &Vault,
    date: NaiveDate,
    items: &[(usize, String)],
) -> Result<(), VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Ok(());
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    let drop: std::collections::HashSet<usize> = parse_todos(&content)
        .into_iter()
        .filter(|t| !t.checked && items.iter().any(|(_, text)| text == &t.text))
        .map(|t| t.line)
        .collect();
    if drop.is_empty() {
        return Ok(());
    }
    let kept: Vec<&str> = content
        .lines()
        .enumerate()
        .filter(|(i, _)| !drop.contains(&(i + 1)))
        .map(|(_, line)| line)
        .collect();
    let mut next = kept.join("\n");
    if content.ends_with('\n') && !next.is_empty() {
        next.push('\n');
    }
    write_atomic(vault.root(), &path, &next)
}

/// Roll yesterday's open todos into `date` (usually today): they are moved,
/// so the previous note keeps only its done todos.
pub fn carry_over(vault: &Vault, date: NaiveDate) -> Result<Snapshot, VaultError> {
    move_open_from_previous(vault, date)?;
    read_snapshot(vault, date)
}

/// Move one still-open todo from `date` to the next calendar day, under the
/// same `##` heading (default `Tasks`). Creating tomorrow's note does **not**
/// roll over the rest of today's list.
pub fn defer_todo(
    vault: &Vault,
    date: NaiveDate,
    heading: Option<&str>,
    text: &str,
) -> Result<Snapshot, VaultError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(VaultError::Io("todo text is empty".into()));
    }
    if text.contains('\n') || text.contains('\r') {
        return Err(VaultError::Io("todo text must be a single line".into()));
    }
    let heading = heading
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Tasks");
    let tomorrow = date
        .checked_add_days(chrono::Days::new(1))
        .ok_or_else(|| VaultError::Io("date overflow".into()))?;

    let config = vault.daily_notes_config()?;
    let today_path = resolved_note_path(vault, &config, date)?;
    if !today_path.exists() {
        return Err(VaultError::Io(format!(
            "daily note does not exist: {}",
            today_path.display()
        )));
    }
    let today_content = fs::read_to_string(&today_path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", today_path.display())))?;
    let today_body = extract_section(&today_content, heading);
    let Some(stripped) = take_open_todo_from_body(&today_body, text) else {
        return Err(VaultError::Io(format!(
            "open todo {text:?} not found under ## {heading}"
        )));
    };

    let tomorrow_path = resolved_note_path(vault, &config, tomorrow)?;
    create_note_if_missing(vault, &config, &tomorrow_path, tomorrow)?;
    let tomorrow_content = fs::read_to_string(&tomorrow_path).map_err(|e| {
        VaultError::Io(format!(
            "failed to read {}: {e}",
            tomorrow_path.display()
        ))
    })?;
    let tomorrow_body = extract_section(&tomorrow_content, heading);
    if !body_has_open_todo(&tomorrow_body, text) {
        let tomorrow_next = replace_or_append_section(
            &tomorrow_content,
            heading,
            &append_open_todo(&tomorrow_body, text),
        );
        write_atomic_with_undo(
            vault,
            tomorrow,
            &tomorrow_path,
            &tomorrow_content,
            &tomorrow_next,
        )?;
    }

    let today_next = replace_or_append_section(&today_content, heading, &stripped);
    write_atomic_with_undo(vault, date, &today_path, &today_content, &today_next)?;
    read_snapshot(vault, date)
}

fn take_open_todo_from_body(body: &str, text: &str) -> Option<String> {
    let want = text.trim();
    let re = checkbox_re();
    let mut found = false;
    let mut kept: Vec<&str> = Vec::new();
    for line in body.lines() {
        if !found
            && let Some(caps) = re.captures(line)
            && caps[3].eq(" ")
            && caps[5].trim() == want
        {
            found = true;
            continue;
        }
        kept.push(line);
    }
    if !found {
        return None;
    }
    while kept.first().is_some_and(|line| line.trim().is_empty()) {
        kept.remove(0);
    }
    while kept.last().is_some_and(|line| line.trim().is_empty()) {
        kept.pop();
    }
    Some(kept.join("\n"))
}

fn body_has_open_todo(body: &str, text: &str) -> bool {
    let want = text.trim();
    let re = checkbox_re();
    body.lines().any(|line| {
        re.captures(line)
            .is_some_and(|caps| caps[3].eq(" ") && caps[5].trim() == want)
    })
}

fn append_open_todo(body: &str, text: &str) -> String {
    let line = format!("- [ ] {text}");
    let trimmed = body.trim_end();
    if trimmed.is_empty() {
        line
    } else {
        format!("{trimmed}\n{line}")
    }
}

/// Open the daily note in Obsidian via `xdg-open`.
pub fn open_in_obsidian(vault: &Vault, date: NaiveDate) -> Result<Snapshot, VaultError> {
    let snap = prepare_note_for_open(vault, date)?;
    let uri = snap
        .obsidian_uri
        .clone()
        .ok_or_else(|| VaultError::Io("missing obsidian URI".into()))?;
    open::launch(&uri)?;
    Ok(snap)
}

/// Create a missing note from the configured daily-note template before it is
/// opened. This deliberately skips carry-over: opening a future date must not
/// move unfinished todos out of the previous day.
fn prepare_note_for_open(vault: &Vault, date: NaiveDate) -> Result<Snapshot, VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    create_note_if_missing(vault, &config, &path, date)?;
    read_snapshot(vault, date)
}

/// Create the note (and parents) if missing, without rolling over. Returns
/// true when created.
fn create_note_if_missing(
    vault: &Vault,
    config: &DailyNotesConfig,
    path: &Path,
    date: NaiveDate,
) -> Result<bool, VaultError> {
    if path.exists() {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        create_dir_all_in_vault(vault.root(), parent)?;
    }
    let body = load_template_body(vault, config, date);
    write_atomic(vault.root(), path, &body)?;
    Ok(true)
}

/// Create today's note (and parents) if missing. Returns true when created.
pub fn ensure_note(
    vault: &Vault,
    config: &DailyNotesConfig,
    path: &Path,
    date: NaiveDate,
) -> Result<bool, VaultError> {
    let created = create_note_if_missing(vault, config, path, date)?;
    // First access of a new day: pull yesterday's open todos into the fresh
    // note and leave the previous one with only its done todos. Plain note
    // creation carries no rollover, so this cannot re-enter itself.
    if created {
        move_open_from_previous(vault, date)?;
    }
    Ok(created)
}

fn load_template_body(vault: &Vault, config: &DailyNotesConfig, date: NaiveDate) -> String {
    if let Some(template_path) = vault.template_path(config)
        && let Ok(raw) = fs::read_to_string(&template_path)
    {
        return expand_template(&raw, date);
    }
    format!("# {}\n", date.format("%Y-%m-%d"))
}

fn expand_template(raw: &str, date: NaiveDate) -> String {
    // Minimal Obsidian template tokens used in daily note templates.
    raw.replace("{{date}}", &date.format("%Y-%m-%d").to_string())
        .replace("{{date:YYYY-MM-DD}}", &date.format("%Y-%m-%d").to_string())
        .replace("{{time}}", "")
}

/// Append a new open todo. When `under_line` is set, nest one level under
/// that todo and insert immediately after it.
pub fn add_todo(vault: &Vault, date: NaiveDate, text: &str) -> Result<Snapshot, VaultError> {
    add_todo_under(vault, date, text, None)
}

pub fn add_todo_under(
    vault: &Vault,
    date: NaiveDate,
    text: &str,
    under_line: Option<usize>,
) -> Result<Snapshot, VaultError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(VaultError::Io("todo text is empty".into()));
    }
    if text.contains('\n') || text.contains('\r') {
        return Err(VaultError::Io("todo text must be a single line".into()));
    }
    match under_line {
        None => {
            add_todo_lines(vault, date, &[(0, text.to_string())])?;
        }
        Some(parent_line) => {
            if parent_line == 0 {
                return Err(VaultError::Io("under-line must be >= 1".into()));
            }
            let config = vault.daily_notes_config()?;
            let path = resolved_note_path(vault, &config, date)?;
            ensure_note(vault, &config, &path, date)?;
            let content = fs::read_to_string(&path)
                .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
            let todos = parse_todos(&content);
            let parent = todos
                .iter()
                .find(|t| t.line == parent_line)
                .ok_or_else(|| VaultError::Io(format!("under-line {parent_line} is not a todo")))?;
            let depth = parent.depth + 1;
            let insert_at = parent_line; // insert after this 1-based line
            let new_line = format!("{}- [ ] {}", "  ".repeat(depth), text);
            let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
            if insert_at > lines.len() {
                return Err(VaultError::Io(format!(
                    "under-line {parent_line} is past end of file"
                )));
            }
            lines.insert(insert_at, new_line);
            let mut next = lines.join("\n");
            if content.ends_with('\n') && !next.ends_with('\n') {
                next.push('\n');
            }
            write_atomic_with_undo(vault, date, &path, &content, &next)?;
        }
    }
    read_snapshot(vault, date)
}

/// Append the given `(depth, text)` todos as indented `- [ ] …` lines.
/// Depths are clamped so each line nests at most one level deeper than the
/// previous inserted line.
fn add_todo_lines(
    vault: &Vault,
    date: NaiveDate,
    items: &[(usize, String)],
) -> Result<(), VaultError> {
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    ensure_note(vault, &config, &path, date)?;
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    let mut prev_depth: Option<usize> = None;
    let lines: Vec<String> = items
        .iter()
        .map(|(depth, text)| {
            let d = match prev_depth {
                None => 0,
                Some(p) => (*depth).min(p + 1),
            };
            prev_depth = Some(d);
            format!("{}- [ ] {}", "  ".repeat(d), text)
        })
        .collect();
    let next = insert_todo_lines(&content, &lines);
    write_atomic_with_undo(vault, date, &path, &content, &next)
}

fn expect_line_text(
    content: &str,
    line: usize,
    expect_text: Option<&str>,
) -> Result<(), VaultError> {
    let Some(expected) = expect_text.map(str::trim).filter(|t| !t.is_empty()) else {
        return Ok(());
    };
    let at_line = parse_todos(content)
        .into_iter()
        .find(|t| t.line == line)
        .map(|t| t.text);
    match at_line {
        Some(actual) if actual.trim() == expected => Ok(()),
        Some(actual) => Err(VaultError::Io(format!(
            "stale view: line {line} now holds {:?} instead of {:?}; refetch and retry",
            actual.trim(),
            expected
        ))),
        None => Err(VaultError::Io(format!(
            "stale view: line {line} is no longer a todo; refetch and retry"
        ))),
    }
}

/// Toggle the checkbox on the given 1-based line.
pub fn toggle_todo(
    vault: &Vault,
    date: NaiveDate,
    line: usize,
    expect_text: Option<&str>,
) -> Result<Snapshot, VaultError> {
    if line == 0 {
        return Err(VaultError::Io("line must be >= 1".into()));
    }
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Err(VaultError::Io(format!(
            "daily note does not exist: {}",
            path.display()
        )));
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    expect_line_text(&content, line, expect_text)?;
    let next = toggle_line(&content, line)?;
    write_atomic_with_undo(vault, date, &path, &content, &next)?;
    read_snapshot(vault, date)
}

pub fn edit_todo(
    vault: &Vault,
    date: NaiveDate,
    line: usize,
    expect_text: Option<&str>,
    new_text: &str,
) -> Result<Snapshot, VaultError> {
    if line == 0 {
        return Err(VaultError::Io("line must be >= 1".into()));
    }
    let new_text = new_text.trim();
    if new_text.is_empty() {
        return Err(VaultError::Io("todo text is empty".into()));
    }
    if new_text.contains('\n') || new_text.contains('\r') {
        return Err(VaultError::Io("todo text must be a single line".into()));
    }
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Err(VaultError::Io(format!(
            "daily note does not exist: {}",
            path.display()
        )));
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    expect_line_text(&content, line, expect_text)?;
    let re = checkbox_re();
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    let idx = line - 1;
    if idx >= lines.len() {
        return Err(VaultError::Io(format!("line {line} is past end of file")));
    }
    let caps = re
        .captures(&lines[idx])
        .ok_or_else(|| VaultError::Io(format!("line {line} is not a checkbox todo")))?;
    lines[idx] = format!(
        "{}{} [{}]{}{}",
        &caps[1], &caps[2], &caps[3], &caps[4], new_text
    );
    let mut next = lines.join("\n");
    if content.ends_with('\n') && !next.ends_with('\n') {
        next.push('\n');
    }
    write_atomic_with_undo(vault, date, &path, &content, &next)?;
    read_snapshot(vault, date)
}

pub fn delete_todo(
    vault: &Vault,
    date: NaiveDate,
    line: usize,
    expect_text: Option<&str>,
    with_children: bool,
) -> Result<Snapshot, VaultError> {
    if line == 0 {
        return Err(VaultError::Io("line must be >= 1".into()));
    }
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Err(VaultError::Io(format!(
            "daily note does not exist: {}",
            path.display()
        )));
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    expect_line_text(&content, line, expect_text)?;
    let todos = parse_todos(&content);
    let target = todos
        .iter()
        .find(|t| t.line == line)
        .ok_or_else(|| VaultError::Io(format!("line {line} is not a todo")))?;
    let mut drop: std::collections::HashSet<usize> = std::collections::HashSet::new();
    drop.insert(line);
    if with_children {
        let parent_depth = target.depth;
        for t in todos.iter().skip_while(|t| t.line <= line) {
            if t.depth <= parent_depth {
                break;
            }
            drop.insert(t.line);
        }
    }
    let kept: Vec<&str> = content
        .lines()
        .enumerate()
        .filter(|(i, _)| !drop.contains(&(i + 1)))
        .map(|(_, line)| line)
        .collect();
    let mut next = kept.join("\n");
    if content.ends_with('\n') && !next.is_empty() {
        next.push('\n');
    }
    write_atomic_with_undo(vault, date, &path, &content, &next)?;
    read_snapshot(vault, date)
}

pub fn set_indent(
    vault: &Vault,
    date: NaiveDate,
    line: usize,
    expect_text: Option<&str>,
    delta: i32,
) -> Result<Snapshot, VaultError> {
    if line == 0 {
        return Err(VaultError::Io("line must be >= 1".into()));
    }
    if delta == 0 {
        return read_snapshot(vault, date);
    }
    let config = vault.daily_notes_config()?;
    let path = resolved_note_path(vault, &config, date)?;
    if !path.exists() {
        return Err(VaultError::Io(format!(
            "daily note does not exist: {}",
            path.display()
        )));
    }
    let content = fs::read_to_string(&path)
        .map_err(|e| VaultError::Io(format!("failed to read {}: {e}", path.display())))?;
    expect_line_text(&content, line, expect_text)?;
    let re = checkbox_re();
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    let idx = line - 1;
    if idx >= lines.len() {
        return Err(VaultError::Io(format!("line {line} is past end of file")));
    }
    let caps = re
        .captures(&lines[idx])
        .ok_or_else(|| VaultError::Io(format!("line {line} is not a checkbox todo")))?;
    let mut level = indent_level(&caps[1]) as i32;
    level = (level + delta).max(0);
    let indent = "  ".repeat(level as usize);
    lines[idx] = format!(
        "{}{} [{}]{}{}",
        indent, &caps[2], &caps[3], &caps[4], &caps[5]
    );
    let mut next = lines.join("\n");
    if content.ends_with('\n') && !next.ends_with('\n') {
        next.push('\n');
    }
    write_atomic_with_undo(vault, date, &path, &content, &next)?;
    read_snapshot(vault, date)
}

pub fn week_summary(
    vault: &Vault,
    anchor: NaiveDate,
) -> Result<crate::status::WeekSummary, VaultError> {
    week_summary_with(vault, anchor, SnapshotFilter {
        todo_heading: Some("tasks"),
        ..SnapshotFilter::default()
    })
}

pub fn week_summary_with(
    vault: &Vault,
    anchor: NaiveDate,
    filter: SnapshotFilter<'_>,
) -> Result<crate::status::WeekSummary, VaultError> {
    use crate::status::{DaySummary, WeekSummary};
    use chrono::Datelike;
    let today = chrono::Local::now().date_naive();
    let days_from_mon = anchor.weekday().num_days_from_monday();
    let monday = anchor
        .checked_sub_days(chrono::Days::new(days_from_mon as u64))
        .unwrap_or(anchor);
    let mut days = Vec::with_capacity(7);
    for offset in 0..7u64 {
        let d = monday
            .checked_add_days(chrono::Days::new(offset))
            .unwrap_or(monday);
        let snap = read_snapshot_with(vault, d, filter)?;
        days.push(DaySummary {
            date: d.format("%Y-%m-%d").to_string(),
            open_count: snap.open_count.unwrap_or(0),
            done_count: snap.done_count.unwrap_or(0),
            exists: snap.exists.unwrap_or(false),
            is_today: d == today,
            has_notes: crate::notes::has_journal_body(snap.notes.as_deref().unwrap_or("")),
        });
    }
    Ok(WeekSummary {
        state: crate::status::State::Ok,
        days: Some(days),
        error_code: None,
        error: None,
    })
}

/// Open/done counts for every day of `anchor`'s calendar month, plus enough
/// padding that a 6-week grid (any week start) can draw dots on leading and
/// trailing cells from the adjacent months.
pub fn month_summary(
    vault: &Vault,
    anchor: NaiveDate,
) -> Result<crate::status::WeekSummary, VaultError> {
    month_summary_with(
        vault,
        anchor,
        SnapshotFilter {
            todo_heading: Some("tasks"),
            ..SnapshotFilter::default()
        },
    )
}

pub fn month_summary_with(
    vault: &Vault,
    anchor: NaiveDate,
    filter: SnapshotFilter<'_>,
) -> Result<crate::status::WeekSummary, VaultError> {
    use crate::status::{DaySummary, WeekSummary};
    use chrono::Datelike;
    let today = chrono::Local::now().date_naive();
    let start = NaiveDate::from_ymd_opt(anchor.year(), anchor.month(), 1).unwrap_or(anchor);
    let next_month = if start.month() == 12 {
        NaiveDate::from_ymd_opt(start.year() + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(start.year(), start.month() + 1, 1)
    }
    .unwrap_or(start);
    let end = next_month.pred_opt().unwrap_or(start);
    let first = start
        .checked_sub_days(chrono::Days::new(7))
        .unwrap_or(start);
    let last = end.checked_add_days(chrono::Days::new(14)).unwrap_or(end);
    let span = (last - first).num_days().max(0) as u64 + 1;
    let mut days = Vec::with_capacity(span as usize);
    for offset in 0..span {
        let d = first
            .checked_add_days(chrono::Days::new(offset))
            .unwrap_or(first);
        let snap = read_snapshot_with(vault, d, filter)?;
        days.push(DaySummary {
            date: d.format("%Y-%m-%d").to_string(),
            open_count: snap.open_count.unwrap_or(0),
            done_count: snap.done_count.unwrap_or(0),
            exists: snap.exists.unwrap_or(false),
            is_today: d == today,
            has_notes: crate::notes::has_journal_body(snap.notes.as_deref().unwrap_or("")),
        });
    }
    Ok(WeekSummary {
        state: crate::status::State::Ok,
        days: Some(days),
        error_code: None,
        error: None,
    })
}

fn write_atomic_with_undo(
    vault: &Vault,
    date: NaiveDate,
    path: &Path,
    before: &str,
    after: &str,
) -> Result<(), VaultError> {
    crate::undo::record_before(vault, date, path, before)?;
    write_atomic(vault.root(), path, after)
}

/// Public wrapper used by the undo module to restore content.
pub fn write_atomic_public(
    vault_root: &Path,
    path: &Path,
    content: &str,
) -> Result<(), VaultError> {
    write_atomic(vault_root, path, content)
}

fn insert_todo_lines(content: &str, items: &[String]) -> String {
    let heading = tasks_heading_re();
    let any_heading = Regex::new(r"^(#{1,6})\s+.+?\s*$").expect("heading regex");
    let lines: Vec<&str> = content.lines().collect();
    let mut insert_at: Option<usize> = None;
    let mut needs_boundary_blank = false;
    for (idx, line) in lines.iter().enumerate() {
        if heading.is_match(line) {
            let level = line.chars().take_while(|ch| *ch == '#').count();
            let section_start = idx + 1;
            let mut section_end = section_start;
            let mut in_fence = false;
            while section_end < lines.len() {
                let trimmed = lines[section_end].trim_start();
                if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
                    in_fence = !in_fence;
                } else if !in_fence
                    && let Some(next) = any_heading.captures(lines[section_end])
                    && next[1].len() <= level
                {
                    break;
                }
                section_end += 1;
            }

            // Append after the section's existing content while keeping blank
            // lines that separate it from the next peer heading.
            let mut at = section_end;
            while at > section_start && lines[at - 1].trim().is_empty() {
                at -= 1;
            }
            // An otherwise-empty section conventionally keeps one blank line
            // between its heading and first todo.
            if at == section_start
                && section_start < section_end
                && lines[section_start].trim().is_empty()
            {
                at += 1;
                // If the section contained only a single blank line, there is
                // no remaining blank-line boundary after the insertion point;
                // add one so the new todos stay separated from the next peer
                // heading.
                if at == section_end {
                    needs_boundary_blank = true;
                }
            }
            insert_at = Some(at);
            break;
        }
    }

    let mut out: Vec<String> = lines.iter().map(|s| (*s).to_string()).collect();
    match insert_at {
        Some(at) => {
            for (offset, item) in items.iter().enumerate() {
                out.insert(at + offset, item.clone());
            }
            if needs_boundary_blank {
                out.insert(at + items.len(), String::new());
            }
        }
        None => {
            if !out.is_empty() && !out.last().map(|s| s.is_empty()).unwrap_or(true) {
                out.push(String::new());
            }
            out.extend(items.iter().cloned());
        }
    }
    let mut body = out.join("\n");
    if !body.ends_with('\n') {
        body.push('\n');
    }
    body
}

fn toggle_line(content: &str, line: usize) -> Result<String, VaultError> {
    let re = checkbox_re();
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    let idx = line - 1;
    if idx >= lines.len() {
        return Err(VaultError::Io(format!(
            "line {line} is past end of file ({} lines)",
            lines.len()
        )));
    }
    let current = lines[idx].clone();
    let caps = re
        .captures(&current)
        .ok_or_else(|| VaultError::Io(format!("line {line} is not a checkbox todo")))?;
    let checked = !caps[3].eq(" ");
    let mark = if checked { " " } else { "x" };
    lines[idx] = format!(
        "{}{} [{}]{}{}",
        &caps[1], &caps[2], mark, &caps[4], &caps[5]
    );
    let mut body = lines.join("\n");
    if content.ends_with('\n') && !body.ends_with('\n') {
        body.push('\n');
    }
    Ok(body)
}

/// Create `dir` and any missing parents after verifying its existing
/// ancestors stay inside the vault.
///
/// The nearest existing ancestor is canonicalized first, so a symlinked
/// daily-notes folder with a nested date format cannot cause directory
/// creation outside the vault: only plain, not-yet-existing directories are
/// created on top of the verified location.
fn create_dir_all_in_vault(vault_root: &Path, dir: &Path) -> Result<(), VaultError> {
    let root = vault_root.canonicalize().map_err(|e| {
        VaultError::Io(format!(
            "failed to resolve vault root {}: {e}",
            vault_root.display()
        ))
    })?;
    let anchor = dir
        .ancestors()
        .find(|a| a.exists())
        .ok_or_else(|| VaultError::Io(format!("no existing parent of {}", dir.display())))?;
    let real_anchor = anchor
        .canonicalize()
        .map_err(|e| VaultError::Io(format!("failed to resolve {}: {e}", anchor.display())))?;
    if !real_anchor.starts_with(&root) {
        return Err(VaultError::Io(format!(
            "refusing to create directories outside the vault: {} resolves to {}",
            anchor.display(),
            real_anchor.display()
        )));
    }
    fs::create_dir_all(dir)
        .map_err(|e| VaultError::Io(format!("failed to create {}: {e}", dir.display())))
}

/// Resolve the note's real location and verify it stays inside the vault.
///
/// The parent directory is canonicalized so a symlinked daily-notes folder is
/// followed to its real location; anything outside the (canonicalized) vault
/// root is refused. An existing note may itself be a symlink — if its target
/// lies inside the vault it is written through, otherwise the write is
/// refused.
fn resolve_note_target(vault_root: &Path, path: &Path) -> Result<PathBuf, VaultError> {
    let root = vault_root.canonicalize().map_err(|e| {
        VaultError::Io(format!(
            "failed to resolve vault root {}: {e}",
            vault_root.display()
        ))
    })?;
    let parent = path
        .parent()
        .ok_or_else(|| VaultError::Io(format!("note path has no parent: {}", path.display())))?;
    let real_parent = parent
        .canonicalize()
        .map_err(|e| VaultError::Io(format!("failed to resolve {}: {e}", parent.display())))?;
    if !real_parent.starts_with(&root) {
        return Err(VaultError::Io(format!(
            "refusing to write outside the vault: {} resolves to {}",
            parent.display(),
            real_parent.display()
        )));
    }
    let name = path
        .file_name()
        .ok_or_else(|| VaultError::Io(format!("note path has no file name: {}", path.display())))?;
    let resolved = real_parent.join(name);
    // A missing note is created at the already-verified parent; a note that
    // resolves through symlinks must end up inside the vault.
    match fs::canonicalize(&resolved) {
        Ok(real) if real.starts_with(&root) => Ok(real),
        Ok(real) => Err(VaultError::Io(format!(
            "refusing to write outside the vault: {} resolves to {}",
            path.display(),
            real.display()
        ))),
        Err(_) => Ok(resolved),
    }
}

/// Unpredictable sibling of `target`: same directory so the final rename
/// stays atomic, random suffix so a pre-created path cannot collide.
fn temp_path_for(target: &Path) -> PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut name = target
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(format!(
        ".tmp-obsidian-daily-qs-{}-{nonce}",
        std::process::id()
    ));
    target.with_file_name(name)
}

fn write_atomic(vault_root: &Path, path: &Path, content: &str) -> Result<(), VaultError> {
    let target = resolve_note_target(vault_root, path)?;
    let tmp = temp_path_for(&target);
    let write_result = (|| {
        // `create_new` is O_CREAT|O_EXCL: it fails if anything — including a
        // symlink — already sits at the temp path, so a pre-created link
        // cannot redirect this write. The parent was canonicalized above, so
        // the temp file cannot escape through a symlinked directory either.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(|e| VaultError::Io(format!("failed to create {}: {e}", tmp.display())))?;
        file.write_all(content.as_bytes())
            .map_err(|e| VaultError::Io(format!("failed to write {}: {e}", tmp.display())))?;
        file.sync_all()
            .map_err(|e| VaultError::Io(format!("failed to sync {}: {e}", tmp.display())))?;
        Ok(())
    })();
    if let Err(err) = write_result {
        // Never leave an orphaned temp file behind in the vault.
        let _ = fs::remove_file(&tmp);
        return Err(err);
    }
    // Preserve the existing note's permissions across the atomic replace;
    // the temp file would otherwise carry umask defaults (a 0600 note would
    // become world-readable).
    #[cfg(unix)]
    if let Ok(meta) = fs::metadata(&target) {
        let _ = fs::set_permissions(&tmp, meta.permissions());
    }
    fs::rename(&tmp, &target).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        VaultError::Io(format!("failed to replace {}: {e}", target.display()))
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::DailyNotesConfig;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_SEQ: AtomicU64 = AtomicU64::new(0);

    fn unique_temp(prefix: &str) -> std::path::PathBuf {
        let n = TEMP_SEQ.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "obsidian-daily-qs-{prefix}-{}-{}-{}",
            std::process::id(),
            n,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn vault_with(content: &str) -> (Vault, NaiveDate, std::path::PathBuf) {
        let root = unique_temp("todos");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD"}"#,
        )
        .unwrap();
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        let note = root.join("Daily").join("2026-08-20.md");
        fs::create_dir_all(note.parent().unwrap()).unwrap();
        fs::write(&note, content).unwrap();
        (
            Vault {
                root,
                archive: None,
            },
            date,
            note,
        )
    }

    #[test]
    fn parses_mixed_checkboxes() {
        let todos = parse_todos(
            "# Day\n\n- [ ] open\n* [x] done\n+ [X] also\nnot a todo\n  - [ ] indented\n",
        );
        assert_eq!(todos.len(), 4);
        assert!(!todos[0].checked);
        assert_eq!(todos[0].line, 3);
        assert!(todos[1].checked);
        assert!(todos[2].checked);
        assert_eq!(todos[3].line, 7);
        assert_eq!(todos[3].text, "indented");
    }

    #[test]
    fn parses_nested_todos() {
        let todos = parse_todos(
            "- [ ] parent\n\t- [ ] tab-child\n  - [ ] space-child\n    - [ ] grand-child\n- [ ] sibling\n",
        );
        assert_eq!(todos.len(), 5);
        assert_eq!(todos[0].depth, 0);
        assert_eq!(todos[0].parent_line, None);
        // Tab and two spaces are both one level.
        assert_eq!(todos[1].depth, 1);
        assert_eq!(todos[1].parent_line, Some(todos[0].line));
        assert_eq!(todos[2].depth, 1);
        assert_eq!(todos[2].parent_line, Some(todos[0].line));
        assert_eq!(todos[3].depth, 2);
        assert_eq!(todos[3].parent_line, Some(todos[2].line));
        assert_eq!(todos[4].depth, 0);
        assert_eq!(todos[4].parent_line, None);
    }

    #[test]
    fn normalizes_deep_indentation_and_lone_nested_todos() {
        // A todo can only nest one level deeper than the previous one, and an
        // indented first todo has no parent, so it becomes top-level.
        let todos = parse_todos("      - [ ] orphan\n- [ ] parent\n        - [ ] child\n");
        assert_eq!(todos[0].depth, 0);
        assert_eq!(todos[0].parent_line, None);
        assert_eq!(todos[1].depth, 0);
        assert_eq!(todos[2].depth, 1);
        assert_eq!(todos[2].parent_line, Some(todos[1].line));
    }

    #[test]
    fn adds_under_todos_heading() {
        let (vault, date, note) = vault_with("# Day\n\n## Todos\n\n- [ ] existing\n\n## Notes\n");
        add_todo(&vault, date, "new one").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert_eq!(
            body,
            "# Day\n\n## Todos\n\n- [ ] existing\n- [ ] new one\n\n## Notes\n"
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn adds_under_tasks_heading() {
        let (vault, date, note) = vault_with("# Day\n\n## Tasks\n\n- [ ] existing\n\n## Notes\n");
        add_todo(&vault, date, "new one").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert_eq!(
            body,
            "# Day\n\n## Tasks\n\n- [ ] existing\n- [ ] new one\n\n## Notes\n"
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn appends_after_nested_content_in_todo_section() {
        let (vault, date, note) = vault_with(
            "# Day\n\n## Todos\n\n- [ ] first\n\n### Later\n\n- [ ] second\n\n## Notes\n",
        );
        add_todo(&vault, date, "last").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert_eq!(
            body,
            "# Day\n\n## Todos\n\n- [ ] first\n\n### Later\n\n- [ ] second\n- [ ] last\n\n## Notes\n"
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn ignores_heading_like_lines_inside_fenced_code_block() {
        let (vault, date, note) =
            vault_with("# Day\n\n## Todos\n\n- [ ] first\n\n```\n## fake\n```\n\n## Notes\n");
        add_todo(&vault, date, "last").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert_eq!(
            body,
            "# Day\n\n## Todos\n\n- [ ] first\n\n```\n## fake\n```\n- [ ] last\n\n## Notes\n"
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn preserves_blank_line_boundary_in_empty_section() {
        let (vault, date, note) = vault_with("# Day\n\n## Todos\n\n## Notes\n");
        add_todo(&vault, date, "new one").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert_eq!(body, "# Day\n\n## Todos\n\n- [ ] new one\n\n## Notes\n");
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn appends_when_no_tasks_heading() {
        let (vault, date, note) = vault_with("# Day\n\nhello\n");
        add_todo(&vault, date, "solo").unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert!(body.ends_with("- [ ] solo\n"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn toggles_checkbox() {
        let (vault, date, note) = vault_with("- [ ] open\n- [x] done\n");
        toggle_todo(&vault, date, 1, None).unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert!(body.starts_with("- [x] open\n"));
        toggle_todo(&vault, date, 2, None).unwrap();
        let body = fs::read_to_string(&note).unwrap();
        assert!(body.contains("- [ ] done\n"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn toggles_when_expected_text_matches() {
        let (vault, date, note) = vault_with("- [ ] open\n- [x] done\n");
        toggle_todo(&vault, date, 1, Some("open")).unwrap();
        assert!(
            fs::read_to_string(&note)
                .unwrap()
                .starts_with("- [x] open\n")
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn refuses_toggle_on_stale_line() {
        let (vault, date, note) = vault_with("- [ ] first\n- [ ] second\n");
        // The snapshot was rendered before a second todo was inserted above;
        // line 1 now holds different text than the caller saw.
        let err = toggle_todo(&vault, date, 1, Some("second")).unwrap_err();
        assert!(err.to_string().contains("stale view"), "err: {err}");
        assert_eq!(
            fs::read_to_string(&note).unwrap(),
            "- [ ] first\n- [ ] second\n"
        );
        // A line that is no longer a todo at all is also refused.
        let err = toggle_todo(&vault, date, 1, Some("gone")).unwrap_err();
        assert!(err.to_string().contains("stale view"), "err: {err}");
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn creates_note_from_template_on_add() {
        let root = unique_temp("create");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join("Templates")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD","template":"Templates/Daily"}"#,
        )
        .unwrap();
        fs::write(
            root.join("Templates/Daily.md"),
            "# {{date:YYYY-MM-DD}}\n\n## Tasks\n\n",
        )
        .unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        add_todo(&vault, date, "first").unwrap();
        let note = root.join("Daily/2026-08-20.md");
        let body = fs::read_to_string(&note).unwrap();
        assert!(body.contains("# 2026-08-20"));
        assert!(body.contains("## Tasks"));
        assert!(body.contains("- [ ] first"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn prepares_missing_note_from_template_before_open() {
        let root = unique_temp("open-create");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join("Templates")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD","template":"Templates/Daily"}"#,
        )
        .unwrap();
        fs::write(
            root.join("Templates/Daily.md"),
            "# {{date:YYYY-MM-DD}}\n\n## Tasks\n\n",
        )
        .unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 21).unwrap();

        let snap = prepare_note_for_open(&vault, date).unwrap();

        assert_eq!(snap.exists, Some(true));
        assert_eq!(
            fs::read_to_string(root.join("Daily/2026-08-21.md")).unwrap(),
            "# 2026-08-21\n\n## Tasks\n\n"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn preparing_future_note_does_not_carry_over_todos() {
        let root = unique_temp("open-future");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join("Daily")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD"}"#,
        )
        .unwrap();
        fs::write(root.join("Daily/2026-08-20.md"), "- [ ] keep here\n").unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 21).unwrap();

        prepare_note_for_open(&vault, date).unwrap();

        assert_eq!(
            fs::read_to_string(root.join("Daily/2026-08-20.md")).unwrap(),
            "- [ ] keep here\n"
        );
        assert_eq!(
            fs::read_to_string(root.join("Daily/2026-08-21.md")).unwrap(),
            "# 2026-08-21\n"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn preparing_archived_note_does_not_create_a_live_copy() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        let (vault, archived) = archived_vault(date, "# Archived\n");

        let snap = prepare_note_for_open(&vault, date).unwrap();

        assert_eq!(snap.path, Some(archived.display().to_string()));
        assert_eq!(fs::read_to_string(&archived).unwrap(), "# Archived\n");
        assert!(!vault.root().join("dailies/2026-08-20.md").exists());
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn carry_over_preserves_nesting() {
        let (vault, today, _) = vault_with("- [ ] keep\n");
        let ynote = vault.root().join("Daily").join("2026-08-19.md");
        fs::write(
            &ynote,
            "- [ ] parent\n  - [ ] child\n  - [x] done-child\n- [x] finished\n- [ ] solo\n",
        )
        .unwrap();
        let snap = carry_over(&vault, today).unwrap();
        let todos = snap.todos.unwrap();
        assert_eq!(todos.len(), 4);
        assert_eq!(todos[0].text, "keep");
        assert_eq!(todos[1].text, "parent");
        assert_eq!(todos[1].depth, 0);
        assert_eq!(todos[2].text, "child");
        assert_eq!(todos[2].depth, 1);
        assert_eq!(todos[2].parent_line, Some(todos[1].line));
        assert_eq!(todos[3].text, "solo");
        assert_eq!(todos[3].depth, 0);
        let note = vault.root().join("Daily/2026-08-20.md");
        let body = fs::read_to_string(&note).unwrap();
        assert!(body.contains("- [ ] parent\n  - [ ] child\n- [ ] solo\n"));
        assert!(!body.contains("done-child"));
        assert!(!body.contains("finished"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn carry_over_reparents_orphaned_children() {
        // Child of a checked parent: the parent is not carried, so the child
        // is clamped to one level under the previous carried todo.
        let (vault, today, _) = vault_with("");
        let ynote = vault.root().join("Daily").join("2026-08-19.md");
        fs::write(&ynote, "- [x] parent\n    - [ ] deep-child\n").unwrap();
        let snap = carry_over(&vault, today).unwrap();
        let todos = snap.todos.unwrap();
        assert_eq!(todos.len(), 1);
        assert_eq!(todos[0].text, "deep-child");
        assert_eq!(todos[0].depth, 0);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn ensure_note_is_noop_when_present() {
        let (vault, date, note) = vault_with("keep\n");
        let config = DailyNotesConfig {
            folder: "Daily".into(),
            format: "YYYY-MM-DD".into(),
            template: None,
            archive: None,
        };
        assert!(!ensure_note(&vault, &config, &note, date).unwrap());
        assert_eq!(fs::read_to_string(&note).unwrap(), "keep\n");
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn carry_over_moves_open_from_previous_day() {
        let (vault, today, _) = vault_with("- [ ] today-only\n");
        let ynote = vault.root().join("Daily").join("2026-08-19.md");
        fs::write(&ynote, "- [ ] leftover\n- [x] finished\n").unwrap();
        let snap = carry_over(&vault, today).unwrap();
        let texts: Vec<_> = snap.todos.unwrap().into_iter().map(|t| t.text).collect();
        assert!(texts.contains(&"leftover".to_string()));
        assert!(texts.contains(&"today-only".to_string()));
        assert!(!texts.iter().any(|t| t == "finished"));
        // Moved, not copied: the previous note keeps only its done todos.
        assert_eq!(fs::read_to_string(&ynote).unwrap(), "- [x] finished\n");
        // Idempotent: second carry-over does not duplicate.
        let snap2 = carry_over(&vault, today).unwrap();
        assert_eq!(
            snap2
                .todos
                .unwrap()
                .iter()
                .filter(|t| t.text == "leftover")
                .count(),
            1
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn carry_over_completes_interrupted_move() {
        // Simulate a crash between "add to today" and "remove from
        // yesterday": the todo is open in both notes. The next carry-over
        // must still empty the previous note instead of stranding it.
        let (vault, today, _) = vault_with("- [ ] ghost\n");
        let ynote = vault.root().join("Daily").join("2026-08-19.md");
        fs::write(&ynote, "- [ ] ghost\n- [x] done\n").unwrap();
        carry_over(&vault, today).unwrap();
        assert_eq!(fs::read_to_string(&ynote).unwrap(), "- [x] done\n");
        let texts: Vec<_> = read_snapshot(&vault, today)
            .unwrap()
            .todos
            .unwrap()
            .into_iter()
            .map(|t| t.text)
            .collect();
        assert_eq!(texts.iter().filter(|t| *t == "ghost").count(), 1);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn carry_over_into_missing_note_does_not_duplicate() {
        // First mutation of the day: the target note does not exist yet.
        // Creating it must not re-enter the rollover and append every
        // carried item twice.
        let root = unique_temp("carry-missing");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join("Daily")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD"}"#,
        )
        .unwrap();
        fs::write(
            root.join("Daily/2026-08-19.md"),
            "- [ ] drag along\n  - [ ] nested\n- [x] done yesterday\n",
        )
        .unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        let snap = carry_over(&vault, date).unwrap();
        let todos = snap.todos.unwrap();
        assert_eq!(todos.len(), 2);
        assert_eq!(todos[0].text, "drag along");
        assert_eq!(todos[0].depth, 0);
        assert_eq!(todos[1].text, "nested");
        assert_eq!(todos[1].depth, 1);
        let body = fs::read_to_string(vault.root().join("Daily/2026-08-20.md")).unwrap();
        assert_eq!(body.matches("- [ ] drag along").count(), 1, "body: {body}");
        assert_eq!(body.matches("- [ ] nested").count(), 1, "body: {body}");
        assert_eq!(
            fs::read_to_string(vault.root().join("Daily/2026-08-19.md")).unwrap(),
            "- [x] done yesterday\n"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn defer_todo_moves_open_task_to_next_day() {
        let content = "## Notes\nhello\n## Tasks\n- [ ] ship\n- [ ] stay\n- [x] done\n";
        let (vault, date, today) = vault_with(content);
        defer_todo(&vault, date, Some("Tasks"), "ship").unwrap();
        let today_body = fs::read_to_string(&today).unwrap();
        assert!(
            !today_body.contains("- [ ] ship"),
            "today still has ship: {today_body}"
        );
        assert!(today_body.contains("- [ ] stay"));
        assert!(today_body.contains("- [x] done"));
        let tomorrow = vault.root().join("Daily/2026-08-21.md");
        let tomorrow_body = fs::read_to_string(&tomorrow).unwrap();
        assert!(tomorrow_body.contains("## Tasks"));
        assert!(tomorrow_body.contains("- [ ] ship"));
        assert!(!tomorrow_body.contains("- [ ] stay"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn defer_todo_does_not_roll_other_open_todos() {
        let content = "## Tasks\n- [ ] ship\n- [ ] other\n";
        let (vault, date, today) = vault_with(content);
        defer_todo(&vault, date, Some("Tasks"), "ship").unwrap();
        assert!(fs::read_to_string(&today).unwrap().contains("- [ ] other"));
        let tomorrow_body = fs::read_to_string(vault.root().join("Daily/2026-08-21.md")).unwrap();
        assert!(tomorrow_body.contains("- [ ] ship"));
        assert!(
            !tomorrow_body.contains("- [ ] other"),
            "rolled other todos: {tomorrow_body}"
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn defer_todo_keeps_review_heading() {
        let content = "## Tasks\n- [ ] ship\n## Morning review\n- [ ] meditate\n";
        let (vault, date, today) = vault_with(content);
        defer_todo(&vault, date, Some("Morning review"), "meditate").unwrap();
        let today_body = fs::read_to_string(&today).unwrap();
        assert!(today_body.contains("- [ ] ship"));
        assert!(!today_body.contains("- [ ] meditate"));
        let tomorrow_body = fs::read_to_string(vault.root().join("Daily/2026-08-21.md")).unwrap();
        assert!(tomorrow_body.contains("## Morning review"));
        assert!(tomorrow_body.contains("- [ ] meditate"));
        assert!(!tomorrow_body.contains("- [ ] ship"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn defer_todo_does_not_duplicate_existing_tomorrow_item() {
        let (vault, date, today) = vault_with("## Tasks\n- [ ] ship\n");
        let tomorrow = vault.root().join("Daily/2026-08-21.md");
        fs::write(&tomorrow, "## Tasks\n- [ ] ship\n").unwrap();
        defer_todo(&vault, date, Some("Tasks"), "ship").unwrap();
        assert!(!fs::read_to_string(&today).unwrap().contains("- [ ] ship"));
        assert_eq!(
            fs::read_to_string(&tomorrow)
                .unwrap()
                .matches("- [ ] ship")
                .count(),
            1
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn creating_note_rolls_previous_day_over() {
        let root = unique_temp("rollover");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join("Daily")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY-MM-DD"}"#,
        )
        .unwrap();
        fs::write(
            root.join("Daily/2026-08-19.md"),
            "- [ ] drag along\n  - [ ] nested\n- [x] done yesterday\n",
        )
        .unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        // First write of the new day creates the note and rolls yesterday's
        // open todos into it.
        add_todo(&vault, date, "fresh").unwrap();
        let body = fs::read_to_string(vault.root().join("Daily/2026-08-20.md")).unwrap();
        assert!(body.contains("- [ ] drag along\n  - [ ] nested\n"));
        assert!(body.contains("- [ ] fresh"));
        assert_eq!(
            fs::read_to_string(vault.root().join("Daily/2026-08-19.md")).unwrap(),
            "- [x] done yesterday\n"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_preserves_note_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let (vault, date, note) = vault_with("- [ ] open\n");
        fs::set_permissions(&note, fs::Permissions::from_mode(0o600)).unwrap();
        toggle_todo(&vault, date, 1, None).unwrap();
        let mode = fs::metadata(&note).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_write_through_symlinked_note_folder() {
        use std::os::unix::fs::symlink;
        let (vault, date, _note) = vault_with("- [ ] open\n");
        let outside = unique_temp("outside-folder");
        fs::create_dir_all(&outside).unwrap();
        let daily = vault.root().join("Daily");
        fs::remove_dir_all(&daily).unwrap();
        symlink(&outside, &daily).unwrap();
        let err = add_todo(&vault, date, "nope").unwrap_err();
        assert!(err.to_string().contains("outside the vault"), "err: {err}");
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
        let _ = fs::remove_dir_all(vault.root());
        let _ = fs::remove_dir_all(outside);
    }

    #[cfg(unix)]
    #[test]
    fn refuses_note_creation_through_symlinked_folder_with_nested_format() {
        use std::os::unix::fs::symlink;
        let root = unique_temp("nested-symlink");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"Daily","format":"YYYY/MM-DD"}"#,
        )
        .unwrap();
        let outside = unique_temp("outside-nested");
        fs::create_dir_all(&outside).unwrap();
        let daily = root.join("Daily");
        symlink(&outside, &daily).unwrap();
        let vault = Vault {
            root: root.clone(),
            archive: None,
        };
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        // Note creation must fail before any directory is created through
        // the symlinked folder outside the vault.
        let err = add_todo(&vault, date, "nope").unwrap_err();
        assert!(err.to_string().contains("outside the vault"), "err: {err}");
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
        let _ = fs::remove_dir_all(vault.root());
        let _ = fs::remove_dir_all(outside);
    }

    #[cfg(unix)]
    #[test]
    fn refuses_write_when_note_symlinks_outside() {
        use std::os::unix::fs::symlink;
        let (vault, date, note) = vault_with("- [ ] open\n");
        let outside = unique_temp("outside-note");
        fs::create_dir_all(&outside).unwrap();
        let real = outside.join("target.md");
        fs::write(&real, "- [ ] precious\n").unwrap();
        fs::remove_file(&note).unwrap();
        symlink(&real, &note).unwrap();
        let err = toggle_todo(&vault, date, 1, None).unwrap_err();
        // The daily-note path check resolves the symlink and refuses before
        // any write is attempted.
        assert!(err.to_string().contains("escapes vault root"), "err: {err}");
        assert_eq!(fs::read_to_string(&real).unwrap(), "- [ ] precious\n");
        let _ = fs::remove_dir_all(vault.root());
        let _ = fs::remove_dir_all(outside);
    }

    #[cfg(unix)]
    #[test]
    fn follows_in_vault_symlinked_note() {
        use std::os::unix::fs::symlink;
        let (vault, date, note) = vault_with("- [ ] open\n");
        let archive = vault.root().join("Archive");
        fs::create_dir_all(&archive).unwrap();
        let real = archive.join("2026-08-20.md");
        fs::write(&real, "- [ ] open\n").unwrap();
        fs::remove_file(&note).unwrap();
        symlink(&real, &note).unwrap();
        toggle_todo(&vault, date, 1, None).unwrap();
        // The real in-vault file is updated and the user's symlink survives.
        assert!(fs::read_to_string(&real).unwrap().starts_with("- [x] open"));
        assert!(
            fs::symlink_metadata(&note)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let _ = fs::remove_dir_all(vault.root());
    }

    #[cfg(unix)]
    #[test]
    fn precreated_temp_symlink_cannot_redirect() {
        use std::os::unix::fs::symlink;
        let (vault, date, note) = vault_with("- [ ] open\n");
        let outside = unique_temp("outside-tmp");
        fs::create_dir_all(&outside).unwrap();
        let victim = outside.join("victim.txt");
        fs::write(&victim, "untouched\n").unwrap();
        // The old predictable temp path, pre-created as a symlink to a file
        // outside the vault. The randomized temp name never collides with it.
        let stale = note.with_extension("md.tmp-obsidian-daily-qs");
        symlink(&victim, &stale).unwrap();
        toggle_todo(&vault, date, 1, None).unwrap();
        assert_eq!(fs::read_to_string(&victim).unwrap(), "untouched\n");
        assert!(
            fs::symlink_metadata(&stale)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(fs::read_to_string(&note).unwrap().starts_with("- [x] open"));
        let _ = fs::remove_dir_all(vault.root());
        let _ = fs::remove_dir_all(outside);
    }

    /// Vault with an archive pattern configured and an archived note for
    /// `date` under `dailies/_archive/YYYY`, with no live note.
    fn archived_vault(date: NaiveDate, content: &str) -> (Vault, std::path::PathBuf) {
        let root = unique_temp("archived");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::write(
            root.join(".obsidian/daily-notes.json"),
            r#"{"folder":"dailies","format":"YYYY-MM-DD"}"#,
        )
        .unwrap();
        let archived = root
            .join("dailies/_archive")
            .join(date.format("%Y").to_string())
            .join(date.format("%Y-%m-%d").to_string())
            .with_extension("md");
        fs::create_dir_all(archived.parent().unwrap()).unwrap();
        fs::write(&archived, content).unwrap();
        let vault = Vault {
            root,
            archive: Some("dailies/_archive/YYYY".into()),
        };
        (vault, archived)
    }

    #[test]
    fn read_snapshot_finds_archived_note() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        let (vault, archived) =
            archived_vault(date, "# 2026-08-20\n- [ ] old one\n- [x] old done\n");
        let snap = read_snapshot(&vault, date).unwrap();
        assert_eq!(snap.exists, Some(true));
        assert_eq!(snap.path, Some(archived.display().to_string()));
        let todos = snap.todos.unwrap();
        assert_eq!(todos.len(), 2);
        assert_eq!(todos[0].text, "old one");
        assert!(!todos[0].checked);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn week_summary_counts_archived_days() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 19).unwrap(); // Wednesday
        let (vault, _) = archived_vault(date, "- [ ] open from archive\n- [x] done from archive\n");
        let week = week_summary(&vault, date).unwrap();
        let days = week.days.unwrap();
        let wed = days
            .iter()
            .find(|d| d.date == "2026-08-19")
            .expect("wednesday in week");
        assert!(wed.exists);
        assert_eq!(wed.open_count, 0);
        assert_eq!(wed.done_count, 0);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn month_summary_counts_days_and_pads_adjacent_months() {
        let (vault, date, _) = vault_with("- [ ] one\n- [ ] two\n- [x] three\n");
        let month = month_summary(&vault, date).unwrap();
        let days = month.days.unwrap();
        assert!(days.len() >= 31 + 7 + 14);
        assert_eq!(days.first().map(|d| d.date.as_str()), Some("2026-07-25"));
        let day = days
            .iter()
            .find(|d| d.date == "2026-08-20")
            .expect("anchor day in month");
        assert!(day.exists);
        assert_eq!(day.open_count, 0);
        assert_eq!(day.done_count, 0);
        assert!(!day.has_notes);
        let empty = days
            .iter()
            .find(|d| d.date == "2026-08-01")
            .expect("month start");
        assert!(!empty.exists);
        assert_eq!(empty.open_count, 0);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn month_summary_dots_count_only_tasks_heading() {
        let content = "## Notes\n- [ ] captured idea\n## Tasks\n- [ ] ship\n- [x] done\n## Morning review\n- [ ] meditate\n";
        let (vault, date, _) = vault_with(content);
        let month = month_summary(&vault, date).unwrap();
        let day = month
            .days
            .unwrap()
            .into_iter()
            .find(|d| d.date == "2026-08-20")
            .expect("anchor day in month");
        assert_eq!(day.open_count, 1);
        assert_eq!(day.done_count, 1);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn month_summary_has_notes_only_for_non_checkbox_lines() {
        let (vault, date, _) = vault_with("- [ ] a todo\n\njournal line\n");
        let month = month_summary(&vault, date).unwrap();
        let day = month
            .days
            .unwrap()
            .into_iter()
            .find(|d| d.date == "2026-08-20")
            .expect("anchor day");
        assert!(day.has_notes);
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn toggle_todo_edits_archived_note_in_place() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).unwrap();
        let (vault, archived) = archived_vault(date, "- [ ] stale task\n");
        let snap = toggle_todo(&vault, date, 1, None).unwrap();
        assert_eq!(snap.exists, Some(true));
        assert_eq!(fs::read_to_string(&archived).unwrap(), "- [x] stale task\n");
        // The live path must not have been created.
        assert!(!vault.root().join("dailies/2026-08-20.md").exists());
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn set_notes_creates_and_updates_section() {
        let (vault, date, note) = vault_with("# Day\n\n## Todos\n\n- [ ] a\n");
        set_notes(&vault, date, Some("Notes"), "hello\n\nworld").unwrap();
        assert_eq!(
            fs::read_to_string(&note).unwrap(),
            "# Day\n\n## Todos\n\n- [ ] a\n## Notes\nhello\n\nworld\n"
        );
        let snap = set_notes(&vault, date, Some("Notes"), "updated").unwrap();
        assert_eq!(snap.notes.as_deref(), Some("updated"));
        assert!(
            fs::read_to_string(&note)
                .unwrap()
                .contains("## Notes\nupdated\n")
        );
        assert!(fs::read_to_string(&note).unwrap().contains("- [ ] a\n"));
        let _ = fs::remove_dir_all(vault.root());
    }

    #[test]
    fn read_snapshot_includes_whole_note_when_heading_empty() {
        let content = "# Day\n\n## Notes\n\njournal entry\n\n## Todos\n\n- [ ] a\n";
        let (vault, date, _) = vault_with(content);
        let snap = read_snapshot(&vault, date).unwrap();
        assert_eq!(
            snap.notes.as_deref(),
            Some("# Day\n\n## Notes\n\njournal entry")
        );
        assert_eq!(snap.todos.as_ref().unwrap().len(), 1);
        let snap = read_snapshot_filtered(&vault, date, None, Some("Notes")).unwrap();
        assert_eq!(snap.notes.as_deref(), Some("journal entry"));
        let _ = fs::remove_dir_all(vault.root());
    }

    fn daily_plugin_filter() -> SnapshotFilter<'static> {
        SnapshotFilter {
            todo_heading: Some("Tasks"),
            notes_heading: None,
            notes_h2_count: Some(2),
        }
    }

    #[test]
    fn daily_template_todos_only_under_tasks() {
        let content = "## Notes\n\
                       ## Links / captured ideas\n\
                       - a captured link\n\
                       ## Tasks\n\
                       - [x] configure sync\n\
                       - [ ] ship the plugin\n\
                       ## Morning review\n\
                       - [ ] Lire une méditation stoïque\n\
                       ## Nightly review\n\
                       - [ ] Regarder l’agenda\n";
        let (vault, date, note) = vault_with(content);
        let filter = daily_plugin_filter();
        let snap = read_snapshot_with(&vault, date, filter).unwrap();
        let todos = snap.todos.unwrap();
        assert_eq!(todos.len(), 2);
        assert_eq!(todos[0].text, "configure sync");
        assert!(todos[0].checked);
        assert_eq!(todos[1].text, "ship the plugin");
        assert!(!todos[1].checked);
        assert_eq!(
            snap.notes.as_deref(),
            Some("## Notes\n## Links / captured ideas\n- a captured link")
        );
        let headings: Vec<&str> = snap
            .sections
            .as_ref()
            .unwrap()
            .iter()
            .map(|s| s.heading.as_str())
            .collect();
        assert_eq!(
            headings,
            [
                "Notes",
                "Links / captured ideas",
                "Tasks",
                "Morning review",
                "Nightly review"
            ]
        );
        assert_eq!(
            snap.sections.as_ref().unwrap()[3].body,
            "- [ ] Lire une méditation stoïque"
        );
        let month = month_summary_with(&vault, date, filter).unwrap();
        let day = month
            .days
            .unwrap()
            .into_iter()
            .find(|d| d.date == date.format("%Y-%m-%d").to_string())
            .unwrap();
        assert_eq!(day.open_count, 1);
        assert_eq!(day.done_count, 1);
        assert!(day.has_notes);

        let updated = set_notes_with(
            &vault,
            date,
            filter,
            "## Notes\n- hello\n## Links / captured ideas\n- a captured link",
        )
        .unwrap();
        assert_eq!(
            updated.notes.as_deref(),
            Some("## Notes\n- hello\n## Links / captured ideas\n- a captured link")
        );
        let file = fs::read_to_string(&note).unwrap();
        assert!(file.contains("## Tasks\n- [x] configure sync\n"));
        assert!(file.contains("## Morning review\n- [ ] Lire une méditation stoïque\n"));
        let _ = fs::remove_dir_all(vault.root());
    }
}
