#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"${FAKE_MUSE_KILL_CALLS:?}"
pid=${4:-}
[[ $pid =~ ^[0-9]+$ ]] || exit 64
if [ "${FAKE_MUSE_KILL_RECORD_ONLY:-0}" = 1 ]; then exit 0; fi
shell_pid=$(ps -e -l | awk -v native="$pid" '
  NR == 1 {for (i=1; i<=NF; i++) {if ($i == "WINPID") win=i; if ($i == "PID") id=i} next}
  win && $win == native {print $id; exit}')
[ -z "$shell_pid" ] || pid=$shell_pid

stop_tree() {
  local parent=$1 child children
  if ps -e -o pid=,ppid= >/dev/null 2>&1; then
    children=$(ps -e -o pid=,ppid= | awk -v parent="$parent" '$2 == parent {print $1}')
  else
    children=$(ps -e | awk -v parent="$parent" 'NR > 1 && $2 == parent {print $1}')
  fi
  for child in $children; do stop_tree "$child"; done
  kill -KILL "$parent" 2>/dev/null || :
}

stop_tree "$pid"
