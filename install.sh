#!/bin/bash
# AgentBar installer: builds the app and wires up the zsh hook.
set -euo pipefail
cd "$(dirname "$0")"

AGENTBAR_DIR="$HOME/.agentbar"
mkdir -p "$AGENTBAR_DIR"

echo "==> Building AgentBar (release)…"
mkdir -p .build/release
# Compiled directly with swiftc: SwiftPM's platform lookup fails on a
# Command Line Tools-only install, and this machine has no full Xcode.
swiftc -O -parse-as-library -o .build/release/AgentBar Sources/AgentBar/*.swift
BIN=".build/release/AgentBar"

# Install hook + default config (never overwrite an existing config).
cp -f hook/hook.zsh "$AGENTBAR_DIR/hook.zsh"
[ -f "$AGENTBAR_DIR/config.txt" ] || cp config.txt "$AGENTBAR_DIR/config.txt"

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
echo "Done. Launch the app with:"
echo "  $PWD/$BIN &"
echo ""
echo "Then open a new terminal so the hook loads, and run a long watchlisted"
echo "command (e.g. grok build). The menu bar icon will show a count."
