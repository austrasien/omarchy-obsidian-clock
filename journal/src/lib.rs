//! Obsidian daily-notes backend for the Omarchy Quattro bar widget.

pub mod config;
pub mod format;
pub mod notes;
pub mod open;
pub mod owned;
pub mod status;
pub mod todos;
pub mod undo;
pub mod watch;

pub use config::{DailyNotesConfig, Vault, VaultError};
pub use status::{DaySummary, Snapshot, State, TodoItem, WeekSummary};
pub use todos::{
    SnapshotFilter, add_todo, add_todo_under, carry_over, defer_todo, delete_todo, edit_todo, ensure_note,
    month_summary, month_summary_with, open_in_obsidian, read_snapshot, read_snapshot_filtered,
    read_snapshot_with, set_indent, set_notes, set_notes_with, toggle_todo, week_summary,
    week_summary_with,
};
pub use undo::undo_last;
