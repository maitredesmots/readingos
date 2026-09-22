# ReadingOS

A reading-first home screen for [KOReader](https://koreader.rocks/), built and
tested on a Kindle Paperwhite 3. It shows the current book, what tasks are
due today, and lets you act on a task without leaving the dashboard —
plus The Dig, a small idle game that grows out of real activity.

This repo is the KOReader **plugin** only (`readingos.koplugin/`). It talks to
a backend over HTTP; the backend is not part of this repo.

## Requirements

- KOReader (recent build; developed against the emulator and a Paperwhite 3)
- A backend implementing the ReadingOS HTTP contract (dashboard, task detail,
  actions, undo) — see [Configuration](#configuration)
- A bearer token issued by that backend

## Install

1. Copy `readingos.koplugin/` onto the device, so you end up with
   `/mnt/us/koreader/plugins/readingos.koplugin/` (containing `main.lua`,
   `_meta.lua`, `VERSION`).
2. Put your API token in `/mnt/us/koreader/readingos-token.txt` (plain text,
   one line) — the plugin reads it from there, so the token is never typed on
   the Kindle's on-screen keyboard.
3. Restart KOReader.

## Configuration

**Tools → ReadingOS** opens the dashboard. Settings are on the dashboard
under **WIĘCEJ → USTAWIENIA**:

- **Serwer** — the backend base URL
- **Token API** — set/replace the token in-device (alternative to the token
  file above)

If the dashboard cannot open (no token yet, server unreachable and nothing
cached), tapping ReadingOS opens these settings instead. Until WIĘCEJ →
USTAWIENIA is confirmed on the PW3, the same list is also in the KOReader
menu as **Tools → ReadingOS – ustawienia (awaryjnie)**.

The plugin also self-updates: it checks the backend's plugin manifest once a
day and offers an install when a newer `VERSION` is published, verifying each
file's size and that it compiles before replacing anything.

## VERSION

A single-line file read at startup (`ReadingOS:localVersion()`) and compared
against the backend's manifest (`ReadingOS._versionNewer()`, dotted
numeric comparison — `2.0.0` sorts correctly against `1.10`, `1.4`, etc.).
Bump it on every release; that's what the self-updater keys off.

Current release: **2.0.0**.

## Development

Lua syntax check (no local interpreter needed):

```bash
cd readingos.koplugin && \
  docker run --rm -v "$PWD":/w -w /w nickblah/luajit:2.1-alpine luajit -bl main.lua /dev/null
```

All plugin logic lives in `main.lua`. `_meta.lua` carries the KOReader plugin
metadata (name, description) shown in its menu.

## License

MIT — see [LICENSE](LICENSE).
