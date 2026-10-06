#!/usr/bin/env bash
set -u

if [ "${1:-}" = --version ]; then
  printf '%s\n' 'Muse Code 1.4.3 (1.4.3-R5018.1)'
  exit 0
fi

if [ "${1:-}" = sandbox ] && [ "${2:-}" = windows ]; then
  printf 'status=%s\n' "${FAKE_MUSE_SANDBOX_STATUS:-ready}"
  exit "${FAKE_MUSE_SANDBOX_EXIT:-0}"
fi

[ "${1:-}" = exec ] || exit 64
calls=${FAKE_MUSE_CALLS:?}
mkdir -p "$calls"
number=1
while [ -e "$calls/$number.args" ]; do number=$((number + 1)); done
printf '%s\0' "$@" >"$calls/$number.args"
printf '%s\n' "$0" >"$calls/$number.launcher"
prompt_file=""
previous=""
for arg in "$@"; do
  if [ "$previous" = --prompt-file ]; then prompt_file=$arg; previous=""; fi
  [ "$arg" = --prompt-file ] && previous=--prompt-file
done
[ -n "$prompt_file" ] && cat "$prompt_file" >"$calls/$number.prompt"
cat >"$calls/$number.stdin"
{
  printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-}"
  printf 'GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND-}"
  printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV-}"
  printf 'MSYS2_ARG_CONV_EXCL=%s\n' "${MSYS2_ARG_CONV_EXCL-}"
} >"$calls/$number.env"

case "${FAKE_MUSE_MODE:-ok}" in
  sleep) sleep 30; exit 0 ;;
  commit) git commit --allow-empty -q -m fake || exit $? ;;
esac

cat "${FAKE_MUSE_FIXTURE:?}"
if [ -n "${FAKE_MUSE_STDERR:-}" ]; then cat "$FAKE_MUSE_STDERR" >&2; fi
exit "${FAKE_MUSE_EXIT:-0}"
