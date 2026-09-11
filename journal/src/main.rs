//! Omarchy Quattro backend for Obsidian daily note todos.

use std::io::{self, Write};
use std::path::PathBuf;

use chrono::{Local, NaiveDate};
use clap::{Parser, Subcommand};

use obsidian_daily_qs::config::Vault;
use obsidian_daily_qs::status::{Snapshot, WeekSummary};
use obsidian_daily_qs::watch;
use obsidian_daily_qs::{
    SnapshotFilter, add_todo_under, carry_over, defer_todo, delete_todo, edit_todo,
    month_summary_with,
    open_in_obsidian, read_snapshot_with, set_indent, set_notes_with, toggle_todo, undo_last,
    week_summary_with,
};

#[derive(Parser)]
#[command(
    name = "obsidian-daily-qs",
    version,
    about = "Backend for the Omarchy Obsidian Daily bar widget",
    long_about = "Reads and updates markdown checkbox todos in Obsidian daily \
                  notes for the Omarchy Quattro widget. Pass --vault or set \
                  OBSIDIAN_VAULT_ROOT."
)]
struct Cli {
    /// Absolute path to the Obsidian vault (overrides OBSIDIAN_VAULT_ROOT)
    #[arg(long, global = true)]
    vault: Option<PathBuf>,

    /// Optional archive folder pattern relative to the vault root
    /// (moment-style, e.g. dailies/_archive/YYYY) where old daily notes live
    #[arg(long, global = true)]
    archive_folder: Option<String>,

    /// Only include todos under this markdown heading (e.g. Tasks)
    #[arg(long, global = true)]
    heading: Option<String>,

    /// Markdown heading for the free-form notes pane (default: whole note
    /// minus checkboxes). Ignored when --notes-h2-count is set.
    #[arg(long, global = true)]
    notes_heading: Option<String>,

    /// Notes pane: first N `##` sections, including the heading lines
    #[arg(long, global = true, value_name = "N")]
    notes_h2_count: Option<usize>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print one status snapshot as a single JSON line and exit
    Status {
        #[arg(long)]
        date: Option<String>,
    },
    /// Stream today's status snapshots as JSON lines when the note changes
    Watch,
    /// Add an open checkbox todo
    Add {
        #[arg(long, allow_hyphen_values = true)]
        text: String,
        #[arg(long)]
        date: Option<String>,
        /// Nest under this 1-based todo line
        #[arg(long)]
        under_line: Option<usize>,
    },
    /// Toggle a checkbox on the given 1-based source line
    Toggle {
        #[arg(long)]
        line: usize,
        #[arg(long)]
        expect_text: Option<String>,
        #[arg(long)]
        date: Option<String>,
    },
    /// Rewrite the text of a todo on the given line
    Edit {
        #[arg(long)]
        line: usize,
        #[arg(long, allow_hyphen_values = true)]
        text: String,
        #[arg(long)]
        expect_text: Option<String>,
        #[arg(long)]
        date: Option<String>,
    },
    /// Delete a todo (optionally with nested children)
    Delete {
        #[arg(long)]
        line: usize,
        #[arg(long)]
        expect_text: Option<String>,
        #[arg(long, default_value_t = false)]
        with_children: bool,
        #[arg(long)]
        date: Option<String>,
    },
    /// Indent a todo one level
    Indent {
        #[arg(long)]
        line: usize,
        #[arg(long)]
        expect_text: Option<String>,
        #[arg(long)]
        date: Option<String>,
    },
    /// Outdent a todo one level
    Outdent {
        #[arg(long)]
        line: usize,
        #[arg(long)]
        expect_text: Option<String>,
        #[arg(long)]
        date: Option<String>,
    },
    /// Restore the previous note contents from the last mutation
    Undo,
    /// Print Mon–Sun open/done counts for the week containing `date`
    Week {
        #[arg(long)]
        date: Option<String>,
    },
    /// Print open/done counts for each day of the month containing `date`
    Month {
        #[arg(long)]
        date: Option<String>,
    },
    /// Move yesterday's still-open todos into the target day
    CarryOver {
        #[arg(long)]
        date: Option<String>,
    },
    /// Move one open todo from `date` to the next day (same heading)
    Defer {
        #[arg(long, allow_hyphen_values = true)]
        text: String,
        #[arg(long)]
        date: Option<String>,
    },
    /// Create the daily note when missing, then open it in Obsidian
    Open {
        #[arg(long)]
        date: Option<String>,
    },
    /// Replace the free-form notes section body
    SetNotes {
        #[arg(long, allow_hyphen_values = true)]
        text: String,
        #[arg(long)]
        date: Option<String>,
    },
}

fn main() {
    let cli = Cli::parse();
    let vault_arg = cli.vault.clone();
    let archive_arg = cli.archive_folder.clone();
    let heading = cli.heading.clone();
    let notes_heading = cli.notes_heading.clone();
    let notes_h2_count = cli.notes_h2_count;
    let filter = SnapshotFilter {
        todo_heading: heading.as_deref(),
        notes_heading: notes_heading.as_deref(),
        notes_h2_count,
    };
    match cli.command {
        Command::Status { date } => emit(run(
            vault_arg,
            archive_arg,
            |vault, d| read_snapshot_with(vault, d, filter),
            date,
        )),
        Command::Watch => watch::watch(
            cli.vault.clone(),
            cli.archive_folder.clone(),
            heading.clone(),
            notes_heading.clone(),
            notes_h2_count,
        ),
        Command::Add {
            text,
            date,
            under_line,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| add_todo_under(vault, d, &text, under_line),
        )),
        Command::Toggle {
            line,
            expect_text,
            date,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| toggle_todo(vault, d, line, expect_text.as_deref()),
        )),
        Command::Edit {
            line,
            text,
            expect_text,
            date,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| edit_todo(vault, d, line, expect_text.as_deref(), &text),
        )),
        Command::Delete {
            line,
            expect_text,
            with_children,
            date,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| delete_todo(vault, d, line, expect_text.as_deref(), with_children),
        )),
        Command::Indent {
            line,
            expect_text,
            date,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| set_indent(vault, d, line, expect_text.as_deref(), 1),
        )),
        Command::Outdent {
            line,
            expect_text,
            date,
        } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| set_indent(vault, d, line, expect_text.as_deref(), -1),
        )),
        Command::Undo => emit(match Vault::resolve(vault_arg, archive_arg) {
            Ok(vault) => match undo_last(&vault) {
                Ok(snap) => {
                    let date = snap
                        .date
                        .as_deref()
                        .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
                        .unwrap_or_else(|| Local::now().date_naive());
                    read_snapshot_with(&vault, date, filter).unwrap_or(snap)
                }
                Err(err) => Snapshot::error_with_code(err.to_string(), err.error_code()),
            },
            Err(err) => Snapshot::error_with_code(err.to_string(), err.error_code()),
        }),
        Command::Week { date } => {
            let out = match Vault::resolve(vault_arg, archive_arg) {
                Ok(vault) => match parse_date(date) {
                    Ok(d) => match week_summary_with(&vault, d, calendar_filter(filter)) {
                        Ok(w) => w,
                        Err(err) => WeekSummary::error(err.to_string(), err.error_code()),
                    },
                    Err(err) => WeekSummary::error(err, "io"),
                },
                Err(err) => WeekSummary::error(err.to_string(), err.error_code()),
            };
            emit_json(&out);
        }
        Command::Month { date } => {
            let out = match Vault::resolve(vault_arg, archive_arg) {
                Ok(vault) => match parse_date(date) {
                    Ok(d) => match month_summary_with(&vault, d, calendar_filter(filter)) {
                        Ok(w) => w,
                        Err(err) => WeekSummary::error(err.to_string(), err.error_code()),
                    },
                    Err(err) => WeekSummary::error(err, "io"),
                },
                Err(err) => WeekSummary::error(err.to_string(), err.error_code()),
            };
            emit_json(&out);
        }
        Command::CarryOver { date } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            carry_over,
        )),
        Command::Defer { text, date } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            |vault, d| defer_todo(vault, d, notes_heading.as_deref(), &text),
        )),
        Command::Open { date } => emit(then_snapshot(
            vault_arg,
            archive_arg,
            date,
            filter,
            open_in_obsidian,
        )),
        Command::SetNotes { text, date } => emit(run(
            vault_arg,
            archive_arg,
            |vault, d| set_notes_with(vault, d, filter, &text),
            date,
        )),
    }
}

fn calendar_filter(filter: SnapshotFilter<'_>) -> SnapshotFilter<'_> {
    if filter
        .todo_heading
        .map(str::trim)
        .is_some_and(|s| !s.is_empty())
    {
        filter
    } else {
        SnapshotFilter {
            todo_heading: Some("tasks"),
            ..filter
        }
    }
}

fn then_snapshot<F>(
    vault_arg: Option<PathBuf>,
    archive_arg: Option<String>,
    date: Option<String>,
    filter: SnapshotFilter<'_>,
    f: F,
) -> Snapshot
where
    F: FnOnce(&Vault, NaiveDate) -> Result<Snapshot, obsidian_daily_qs::VaultError>,
{
    run(
        vault_arg,
        archive_arg,
        |vault, d| {
            f(vault, d)?;
            read_snapshot_with(vault, d, filter)
        },
        date,
    )
}

fn run<F>(
    vault_arg: Option<PathBuf>,
    archive_arg: Option<String>,
    f: F,
    date: Option<String>,
) -> Snapshot
where
    F: FnOnce(&Vault, NaiveDate) -> Result<Snapshot, obsidian_daily_qs::VaultError>,
{
    match Vault::resolve(vault_arg, archive_arg) {
        Ok(vault) => match parse_date(date) {
            Ok(d) => match f(&vault, d) {
                Ok(snap) => snap,
                Err(err) => Snapshot::error_with_code(err.to_string(), err.error_code()),
            },
            Err(err) => Snapshot::error_with_code(err, "io"),
        },
        Err(err) => Snapshot::error_with_code(err.to_string(), err.error_code()),
    }
}

fn parse_date(date: Option<String>) -> Result<NaiveDate, String> {
    match date {
        None => Ok(Local::now().date_naive()),
        Some(s) => NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d")
            .map_err(|_| format!("invalid --date {s:?}; expected YYYY-MM-DD")),
    }
}

fn emit(snap: Snapshot) {
    emit_json(&snap);
}

fn emit_json<T: serde::Serialize>(value: &T) {
    let line = serde_json::to_string(value).expect("serializes");
    let mut out = io::stdout().lock();
    if writeln!(out, "{line}").is_err() || out.flush().is_err() {
        std::process::exit(0);
    }
}
