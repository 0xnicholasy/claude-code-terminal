#!/bin/bash
# Throwaway fleet of N idle Claude sessions for the memory target.
# Usage: scripts/fleet.sh start N | pids | rss | stop
# Every session lives in a scratch dir under $TMPDIR/ccterm-test/fleet-*; only processes recorded
# in the state file are ever stopped. Real sessions are never touched.
set -euo pipefail
ROOT="${TMPDIR%/}/ccterm-test"
STATE="$ROOT/fleet.state"   # lines: uuid dir wrapper_pid
CLAUDE="${CCTERM_CLAUDE_PATH:-$HOME/.local/bin/claude}"
mkdir -p "$ROOT"
# Session markers inherited from a parent Claude session make the child skip transcripts and
# stay out of `claude agents --json` (see tasks/lessons.md); strip them for every fleet process.
SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_BRIDGE_SESSION_ID
       -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_MESSAGING_SOCKET
       -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_PLUGIN_DATA -u AI_AGENT)

# claude root pid for a session uuid: the process running "$CLAUDE --resume <uuid>"
# (not the script(1) wrapper, whose argv also contains it).
claude_pid_for() {
  local uuid=$1
  ps -axo pid=,command= | awk -v c="$CLAUDE" -v u="--resume $uuid" '$2==c && index($0,u) {print $1}' | head -1
}

tree() { # $1 = root pid; prints root + descendants
  ps -axo pid=,ppid= | awk -v r="$1" '{p[$1]=$2} END{ s[r]=1; ch=1; while(ch){ch=0; for(k in p) if(!(k in s) && (p[k] in s)){s[k]=1; ch=1}} for(k in s) print k }'
}

case "${1:-}" in
  start)
    n=${2:-8}
    for i in $(seq 1 "$n"); do
      u=$(uuidgen | tr 'A-Z' 'a-z'); d="$ROOT/fleet-$i-$u"; mkdir -p "$d"
      (cd "$d" && env "${SCRUB[@]}" "$CLAUDE" -p "reply with OK" --model haiku --session-id "$u" >/dev/null 2>&1)
      (cd "$d" && nohup env "${SCRUB[@]}" script -q /dev/null "$CLAUDE" --resume "$u" </dev/null >/dev/null 2>&1 &
       echo "$u $d $!" >> "$STATE")
    done
    sleep 20; "$0" pids ;;
  pids)
    while read -r u d w; do p=$(claude_pid_for "$u"); echo "${p:-dead} $u $d"; done < "$STATE" ;;
  rss)
    total=0
    while read -r u d w; do
      p=$(claude_pid_for "$u"); [ -z "$p" ] && continue
      for q in $(tree "$p"); do r=$(ps -o rss= -p "$q" 2>/dev/null || echo 0); total=$((total + ${r:-0})); done
    done < "$STATE"
    echo "fleet_rss_kb=$total" ;;
  stop)
    [ -f "$STATE" ] || exit 0
    while read -r u d w; do
      p=$(claude_pid_for "$u")
      if [ -n "$p" ]; then for q in $(tree "$p"); do kill "$q" 2>/dev/null || true; done; fi
      kill "$w" 2>/dev/null || true
    done < "$STATE"
    mv "$STATE" "$STATE.done.$(date +%s)" ;;
  *) echo "usage: $0 start N | pids | rss | stop" >&2; exit 2 ;;
esac
