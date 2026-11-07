#!/bin/bash
# Starts ONE throwaway Claude session for testing ccgovd governing, in a scratch dir under $TMPDIR/ccterm-test/.
#   1. `claude -p "reply with OK" --model haiku --session-id <uuid>` writes the transcript.
#   2. `claude --resume <uuid>` runs in a PTY that answers terminal queries: a private tmux server (-L ccterm-test-*),
#      never the user's own tmux. `PTY=script` uses `script -q /dev/null claude ...` instead; that PTY has no terminal
#      emulator behind it and in testing the session never registered in `claude agents --json`.
# A new folder shows the trust dialog; Enter (default "Yes") is sent for THIS scratch dir only.
# Prints SCRATCH=, SESSION=, ROOT_PID=, READY on stdout, then waits. Ctrl-C / SIGTERM (or exit) kills everything it started.
set -u

BASE="${TMPDIR:-/tmp}/ccterm-test"
mkdir -p "$BASE"
SCRATCH="$(cd "$(mktemp -d "$BASE/session.XXXXXX")" && pwd -P)"
SESSION="$(uuidgen | tr 'A-Z' 'a-z')"
CLAUDE="${CCTERM_CLAUDE_PATH:-$HOME/.local/bin/claude}"
TMUX_SOCK="ccterm-test-${SESSION%%-*}"
ROOT_PID=""

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$ROOT_PID" ] && ps -o command= -p "$ROOT_PID" 2>/dev/null | grep -q -- "$SESSION"; then
    pkill -TERM -P "$ROOT_PID" 2>/dev/null
    kill -TERM "$ROOT_PID" 2>/dev/null
  fi
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null   # only our private server
  pkill -TERM -P $$ 2>/dev/null                   # script(1) wrapper / stdin keeper if PTY=script
  sleep 1
  if [ -n "$ROOT_PID" ] && ps -o command= -p "$ROOT_PID" 2>/dev/null | grep -q -- "$SESSION"; then
    kill -KILL "$ROOT_PID" 2>/dev/null
  fi
  echo "CLEANED $SESSION"
}
trap cleanup EXIT INT TERM

cd "$SCRATCH" || exit 1
"$CLAUDE" -p "reply with OK" --model haiku --session-id "$SESSION" </dev/null
echo "FIRST_PROMPT_DONE rc=$?"

if [ "${PTY:-tmux}" = "script" ]; then
  script -q /dev/null "$CLAUDE" --resume "$SESSION" < <(for _ in 1 2 3 4 5 6 7; do sleep 3; printf '\r'; done; exec tail -f /dev/null) >/dev/null 2>&1 &
else
  tmux -L "$TMUX_SOCK" new-session -d -x 120 -y 40 -c "$SCRATCH" "$CLAUDE" --resume "$SESSION"
  ( for _ in 1 2 3 4 5; do sleep 3; tmux -L "$TMUX_SOCK" send-keys Enter 2>/dev/null; done ) &
fi

for _ in $(seq 1 60); do
  for p in $(pgrep -x claude); do
    if ps -o command= -p "$p" 2>/dev/null | grep -q -- "--resume $SESSION"; then ROOT_PID="$p"; break 2; fi
  done
  sleep 0.5
done

echo "SCRATCH=$SCRATCH"
echo "SESSION=$SESSION"
echo "ROOT_PID=$ROOT_PID"
[ -n "$ROOT_PID" ] && echo "READY"
# Stay alive (so the trap can clean up) until the session's root process is gone.
while [ -n "$ROOT_PID" ] && ps -p "$ROOT_PID" >/dev/null 2>&1; do sleep 1; done
