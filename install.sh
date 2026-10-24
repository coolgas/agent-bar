#!/bin/bash
# AgentBar installer: builds the app and wires up the zsh hook.
set -euo pipefail
cd "$(dirname "$0")"

AGENTBAR_DIR="$HOME/.agentbar"
mkdir -p "$AGENTBAR_DIR"

echo "==> Building AgentBar (release)…"
mkdir -p .build/release
BIN=".build/release/AgentBar"
# Prefer SwiftPM, but fall back to swiftc: SwiftPM's platform lookup fails on
# a Command Line Tools-only install (no full Xcode), which is common here.
if ! swift build -c release --product AgentBar 2>/dev/null; then
  echo "    SwiftPM unavailable, compiling with swiftc"
  swiftc -O -parse-as-library -o "$BIN" Sources/AgentBar/*.swift
fi
[ -x "$BIN" ] || { echo "Build failed: $BIN not found"; exit 1; }

# Install hook + default config (never overwrite an existing config).
cp -f hook/hook.zsh "$AGENTBAR_DIR/hook.zsh"
[ -f "$AGENTBAR_DIR/config.txt" ] || cp config.txt "$AGENTBAR_DIR/config.txt"
echo "$PWD/$BIN" > "$AGENTBAR_DIR/bin.path"

# Source the hook from ~/.zshrc.
if ! grep -q "agentbar/hook.zsh" "$HOME/.zshrc" 2>/dev/null; then
  {
    echo ""
    echo "# AgentBar: notify the menu bar app when agent/build commands finish"
    echo '[ -f "$HOME/.agentbar/hook.zsh" ] && source "$HOME/.agentbar/hook.zsh"'
  } >> "$HOME/.zshrc"
  echo "==> Added hook to ~/.zshrc (open a new terminal to activate)"
else
  echo "==> ~/.zshrc already sources the AgentBar hook"
fi

echo ""
echo "Done. Open a new terminal so the hook loads, then:"
echo "  abstart    # launch the menu bar app in the background"
echo "  abstop     # quit it"
echo "  abstatus   # is it running?"
echo ""
echo "Run a long watchlisted command (e.g. grok build) and the menu bar icon"
echo "will show a count."
