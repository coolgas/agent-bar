# AgentBar — menu bar agent-finish tracker (zsh hook)
#
# Fires an event into ~/.agentbar/events.jsonl whenever a watchlisted command
# (see ~/.agentbar/config.txt) runs for at least minDurationSec and exits.
# Sourced from ~/.zshrc by install.sh.

zmodload zsh/datetime 2>/dev/null

typeset -g _AGENTBAR_DIR="$HOME/.agentbar"
typeset -g _AGENTBAR_CFG="$_AGENTBAR_DIR/config.txt"
typeset -g _AGENTBAR_LOG="$_AGENTBAR_DIR/events.jsonl"
typeset -g _AGENTBAR_START=0
typeset -g _AGENTBAR_CMD=""
typeset -gi _AGENTBAR_MIN_DUR=5
typeset -g _AGENTBAR_CFG_MTIME=""
typeset -ga _AGENTBAR_WATCH

# Re-read config only when it changed (stat is cheap; the whole parse is rare).
_agentbar_reload_config() {
  local mtime
  mtime="$(stat -f %m "$_AGENTBAR_CFG" 2>/dev/null)" || mtime=""
  [[ -n "$mtime" && "$mtime" == "$_AGENTBAR_CFG_MTIME" ]] && return 0
  _AGENTBAR_CFG_MTIME="$mtime"
  _AGENTBAR_WATCH=(grok claude codex gemini make cargo "npm run" pnpm yarn pytest "opencode run")
  _AGENTBAR_MIN_DUR=5
  [[ -r "$_AGENTBAR_CFG" ]] || return 0
  local line pat
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue
    case "$line" in
      watch\ *)
        pat="${line#watch }"
        pat="${pat#"${pat%%[![:space:]]*}"}"
        _AGENTBAR_WATCH+=("$pat")
        ;;
      minDurationSec*)
        _AGENTBAR_MIN_DUR="${line//[!0-9]/}"
        [[ "$_AGENTBAR_MIN_DUR" =~ ^[0-9]+$ ]] || _AGENTBAR_MIN_DUR=5
        ;;
    esac
  done < "$_AGENTBAR_CFG"
  (( ${#_AGENTBAR_WATCH} )) || _AGENTBAR_WATCH=("grok" "claude" "codex" "gemini" "make" "cargo" "npm run" "pnpm" "yarn" "pytest" "opencode run")
  return 0
}

# Prefix matching against the watchlist. "grok" matches any `grok …`;
# "npm run" only matches `npm run …`. The bare interactive `opencode` TUI is
# skipped — task completion is tracked separately by the app's event monitor.
_agentbar_match() {
  local cmd="$1" pat pfirst first
  first="${cmd%% *}"; first="${first##*/}"
  for pat in "${_AGENTBAR_WATCH[@]}"; do
    pfirst="${pat%% *}"; pfirst="${pfirst##*/}"
    [[ "$first" == "$pfirst" ]] || continue
    if [[ "$pfirst" == "opencode" ]]; then
      [[ "$cmd" =~ ^opencode[[:space:]]+(run|exec)([[:space:]]|$) ]] || continue
    fi
    if [[ "$pat" == *\ * ]]; then
      [[ "$cmd" == "$pat" || "$cmd" == "$pat "* ]] && return 0
    else
      return 0
    fi
  done
  return 1
}

_agentbar_emit() {
  [[ -d "$_AGENTBAR_DIR" ]] || mkdir -p "$_AGENTBAR_DIR"
  local rc="$1" dur="$2" ts="$EPOCHSECONDS"
  local id="$$-${EPOCHSECONDS}-${RANDOM}${RANDOM}"
  local esc_cmd esc_cwd tty_now
  esc_cmd="${_AGENTBAR_CMD//$'\t'/ }"
  esc_cmd="${esc_cmd//$'\n'/ }"
  esc_cmd="${esc_cmd//\\/\\\\}"
  esc_cmd="${esc_cmd//\"/\\\"}"
  esc_cwd="${PWD//\\/\\\\}"
  esc_cwd="${esc_cwd//\"/\\\"}"
  tty_now="$(tty 2>/dev/null)" || tty_now=""
  tty_now="${tty_now//\\/\\\\}"
  tty_now="${tty_now//\"/\\\"}"
  print -r -- "{\"id\":\"$id\",\"source\":\"zsh\",\"cmd\":\"$esc_cmd\",\"exit\":$rc,\"dur\":$dur,\"cwd\":\"$esc_cwd\",\"tty\":\"$tty_now\",\"ts\":$ts}" >>! "$_AGENTBAR_LOG"
}

_agentbar_preexec() {
  _agentbar_reload_config
  _AGENTBAR_CMD="$1"
  _AGENTBAR_START="$EPOCHSECONDS"
}

_agentbar_precmd() {
  local rc="$?"
  if (( _AGENTBAR_START )); then
    local dur=$(( EPOCHSECONDS - _AGENTBAR_START ))
    if (( dur >= _AGENTBAR_MIN_DUR )) && _agentbar_match "$_AGENTBAR_CMD"; then
      _agentbar_emit "$rc" "$dur"
    fi
  fi
  _AGENTBAR_START=0
  _AGENTBAR_CMD=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _agentbar_preexec
add-zsh-hook precmd _agentbar_precmd

# Warm the config cache immediately so the watchlist is ready on first use.
_agentbar_reload_config
