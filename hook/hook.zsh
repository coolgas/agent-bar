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
typeset -g _AGENTBAR_MATCH_CMD=""
typeset -gi _AGENTBAR_MIN_DUR=5
typeset -g _AGENTBAR_CFG_MTIME=""
typeset -ga _AGENTBAR_WATCH
typeset -ga _AGENTBAR_DEFAULT_WATCH
_AGENTBAR_DEFAULT_WATCH=(grok claude codex gemini make cargo "npm run" pnpm yarn pytest "opencode run")

# Re-read config only when it changed (stat is cheap; the whole parse is rare).
_agentbar_reload_config() {
  local mtime
  mtime="$(stat -f %m "$_AGENTBAR_CFG" 2>/dev/null)" || mtime=""
  [[ -n "$mtime" && "$mtime" == "$_AGENTBAR_CFG_MTIME" ]] && return 0
  _AGENTBAR_CFG_MTIME="$mtime"
  # Config "watch" lines replace the defaults entirely (same as the app).
  _AGENTBAR_WATCH=()
  _AGENTBAR_MIN_DUR=5
  if [[ ! -r "$_AGENTBAR_CFG" ]]; then
    _AGENTBAR_WATCH=("${_AGENTBAR_DEFAULT_WATCH[@]}")
    return 0
  fi
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
      minDurationSec\ *)
        local n="${line#minDurationSec }"
        n="${n//[[:space:]]/}"
        [[ "$n" =~ ^[0-9]+$ ]] && _AGENTBAR_MIN_DUR="$n"
        ;;
    esac
  done < "$_AGENTBAR_CFG"
  (( ${#_AGENTBAR_WATCH} )) || _AGENTBAR_WATCH=("${_AGENTBAR_DEFAULT_WATCH[@]}")
  return 0
}

# Prefix matching against the watchlist. "grok" matches any `grok …`;
# "npm run" only matches `npm run …`. The bare interactive `opencode` TUI is
# skipped — task completion is tracked separately by the app's event monitor.
_agentbar_match() {
  local cmd="$1" pat pfirst first
  # Skip leading VAR=value assignments (e.g. `CI=1 npm run build`).
  while [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
    cmd="${cmd#"$MATCH"}"
  done
  cmd="${cmd//$'\t'/ }"
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
  _agentbar_json_escape "$_AGENTBAR_CMD"; esc_cmd="$REPLY"
  _agentbar_json_escape "$PWD"; esc_cwd="$REPLY"
  tty_now="$(tty 2>/dev/null)" || tty_now=""
  _agentbar_json_escape "$tty_now"; tty_now="$REPLY"
  print -r -- "{\"id\":\"$id\",\"source\":\"zsh\",\"cmd\":\"$esc_cmd\",\"exit\":$rc,\"dur\":$dur,\"cwd\":\"$esc_cwd\",\"tty\":\"$tty_now\",\"ts\":$ts}" >>! "$_AGENTBAR_LOG"
}

# JSON string escaping (result in $REPLY). Done character by character:
# zsh's ${s//\\/\\\\} pattern silently matches nothing, and control
# characters would otherwise produce invalid JSON that the app drops.
_agentbar_json_escape() {
  local s="$1" c out="" i
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"
    case "$c" in
      '\')    out+='\\' ;;
      '"')    out+='\"' ;;
      $'\t')  out+='\t' ;;
      $'\n')  out+='\n' ;;
      $'\r')  out+='\r' ;;
      [[:cntrl:]]) out+=' ' ;;
      *)      out+="$c" ;;
    esac
  done
  REPLY="$out"
}

_agentbar_preexec() {
  _agentbar_reload_config
  _AGENTBAR_CMD="$1"
  # $3 is the alias-expanded command, so `alias cc=claude` still matches.
  _AGENTBAR_MATCH_CMD="${3:-$1}"
  _AGENTBAR_START="$EPOCHSECONDS"
}

_agentbar_precmd() {
  local rc="$?"
  if (( _AGENTBAR_START )); then
    local dur=$(( EPOCHSECONDS - _AGENTBAR_START ))
    if (( dur >= _AGENTBAR_MIN_DUR )) && _agentbar_match "$_AGENTBAR_MATCH_CMD"; then
      _agentbar_emit "$rc" "$dur"
    fi
  fi
  _AGENTBAR_START=0
  _AGENTBAR_CMD=""
  _AGENTBAR_MATCH_CMD=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _agentbar_preexec
add-zsh-hook precmd _agentbar_precmd

# Warm the config cache immediately so the watchlist is ready on first use.
_agentbar_reload_config

# --- start / stop helpers ------------------------------------------------
# install.sh writes the built binary's path to ~/.agentbar/bin.path so these
# keep working wherever the checkout lives.

_agentbar_bin() {
  local bin=""
  [[ -r "$_AGENTBAR_DIR/bin.path" ]] && bin="$(<"$_AGENTBAR_DIR/bin.path")"
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    print -u2 "agentbar: binary not found; run install.sh in the checkout"
    return 1
  fi
  print -r -- "$bin"
}

abstart() {
  local bin log
  bin="$(_agentbar_bin)" || return 1
  if pgrep -x AgentBar >/dev/null; then
    print "AgentBar already running (pid $(pgrep -x AgentBar | head -1))"
    return 0
  fi
  log="$_AGENTBAR_DIR/agentbar.log"
  nohup "$bin" >>"$log" 2>&1 &!
  sleep 0.5
  if pgrep -x AgentBar >/dev/null; then
    print "AgentBar started (pid $(pgrep -x AgentBar | head -1))"
  else
    print -u2 "AgentBar failed to start; see $log"
    return 1
  fi
}

abstop() {
  if ! pgrep -x AgentBar >/dev/null; then
    print "AgentBar is not running"
    return 0
  fi
  pkill -x AgentBar
  local i
  for i in {1..20}; do
    pgrep -x AgentBar >/dev/null || { print "AgentBar stopped"; return 0 }
    sleep 0.1
  done
  print -u2 "AgentBar did not stop"
  return 1
}

abstatus() {
  if pgrep -x AgentBar >/dev/null; then
    print "AgentBar running (pid $(pgrep -x AgentBar | head -1))"
  else
    print "AgentBar not running"
  fi
}
