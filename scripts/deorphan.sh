#!/usr/bin/env bash
# deorphan.sh — find (and optionally kill) detached Grok agent processes
# owned by the current user. Intended for ~/.grok/skills/grok-deorphan.
#
# Usage:
#   deorphan.sh           # same as kill
#   deorphan.sh kill      # check, kill orphans, report
#   deorphan.sh check     # check and report only (no signals)
#
# Classification:
#   ATTACHED (KEEP) — grok agent with a live terminal attachment:
#     controlling TTY (pts/*), and/or open FD to a live /dev/pts/N
#     (not "(deleted)"), and/or an ancestor sshd: user@pts/N with a live pts.
#     Always listed — including the session that invoked this script (SELF).
#     SELF is force-merged into KEEP after scan if find_self found it but
#     classify omitted it (PPID==agent skip, transient /proc read, etc.).
#   ORPHAN — grok agent with no live terminal attachment (deleted-pts FDs
#     alone do NOT count as attached; SSH-dead leftovers are orphans).
#     The invoker (SELF) is never left on the orphan/kill list.
#   WRAPPER — ProjectMan re-spawn bash wrappers considered only in kill mode
#     when they have no attached grok child.
#
# Hard rules before SIGTERM (kill mode only):
#   1. pid owned by $UID
#   2. no live terminal attachment (see above)
#   3. /proc/pid/exe is a Grok Build binary
#   4. cmdline looks like a Grok agent (not this script, not helpers)
#   5. never pkill/killall/kill -- -PGID; only explicit PIDs
#
# Exit 0 always after report (kill failures noted in report). Not interactive.
set -euo pipefail

export LC_ALL=C

MODE="${1:-kill}"
case "$MODE" in
  kill|check) ;;
  -h|--help|help)
    cat <<'USAGE'
Usage: deorphan.sh [kill|check]
  kill   (default) classify, kill orphans, report
  check  classify and report only — no signals
USAGE
    exit 0
    ;;
  *)
    echo "deorphan: unknown mode '$MODE' (want: kill | check)" >&2
    exit 2
    ;;
esac

REPORT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
declare -a KEPT_LINES=()
declare -a ORPHAN_PIDS=()
declare -a ORPHAN_LINES=()
declare -a KILLED=()
declare -a FAILED=()
declare -a SKIPPED=()
declare -a WRAPPER_PIDS=()
declare -a WRAPPER_KILLED=()

# Grok agent PID that invoked us (ancestor of this script), if any.
SELF_AGENT_PID=""

is_digits() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# True if this PID has no controlling terminal (ps tty is ? / empty / -).
has_no_ctty() {
  local pid=$1 tty
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [[ -z "$tty" || "$tty" == "?" || "$tty" == "-" ]]
}

# ps TTY field (pts/N or ?)
ps_tty() {
  local pid=$1 tty
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$tty" || "$tty" == "?" || "$tty" == "-" ]]; then
    printf '?'
  else
    printf '%s' "$tty"
  fi
}

owned_by_us() {
  local pid=$1 uid
  [[ -r "/proc/$pid/status" ]] || return 1
  uid="$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" == "$UID" ]]
}

# Resolve exe; must be a Grok Build binary path/name.
is_grok_agent_exe() {
  local pid=$1 exe base
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [[ -n "$exe" ]] || return 1
  # deleted binaries still show as "path (deleted)"
  exe="${exe% (deleted)}"
  base="$(basename "$exe")"
  case "$base" in
    grok|grok-linux-x86_64|grok-linux-aarch64) return 0 ;;
  esac
  # installed under ~/.grok/...
  [[ "$exe" == *'/.grok/'* ]] && [[ "$base" == grok* ]] && return 0
  return 1
}

# Cmdline must look like the agent, not scanners/helpers.
is_grok_agent_cmdline() {
  local pid=$1 cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  cmd="${cmd%"${cmd##*[![:space:]]}"}" # rtrim
  [[ -n "$cmd" ]] || return 1

  # Explicit denylist fragments
  case "$cmd" in
    *deorphan*|*de-orphan*|*grok-deorphan*|*grok-reap*|*grok-privacy*|*strace*|*gdb\ * ) return 1 ;;
  esac

  # Must mention grok as invocation
  # Accept: grok ... | .../grok ... | .../grok-linux-x86_64 ...
  if [[ "$cmd" =~ (^|[[:space:]])([^[:space:]]*/)?grok(-linux-[a-z0-9_]+)?([[:space:]]|$) ]]; then
    return 0
  fi
  return 1
}

is_grok_agent() {
  local pid=$1
  is_grok_agent_exe "$pid" && is_grok_agent_cmdline "$pid"
}

# ProjectMan / launcher wrappers that only exist to re-spawn grok.
is_orphan_grok_wrapper() {
  local pid=$1 cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  [[ "$cmd" == *'trap'*'exit 143'* && "$cmd" == *'grok'* ]] || return 1
  [[ "$cmd" == *'bash'* || "$cmd" == bash* ]] || return 1
  return 0
}

# Count open FDs: live /dev/pts/N vs /dev/pts/N (deleted).
# Sets globals: _LIVE_PTS_COUNT _DELETED_PTS_COUNT _LIVE_PTS_SAMPLE
scan_pts_fds() {
  local pid=$1 fd target base
  _LIVE_PTS_COUNT=0
  _DELETED_PTS_COUNT=0
  _LIVE_PTS_SAMPLE=""
  [[ -d "/proc/$pid/fd" ]] || return 0
  # Use nullglob-safe loop; ignore unreadable fds
  for fd in "/proc/$pid/fd/"*; do
    [[ -e "$fd" || -L "$fd" ]] || continue
    target="$(readlink "$fd" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    case "$target" in
      /dev/pts/*)
        base="${target#/dev/pts/}"
        if [[ "$base" == *'(deleted)'* ]] || [[ "$target" == *' (deleted)' ]]; then
          _DELETED_PTS_COUNT=$((_DELETED_PTS_COUNT + 1))
        else
          # Only count if the pts node still exists in the filesystem
          if [[ -e "/dev/pts/${base%% *}" ]]; then
            _LIVE_PTS_COUNT=$((_LIVE_PTS_COUNT + 1))
            [[ -n "$_LIVE_PTS_SAMPLE" ]] || _LIVE_PTS_SAMPLE="pts/${base%% *}"
          else
            _DELETED_PTS_COUNT=$((_DELETED_PTS_COUNT + 1))
          fi
        fi
        ;;
    esac
  done
}

# Walk ancestors; true if any looks like sshd holding a live pts for this user.
has_live_sshd_ancestor() {
  local pid=$1 cur ppid cmd stty n
  cur="$pid"
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [[ -r "/proc/$cur/status" ]] || return 1
    ppid="$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null || true)"
    [[ -n "$ppid" && "$ppid" != "0" ]] || return 1
    cur="$ppid"
    [[ "$cur" != "1" ]] || return 1
    cmd="$(tr '\0' ' ' <"/proc/$cur/cmdline" 2>/dev/null || true)"
    # sshd: user@pts/N  or  sshd: user [priv] under a pts session
    if [[ "$cmd" == *sshd* && "$cmd" == *@pts/* ]]; then
      stty="${cmd##*@}"
      stty="${stty%% *}"
      # stty like pts/2
      if [[ "$stty" == pts/* && -e "/dev/${stty}" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# Live terminal attachment (KEEP). Deleted pts alone is NOT live.
has_live_terminal_attachment() {
  local pid=$1 tty
  # 1) Controlling TTY is a real pts/tty that still exists
  tty="$(ps_tty "$pid")"
  if [[ "$tty" != "?" && -e "/dev/$tty" ]]; then
    return 0
  fi
  # 2) Open FD to a live /dev/pts/N
  scan_pts_fds "$pid"
  if ((_LIVE_PTS_COUNT > 0)); then
    return 0
  fi
  # 3) Ancestor is sshd:user@pts/N with that pts still present
  if has_live_sshd_ancestor "$pid"; then
    return 0
  fi
  return 1
}

# Find the grok agent in our own ancestor chain (the session running us).
find_self_agent_pid() {
  local cur ppid n
  cur="$$"
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [[ -r "/proc/$cur/status" ]] || return 0
    ppid="$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null || true)"
    [[ -n "$ppid" && "$ppid" != "0" ]] || return 0
    cur="$ppid"
    [[ "$cur" != "1" ]] || return 0
    if is_grok_agent "$cur" 2>/dev/null; then
      SELF_AGENT_PID="$cur"
      return 0
    fi
  done
  return 0
}

short_cmd() {
  local pid=$1 cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  cmd="$(printf '%s' "$cmd" | tr -s ' ' | cut -c1-100)"
  printf '%s' "$cmd"
}

proc_cwd() {
  local pid=$1 c
  c="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  printf '%s' "${c:-?}"
}

proc_ppid() {
  local pid=$1 p
  p="$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  printf '%s' "${p:-?}"
}

# --resume UUID or "-" if absent
resume_id() {
  local pid=$1 cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  if [[ "$cmd" =~ --resume[[:space:]]+([0-9a-fA-F-]{8,}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '-'
  fi
}

# Build a rich one-line description for reports.
describe_agent() {
  local pid=$1 role=$2
  local tty pcpu cwd ppid resume live del reason self_tag
  tty="$(ps_tty "$pid")"
  pcpu="$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  cwd="$(proc_cwd "$pid")"
  ppid="$(proc_ppid "$pid")"
  resume="$(resume_id "$pid")"
  scan_pts_fds "$pid"
  live="$_LIVE_PTS_COUNT"
  del="$_DELETED_PTS_COUNT"

  if [[ "$role" == "KEEP" ]]; then
    reason="live_terminal"
    if [[ "$tty" != "?" && -e "/dev/$tty" ]]; then
      reason="ctty=$tty"
    elif ((live > 0)); then
      reason="live_pts_fd=${_LIVE_PTS_SAMPLE:-yes}"
    else
      reason="sshd_ancestor"
    fi
  else
    reason="no_live_terminal"
    if ((del > 0)); then
      reason="deleted_pts_only"
    fi
    if [[ "$ppid" == "1" ]]; then
      reason="${reason}+ppid1"
    fi
  fi

  self_tag=""
  if [[ -n "$SELF_AGENT_PID" && "$pid" == "$SELF_AGENT_PID" ]]; then
    self_tag=" SELF"
  fi

  printf 'pid=%s ppid=%s tty=%s cpu=%s cwd=%s resume=%s live_pts=%s del_pts=%s reason=%s%s cmd=%s' \
    "$pid" "$ppid" "$tty" "${pcpu:-?}" "$cwd" "$resume" "$live" "$del" "$reason" "$self_tag" \
    "$(short_cmd "$pid")"
}

classify_pid() {
  local pid=$1 line

  is_digits "$pid" || return 0
  [[ -d "/proc/$pid" ]] || return 0
  # Never treat this script as an agent. Skip direct parent only when it is
  # NOT the invoking agent (PPID==agent happens if the tool shell execs us).
  [[ "$pid" == "$$" ]] && return 0
  if [[ "$pid" == "$PPID" && "$pid" != "${SELF_AGENT_PID:-}" ]]; then
    return 0
  fi

  owned_by_us "$pid" || return 0

  if is_grok_agent "$pid"; then
    if has_live_terminal_attachment "$pid"; then
      line="$(describe_agent "$pid" KEEP)"
      KEPT_LINES+=("$line")
    else
      line="$(describe_agent "$pid" ORPHAN)"
      ORPHAN_PIDS+=("$pid")
      ORPHAN_LINES+=("$line")
    fi
    return 0
  fi

  if is_orphan_grok_wrapper "$pid"; then
    # Only track wrappers that look detached (no live attachment)
    if ! has_live_terminal_attachment "$pid"; then
      WRAPPER_PIDS+=("$pid")
    fi
    return 0
  fi
}

# True if pid already appears in a describe_agent line list (pid=N ...).
lines_have_pid() {
  local want=$1 line
  shift
  for line in "$@"; do
    [[ "$line" == "pid=${want} "* ]] && return 0
  done
  return 1
}

# Guarantee: when find_self_agent_pid found an invoker, it is always listed
# under KEEP with the SELF tag (never silent-omit, never kill-listed).
ensure_self_listed() {
  local pid line i new_orphans=() new_orphan_lines=()
  pid="${SELF_AGENT_PID:-}"
  [[ -n "$pid" ]] || return 0
  [[ -d "/proc/$pid" ]] || return 0

  # Strip SELF from orphan lists if a prior classify put it there.
  if ((${#ORPHAN_PIDS[@]} > 0)); then
    for i in "${!ORPHAN_PIDS[@]}"; do
      if [[ "${ORPHAN_PIDS[$i]}" == "$pid" ]]; then
        continue
      fi
      new_orphans+=("${ORPHAN_PIDS[$i]}")
      new_orphan_lines+=("${ORPHAN_LINES[$i]}")
    done
    ORPHAN_PIDS=("${new_orphans[@]+"${new_orphans[@]}"}")
    ORPHAN_LINES=("${new_orphan_lines[@]+"${new_orphan_lines[@]}"}")
  fi

  # Already a KEEP line for this pid?
  if ((${#KEPT_LINES[@]} > 0)) && lines_have_pid "$pid" "${KEPT_LINES[@]}"; then
    return 0
  fi

  # Force KEEP even if is_grok_agent failed mid-scan or attachment flaked:
  # the invoker is definitionally live enough to be running this script.
  line="$(describe_agent "$pid" KEEP)"
  KEPT_LINES+=("$line")
}

# --- identify calling session first (for SELF tag) ---
find_self_agent_pid

# --- scan ---
for status in /proc/[0-9]*/status; do
  [[ -r "$status" ]] || continue
  pid="${status#/proc/}"
  pid="${pid%/status}"
  classify_pid "$pid"
done

# --- force SELF into KEEP when detected but omitted ---
ensure_self_listed

# Sort KEEP lines by pid for stable reports (noglob: lines may contain * ? [])
if ((${#KEPT_LINES[@]} > 0)); then
  # shellcheck disable=SC2207
  set -f
  IFS=$'\n' KEPT_LINES=($(printf '%s\n' "${KEPT_LINES[@]}" | LC_ALL=C sort))
  unset IFS
  set +f
fi

# --- kill orphans (agents first) — skipped in check mode ---
if [[ "$MODE" == "kill" ]]; then
  for pid in "${ORPHAN_PIDS[@]+"${ORPHAN_PIDS[@]}"}"; do
    # Never kill the session running us (should not be in ORPHAN_PIDS if attached)
    if [[ -n "$SELF_AGENT_PID" && "$pid" == "$SELF_AGENT_PID" ]]; then
      SKIPPED+=("pid=$pid reason=self_session")
      continue
    fi
    # Re-validate immediately before signal (TOCTOU belt)
    if ! owned_by_us "$pid" \
      || has_live_terminal_attachment "$pid" \
      || ! is_grok_agent "$pid"; then
      SKIPPED+=("pid=$pid reason=failed_pre_kill_recheck")
      continue
    fi
    if kill -TERM "$pid" 2>/dev/null; then
      KILLED+=("$pid")
    else
      FAILED+=("$pid TERM")
    fi
  done

  # brief grace
  if ((${#KILLED[@]} > 0)); then
    sleep 1
  fi

  for pid in "${KILLED[@]+"${KILLED[@]}"}"; do
    if [[ -d "/proc/$pid" ]]; then
      if owned_by_us "$pid" && ! has_live_terminal_attachment "$pid" \
        && is_grok_agent_exe "$pid" 2>/dev/null; then
        if kill -KILL "$pid" 2>/dev/null; then
          :
        else
          FAILED+=("$pid KILL")
        fi
      fi
    fi
  done

  # --- wrappers only if still up and no attached grok child ---
  for pid in "${WRAPPER_PIDS[@]+"${WRAPPER_PIDS[@]}"}"; do
    [[ -d "/proc/$pid" ]] || continue
    if ! owned_by_us "$pid" || has_live_terminal_attachment "$pid" \
      || ! is_orphan_grok_wrapper "$pid"; then
      SKIPPED+=("pid=$pid reason=wrapper_recheck_failed")
      continue
    fi
    has_attached_grok_child=0
    for cstatus in /proc/[0-9]*/status; do
      [[ -r "$cstatus" ]] || continue
      cpid="${cstatus#/proc/}"
      cpid="${cpid%/status}"
      c_ppid="$(awk '/^PPid:/{print $2; exit}' "$cstatus" 2>/dev/null || true)"
      [[ "$c_ppid" == "$pid" ]] || continue
      if is_grok_agent_exe "$cpid" 2>/dev/null && has_live_terminal_attachment "$cpid"; then
        has_attached_grok_child=1
        break
      fi
    done
    if ((has_attached_grok_child)); then
      SKIPPED+=("pid=$pid reason=wrapper_has_attached_child")
      continue
    fi
    if kill -TERM "$pid" 2>/dev/null; then
      WRAPPER_KILLED+=("$pid")
    else
      FAILED+=("$pid wrapper_TERM")
    fi
  done
fi

# --- report (stdout; agent pastes this) ---
cat <<EOF
=== deorphan report ===
time_utc: $REPORT_TS
mode: $MODE
host: $(hostname -s 2>/dev/null || hostname)
user: $(id -un) uid=$UID
self_agent_pid: ${SELF_AGENT_PID:-unknown}
scope: uid=$UID grok agents; KEEP=live terminal; ORPHAN=no live terminal (deleted pts alone = orphan)
note: KEEP always lists every attached session including SELF (the invoker)

attached_grok_sessions: ${#KEPT_LINES[@]}
EOF

if ((${#KEPT_LINES[@]} > 0)); then
  for line in "${KEPT_LINES[@]}"; do
    echo "  KEEP  $line"
  done
else
  echo "  (none)"
fi

echo "orphans_found: ${#ORPHAN_LINES[@]}"
if ((${#ORPHAN_LINES[@]} > 0)); then
  for line in "${ORPHAN_LINES[@]}"; do
    echo "  ORPHAN $line"
  done
else
  echo "  (none)"
fi

if [[ "$MODE" == "check" ]]; then
  echo "action: none (check-only; no signals sent)"
  if ((${#ORPHAN_PIDS[@]} > 0)); then
    echo "would_term_agent_pids: ${ORPHAN_PIDS[*]}"
  else
    echo "would_term_agent_pids: (none)"
  fi
  if ((${#WRAPPER_PIDS[@]} > 0)); then
    echo "would_consider_wrapper_pids: ${WRAPPER_PIDS[*]}"
  else
    echo "would_consider_wrapper_pids: (none)"
  fi
else
  echo "agents_signaled_term: ${#KILLED[@]}"
  if ((${#KILLED[@]} > 0)); then
    echo "  pids: ${KILLED[*]}"
  fi

  echo "wrappers_term: ${#WRAPPER_KILLED[@]}"
  if ((${#WRAPPER_KILLED[@]} > 0)); then
    echo "  pids: ${WRAPPER_KILLED[*]}"
  fi

  echo "skipped: ${#SKIPPED[@]}"
  if ((${#SKIPPED[@]} > 0)); then
    for line in "${SKIPPED[@]}"; do
      echo "  SKIP  $line"
    done
  fi

  echo "failures: ${#FAILED[@]}"
  if ((${#FAILED[@]} > 0)); then
    for line in "${FAILED[@]}"; do
      echo "  FAIL  $line"
    done
  fi

  still=0
  for pid in "${KILLED[@]+"${KILLED[@]}"}"; do
    if [[ -d "/proc/$pid" ]]; then
      echo "  STILL_ALIVE pid=$pid"
      still=$((still + 1))
    fi
  done
  echo "agents_still_alive_after: $still"
fi
echo "=== end deorphan ==="
