# Omarchy Obsidian Clock

An [Omarchy](https://omarchy.org/) **bar clock** whose calendar popup shows that day’s **Obsidian daily note** — todos as checkboxes, journal as a scrollable editor.

> **⚡ Built for Omarchy:** clone of the stock `omarchy.clock`. Click a day in the month grid to load that day’s note (folder and filename come from your vault’s Daily Notes plugin).

```
Bar date  →  calendar popup  →  click a day  →  that day's Obsidian journal
```

Fork of Omarchy’s built-in clock. Plugin id stays `austraz.clock`.

---

### ☕ Support the Project
If this saves you from alt-tabbing into Obsidian just to tick a box or skim today’s note, a tip is always appreciated.

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg?style=for-the-badge&logo=paypal)](https://paypal.me/austraz)

---

### 💬 Feedback & Community
Got a question, found a bug, or have a suggestion? Open an [**issue**](https://github.com/austrasien/omarchy-obsidian-clock/issues).

---

## 🚀 Overview

Omarchy’s clock already paints a month grid. This fork keeps that, and wires each cell to the markdown daily note in **your** vault.

**Why bother?**

| | Stock clock ❌ | This fork ✅ |
| :--- | :--- | :--- |
| **See the month** | Yes | Yes |
| **Open that day’s journal** | No | Click the day |
| **Todos** | — | Inbox at the top (**Add a todo… (Enter)**); **→** moves one item to tomorrow; right-click renames; dots = **open Tasks** (max 5) |
| **Journal text** | — | One button per `##` in your daily template (up to 6), editor below |
| **Omarchy** | Built-in | User plugin; disable `omarchy.clock` |

> **Note:** Vault location is **not** hardcoded. You set it once on the widget (see below). Nothing from your notes is committed to this repo.

## What’s new in 1.8

An open todo can move to any calendar day, not only tomorrow.

- Each open checkbox has a **target** next to **→**. Click it, then click a day: the item moves under the same `##` on that date, and the popup opens that day.
- While picking, remaining days of the current month (not today) use the **theme accent**. Change month with the chevrons to target October, November, and so on. The grid size does not change.
- **→** still means tomorrow and does not switch the selected day.
- CLI: `defer --to YYYY-MM-DD`.

## What’s new in 1.7

Obsidian Sync only uploads while the desktop app is running. The clock now keeps that process alive, and it can put back todos Sync wiped by replacing a day with a blank Daily template.

- On bar start (and after a write if Obsidian is still down), the widget starts the app. If [Background Tray](https://community.obsidian.md/plugins/background-tray) (or Tray) is **enabled** in that vault, the window is closed into the tray so Sync keeps running without stealing the desktop. Without it, the window stays open.
- Todos this clock wrote (Add / →) are remembered. If Sync later replaces that note with an unused Daily template, those open items are restored under the same heading. A delete in a note you actually edited is left alone.
- White calendar cells ignore Daily-template prompt lines, so an unused template day no longer looks like it has notes.
- Close uses Hyprland’s Lua dispatcher (`hl.dsp.window.close`), which is what Omarchy’s `hyprctl dispatch` actually accepts.

## What’s new in 1.6

Open todos can move to tomorrow without dumping the rest of today’s list onto that note.

- Each **open** checkbox has a **→**. It removes that line from the selected day and appends `- [ ]` under the **same `##`** on the next calendar day. Creating tomorrow’s file does **not** copy the other open todos (Daily Notes templates would otherwise fill them in).
- **Right-click** a todo (open or done, Tasks or a section) to rename it in place. Enter saves, Esc cancels. Left-click still toggles.
- Calendar dots on days **before today** use the **theme accent**. Today and future days keep the selected-state color.
- Every control has a short English tooltip (bar: format / timezone; days; todos; →; sections; ↗).
- `month` / `week` on the bundled CLI count **Tasks** unless `--heading` is set, so a newly created tomorrow cannot mark the grid with template checkboxes from other sections.

## What’s new in 1.5

The popup is an inbox first, a journal second.

- **Add a todo… (Enter)** sits at the top. There is no `+` button — Enter adds. Opening the calendar focuses that field, not the editor.
- Open todos stay in the list. Done items collapse behind a **`N done`** row (click to expand). Same pattern for checkboxes under a selected section.
- Calendar dots count **open `- [ ]` under `## Tasks` only**. Morning / nightly / other checkboxes no longer mark the month.
- Section buttons sit **above** the editor; that section’s checkboxes sit **below** it. Todo rows are a little tighter.

## What’s new in 1.4

Tabs are no longer a hardcoded Notes / Links / Tasks / reviews row. The popup follows the `##` headings in your Daily Notes **template** (or that day’s note if the template is missing).

- A heading whose title contains **`tasks`** (case-insensitive) is **pinned**: the checkbox list and **Add a todo…** stay on screen, above the editor. It is not a tab.
- Up to **six** other `##` headings become **equal-width buttons under the text field**. Fewer headings → fewer buttons.
- Morning / nightly icons: title contains `nigh` → moon; `morning`, `daily`, or the word `day` → sun. Other titles show the heading text.
- Selecting a section shows that heading’s checkboxes (if any), then the rest of the body in the editor. **Add a todo** always writes under the Tasks heading.
- Each button still reads and writes **that `##` only**. Compact markdown: no extra blank line after a `##` or before the next one.
- `--text` values that start with `-` keep working (review lines like `- [x]`).

## What’s new in 1.3.1

Toggling a **morning / nightly** leading checkbox now writes `- [x]` into the daily note. v1.3 dropped those saves: the body starts with `- [ ]`, and the CLI treated that as a flag, so Obsidian never saw the check and the box came back empty on reopen.

## Daily note headings

The popup does **not** assume a fixed set of titles. It lists `##` headings from the vault’s daily-note template. Matching is **by title** (case-insensitive). Anything under a heading the popup is not showing is left alone.

| Kind | How it is recognized | In the popup | Calendar |
| :--- | :--- | :--- | :--- |
| **Tasks** | `##` title contains `tasks` | Pinned list + **Add a todo… (Enter)** (not a button). Done items hide behind **`N done`**. **→** on an open row defers that item to tomorrow under this heading. Right-click renames. | One dot per **open** `- [ ]` under this heading (max 5). Days **before today** use the theme **accent**. |
| **Other `##`** | Every other template heading, up to 6 | Button above the editor. Checkboxes in that section sit under the text field (done items also collapse). Same **→** / right-click as Tasks. | Non-checkbox prose on an in-month day turns that cell **white**. |

Writes replace that one section only. No extra blank line after the `##` or before the next `##`; a newline in the editor is a newline in the file.

## ✨ Key Features

### 📅 Month grid
- ISO week numbers; click **W** to change week start.
- Click the big date heading to jump back to today.
- In-month days with journal prose (not only checkboxes) render in white; other month days stay muted. Adjacent-month cells stay grey even if those files have notes.
- Up to five dots under a day, one per **open Tasks** todo. Past days with leftovers use the **theme accent**; today and future use the selected-state color.

### ✅ Popup
- **Add a todo… (Enter)** at the top (focused on open), then open Tasks, then **`N done`**, then up to six section buttons (equal width) and **↗** (open in Obsidian), then the editor, then that section’s checkboxes.
- Left-click a todo to toggle. **Right-click** to rename (Enter / Esc). **→** on an open row moves that item to tomorrow under the same heading.
- Section buttons come from the daily template. Sun / moon glyphs when the title looks like a morning or nightly heading.
- Hover any control for a short English tooltip.
- Autosave after a short pause. A **Saving…** hint appears while dirty. The caret is not reset on save, so Enter keeps a second line.
- ↗ opens the selected day in Obsidian (creates the note from the vault’s Daily Notes template if it is missing).

### 🔌 Backend (bundled)
- Ships `bin/obsidian-daily-qs-<arch>` (plus an unsuffixed copy) for `status`, `month`, `week`, `set-notes`, `add`, `toggle`, `defer`, `open`, `ensure-obsidian`.
- `defer --text=… --date YYYY-MM-DD` (with `--notes-heading`) moves one open checkbox to the next day, or to `--to YYYY-MM-DD`. `month` / `week` default `--heading` to `tasks`.
- `ensure-obsidian` starts the desktop app when it is down, then hides it to the tray when a close-to-tray plugin is enabled.
- `status` returns every `##` as `{heading, body}` plus `templateHeadings` from the daily template. `set-notes --notes-heading <title>` replaces that body only.
- Rust sources live under `journal/` (Apache-2.0 fork of [obsidian-daily-qs](https://github.com/LucaNerlich/obsidian-daily-qs) with whole-note journal mode).
- Optional override: `journalBin`. No separate `austraz.obsidian-daily` / marketplace daily plugin required.

## 🛠 Installation (Omarchy)

1. **Add the plugin** (in a terminal):

   ```sh
   omarchy plugin add https://github.com/austrasien/omarchy-obsidian-clock.git --enable
   ```

   `--enable` puts `austraz.clock` on the bar. Disable the stock clock if both would show:

   ```sh
   omarchy plugin disable omarchy.clock
   ```

2. **Point it at your Obsidian vault** (required — see the next section).

3. Restart the shell if the bar does not pick it up:

```sh
omarchy restart shell
```

### Update / remove

```sh
omarchy plugin update austraz.clock
omarchy plugin remove austraz.clock
```

If you previously installed a standalone `austraz.obsidian-daily` only for this clock, you can remove it after updating:

```sh
# Managed install:
omarchy plugin remove austraz.obsidian-daily
# Or a manual copy under ~/.config/omarchy/plugins/:
rm -rf ~/.config/omarchy/plugins/austraz.obsidian-daily
omarchy-shell shell rescanPlugins
```

## 📂 Where to set your Obsidian vault path

The plugin does **not** guess your vault. After install, set **`vaultPath`** to the **absolute** folder that contains `.obsidian/` (the vault root — not a single note, not the daily-notes folder alone).

**Recommended** (terminal):

```sh
omarchy bar set austraz.clock vaultPath "$HOME/Documents/Obsidian/MyVault"
```

Replace `MyVault` with your vault directory. Example: if notes live in `/home/you/Documents/Obsidian/Work/.obsidian/`, the path is `/home/you/Documents/Obsidian/Work`.

**Or** edit `~/.config/omarchy/shell.json`: find the bar widget `"id": "austraz.clock"` and add / set:

```json
{
  "id": "austraz.clock",
  "vaultPath": "/home/YOU/Documents/Obsidian/MyVault"
}
```

That file is the only place the path is stored. It is user config (`~/.config/omarchy/`), never this git repo.

Daily-note **folder and filename** still come from the vault’s Daily Notes plugin (`.obsidian/daily-notes.json`).

Then:

```sh
omarchy restart shell
```

Leave `vaultPath` empty and the calendar still works; the journal pane stays empty until you set it.

## ⚙️ Settings

On the `austraz.clock` entry in `~/.config/omarchy/shell.json`, or via `omarchy bar set austraz.clock <key> <value>`.

| Key | Default | Meaning |
|---|---|---|
| **`vaultPath`** | `""` | **Absolute Obsidian vault root.** Set this. |
| `journalBin` | `""` | Optional absolute path to the journal CLI. Empty = bundled `bin/obsidian-daily-qs-<arch>`. |
| `format` / `formatAlt` | clock strings | Bar label; right-click cycles formats. |
| `weekStartDay` | locale | First day of the week (`W` on the grid toggles). |
| `birthYear` / `lifeExpectancy` | unset | Optional “LIFE” bar (double-tap the year rail). |

## 🔌 IPC

```sh
omarchy-shell austraz.clock toggle
omarchy-shell austraz.clock selectDate 2026-09-08
omarchy-shell shell toggle omarchy.clock
```

The last line still works if this clone registered the stock clock IPC id.

## ⚖️ License

- **MIT** for the QML clock UI (fork of Omarchy’s `omarchy.clock`).
- **Apache-2.0** for the bundled journal CLI under `journal/` / `bin/` — see `NOTICE` and `journal/LICENSE`.

---
*Developed so a click on the Omarchy calendar opens that day’s Obsidian journal — without hardcoding anyone’s vault.*
