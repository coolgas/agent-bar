# AgentBar

A tiny macOS menu bar app that tracks when your terminal agents and builds
finish. A count badge sits in the top-right menu bar; click it to see exactly
what finished, whether it succeeded, how long it ran, and where.

```
[tray 3]  ← menu bar shows the number of finished-but-unseen tasks

  ┌──────────────────────────────────────────────┐
  │ AgentBar              3 new           Clear  │
  ├──────────────────────────────────────────────┤
  │ ✅ grok build                        zsh     │
  │    4m 32s  ·  14:02  ·  spin-glasses         │
  │ ❌ pytest tests/ -k slow              zsh    │
  │    1m 04s  ·  13:58  ·  spin-glasses         │
  │ ✅ opencode · fix the failing test    oc     │
  │    12m 40s  ·  13:51                         │
  ├──────────────────────────────────────────────┤
  │                            Quit AgentBar     │
  └──────────────────────────────────────────────┘
```

Click a row to acknowledge it. **Clear** acknowledges everything.

## How it works

Three producers append one JSON line per finished task to
`~/.agentbar/events.jsonl`; the app tails that file once a second.

| Producer | Detects | Notes |
|---|---|---|
| zsh hook | Watchlisted command exits after ≥ `minDurationSec` | Primary source. Captures command, exit code, duration, cwd, tty. |
| Process watcher | Watchlisted process vanishes from the process table (3s poll) | Safety net for non-zsh shells. No exit codes; deduped against the hook. |
| opencode monitor | An opencode session finishes executing a task | Discovers the background service via `opencode api get /api/info`, then consumes the `/api/event` SSE stream directly. |

The bare interactive `opencode` TUI is intentionally *not* counted when you
quit it — opencode sessions fire events each time the agent finishes a task
instead. One-shot `opencode run …` commands are counted like any other
command.

## Build & install

```sh
cd ~/Developer/agentbar
./install.sh          # builds release, installs hook + config, edits ~/.zshrc
```

Launch the app:

```sh
.build/release/AgentBar &
```

It runs as a bare menu bar item (no Dock icon). Quit it from the menu.

## Configuration

Edit `~/.agentbar/config.txt` (changes apply within seconds):

```
minDurationSec 5
maxEvents 200

watch grok
watch claude
watch make
watch npm run
# …one prefix per line; "watch opencode run" covers one-shot runs
```

- `watch` lines match by command prefix (`grok` matches `grok build …`,
  `npm run` only matches `npm run …`).
- If the file contains no `watch` lines, a built-in default list is used.

## Files

| Path | Purpose |
|---|---|
| `~/.agentbar/events.jsonl` | Event log (one JSON object per finished task) |
| `~/.agentbar/acked.json` | Acknowledged event ids (the count survives restarts) |
| `~/.agentbar/config.txt` | Watchlist + settings |
| `~/.agentbar/hook.zsh` | The zsh hook (copied from this repo by `install.sh`) |

Events recorded while the app is closed still show up when you relaunch it.

## Uninstall

1. Remove the AgentBar lines from `~/.zshrc`.
2. `pkill AgentBar`.
3. `rm -rf ~/.agentbar ~/Developer/agentbar`.

## Notes

- Requires macOS 13+ (uses `MenuBarExtra`); built with `swift build`, no Xcode
  project needed.
- The opencode integration depends on opencode's experimental `/api/event`
  stream and `~/.config/opencode/service.json` for local auth; if either
  changes, the monitor reconnects and degrades gracefully (it just stops
  emitting opencode events).
- When launched from Finder/Spotlight a bare executable inherits a minimal
  PATH; the app resolves `opencode` through a login shell to cope with this.
