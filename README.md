# Omarchy Obsidian Clock

An [Omarchy](https://omarchy.org/) **bar clock** whose calendar popup shows that day’s **Obsidian daily note** — todos as checkboxes, journal as a scrollable editor.

> **⚡ Built for Omarchy:** clone of the stock `omarchy.clock`. Click a day in the month grid to load `Journals/YYYY-MM-DD.md` (or whatever folder your vault’s Daily Notes plugin uses).

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
| **Todos** | — | Dots under the date (max 5); checkboxes in the popup |
| **Journal text** | — | Scrollable editor (checkbox-only days stay “no note”) |
| **Omarchy** | Built-in | User plugin; disable `omarchy.clock` |

> **Note:** Vault location is **not** hardcoded. You set it once on the widget (see below). Nothing from your notes is committed to this repo.

## ✨ Key Features

### 📅 Month grid
- ISO week numbers; click **W** to change week start.
- Click the big date heading to jump back to today.
- Days **in the current month** with journal prose (at least one non-checkbox line) render in white; other month days stay muted. Adjacent-month cells stay grey even if those files have notes.
- Up to five dots under a day, one per checkbox todo.

### ✅ Todos + journal
- Toggle todos, add one from the footer field.
- Journal `TextArea` scrolls when the note is long; autosave after a short pause.
- Diagonal arrow opens the note in Obsidian.

### 🔌 Backend (bundled)
- Ships `bin/obsidian-daily-qs-<arch>` (plus an unsuffixed shim) for `status`, `month`, `set-notes`, `add`, `toggle`, `open`.
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

The plugin does **not** guess your vault. After install, set **`vaultPath`** to the **absolute** folder that contains `.obsidian/` (the vault root — not a single note, not `Journals/` alone).

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

Daily-note **folder and filename** still come from the vault’s Daily Notes plugin (`.obsidian/daily-notes.json`, e.g. `"folder": "Journals"`).

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
