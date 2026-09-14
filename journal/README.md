# Journal backend (`obsidian-daily-qs`)

Rust CLI used by `austraz.clock` for Obsidian daily notes (`status`, `month`,
`week`, `set-notes`, `add`, `toggle`, `defer`, `open`, `ensure-obsidian`).

`month` / `week` count checkboxes under a `##` whose title contains `tasks`
unless `--heading` is set. `defer --text=…` moves one open item to the next
day under `--notes-heading` (default `Tasks`) without rolling over the rest
of today’s list. After a write, if Obsidian is closed the CLI starts it so
Sync can upload (`ensure-obsidian`); if a close-to-tray plugin is enabled it
hides the window. If Obsidian is already running, the vault watcher is
enough and the widget does not steal focus.

Forked from [LucaNerlich/obsidian-daily-qs](https://github.com/LucaNerlich/obsidian-daily-qs)
(Apache-2.0) with `set-notes` and empty-heading = whole-note journal mode.

## Rebuild bundled binaries

From this directory (needs the pinned toolchain in `rust-toolchain.toml`):

```sh
cargo build --release
cp target/release/obsidian-daily-qs ../bin/obsidian-daily-qs-$(uname -m)
cp target/release/obsidian-daily-qs ../bin/obsidian-daily-qs
```

For portable musl builds, adapt upstream `scripts/build-bundle.sh` targets
(`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`).
