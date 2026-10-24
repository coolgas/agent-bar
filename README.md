# AgentBar

A tiny macOS menu bar app that tells you when your terminal agents and builds
finish. When a watched command exits, the tray icon gets a count badge; click it
to see what finished, whether it succeeded, how long it took and where.

Each row shows the harness (`opencode`, `grok`, `claude`, …), the folder it ran
in (hover for the full path), the first few words of the prompt or arguments,
and the model when the harness reports one (currently opencode only).

```
[tray 3]  ← menu bar: unread count (empty tray when nothing is waiting)

  ┌──────────────────────────────────────────────┐
  │ AgentBar              3 new           Clear  │
  ├──────────────────────────────────────────────┤
  │ ✅ grok  spin-glasses                        │
  │    build                                     │
  │    4m 32s  ·  14:02                          │
  │ ❌ pytest  spin-glasses                      │
  │    tests/ -k slow                            │
  │    1m 04s  ·  13:58                          │
  │ ✅ opencode  agentbar                        │
  │    fix the failing test in the…              │
  │    claude-sonnet-5-5  ·  12m 40s  ·  13:51   │
  ├──────────────────────────────────────────────┤
  │ 🔥 Today: 182.4k tokens · $0.42              │
  ├──────────────────────────────────────────────┤
  │                            Quit AgentBar     │
  └──────────────────────────────────────────────┘
```

Hover the tray icon for a one-line summary (running · finished · tokens today).

- **Click a row** to acknowledge it. Acknowledged rows stay in the list, dimmed.
- **Clear** wipes the whole list *and* truncates the log file, so cleared
  history doesn't come back on the next launch.

## Quick start

```sh
git clone https://github.com/coolgas/agent-bar.git
cd agent-bar
./install.sh          # builds release, installs hook + config, edits ~/.zshrc
```

Then open a new terminal and use the commands the installer adds:

```sh
abstart     # launch the app in the background
abstop      # quit it
abstatus    # is it running?
```

They survive closing the terminal; the app's output goes to
`~/.agentbar/agentbar.log`. `abstart` is a no-op if the app is already running.

The app runs as a bare menu bar item — no Dock icon. Quit it from the panel or
with `abstop`.

## Requirements

- macOS 13 or later (`MenuBarExtra`).
- Swift 5.9 toolchain. A full Xcode install isn't needed: `install.sh` tries
  `swift build -c release` and falls back to compiling with `swiftc`, which
  works with Command Line Tools only.
- zsh (the hook is a zsh plugin). Non-zsh shells still get process-watcher
  coverage, but without exit codes.

## How it works

Three producers append one JSON line per finished task to
`~/.agentbar/events.jsonl`; the app tails that file once a second (and once
more whenever the panel opens).

| Producer | Detects | Notes |
|---|---|---|
| zsh hook | A watched command exits after ≥ `minDurationSec` | Primary source. Records the command, exit code, duration, cwd and tty. |
| Process watcher | A watched process disappears from the process table (3s poll) | Safety net for non-zsh shells and terminal apps outside zsh. No exit code; waits 2.5s before logging so it doesn't double-count the hook. |
| opencode monitor | An opencode session finishes a task | Finds the local service via `opencode api get /api/info`, then consumes the `/api/event` SSE stream directly. Also sums daily token usage. |

The bare interactive `opencode` TUI is intentionally *not* counted when you quit
it — opencode sessions emit an execution event each time the agent finishes a
task instead. One-shot `opencode run …` commands are counted like any other
command.

## Configuration

Edit `~/.agentbar/config.txt` (changes are picked up within seconds, no
restart):

```
minDurationSec 5
maxEvents 200

watch grok
watch claude
watch codex
watch gemini
watch make
watch cargo
watch npm run
watch pnpm
watch yarn
watch pytest
watch opencode run
```

| Directive | Meaning |
|---|---|
| `watch <prefix>` | Fire an event when a command starting with this prefix finishes. `grok` matches `grok build …`; `npm run` only matches `npm run …`. |
| `minDurationSec <n>` | Ignore commands that ran for fewer than `n` seconds (default 5). |
| `maxEvents <n>` | Rows kept in the panel (default 200). The log file itself is not trimmed; use Clear. |

Notes:

- Any `watch` line **replaces** the built-in list entirely. If you define none,
  the defaults shown above are used.
- Matching ignores a path prefix (`/usr/local/bin/grok`), leading `VAR=value`
  assignments (`CI=1 npm run build`) and aliases (`alias cc=claude` counts as
  `claude`).
- `#` starts a comment, including at the end of a line.

## Files

| Path | Purpose |
|---|---|
| `~/.agentbar/events.jsonl` | Event log (one JSON object per finished task) |
| `~/.agentbar/acked.json` | Acknowledged event ids (unread count survives restarts) |
| `~/.agentbar/usage.json` | Today's opencode token usage; resets at midnight |
| `~/.agentbar/config.txt` | Watchlist and settings |
| `~/.agentbar/hook.zsh` | The zsh hook and the `abstart`/`abstop` commands |
| `~/.agentbar/bin.path` | Where `install.sh` built the binary |
| `~/.agentbar/agentbar.log` | App output when launched with `abstart` |

`install.sh` never overwrites an existing `config.txt`, so your watchlist
survives re-running it. Set `AGENTBAR_HOME` to use a different data directory
(handy for testing):

```sh
AGENTBAR_HOME=/tmp/agentbar-test .build/release/AgentBar
```

Events recorded while the app is closed still show up when you relaunch it.

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing appears after a long command | Is the hook loaded? `source ~/.zshrc`, then `typeset -f _agentbar_preexec` should print a function. |
| Command finished but no event | Did it run for at least `minDurationSec`? Does it match a `watch` prefix? |
| No opencode events | `opencode api get /api/info` must succeed and `~/.config/opencode/service.json` must exist. |
| Wrong `$PATH` when launched from Finder | The app resolves `opencode` through a login shell, so launching from Finder works; prefer `abstart` anyway. |

## Uninstall

1. Remove the AgentBar line (and the `abstart` helpers it sources) from
   `~/.zshrc`.
2. `abstop` (or `pkill -x AgentBar`).
3. `rm -rf ~/.agentbar ~/Developer/agent-bar`.

## Development

```sh
swift build                 # may fail on Command Line Tools-only installs
swiftc -O -parse-as-library -o .build/release/AgentBar Sources/AgentBar/*.swift
./install.sh                # rebuild + reinstall hook and helpers
```

Source layout:

| File | Role |
|---|---|
| `App.swift` | App entry point, `AppModel` (wires producers to the UI), menu bar label |
| `MenuView.swift` | The panel: header, event rows, usage footer |
| `Models.swift` | `AgentEvent`, config parsing (`Config`), daily `Usage`, `ConfigStore` |
| `EventStore.swift` | Tails `events.jsonl`, tracks unread/acknowledged state |
| `ProcessWatcher.swift` | `ps` polling fallback |
| `OpencodeMonitor.swift` | opencode event-stream consumer |
| `hook/hook.zsh` | zsh hook + `abstart`/`abstop`/`abstatus` |
