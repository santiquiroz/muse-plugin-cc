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
  printf 'GIT_CONFIG_COUNT=%s\n' "${GIT_CONFIG_COUNT-}"
  for ((index=0; index<${GIT_CONFIG_COUNT:-0}; index++)); do
    key="GIT_CONFIG_KEY_$index"
    value="GIT_CONFIG_VALUE_$index"
    printf '%s=%s\n' "$key" "${!key-}"
    printf '%s=%s\n' "$value" "${!value-}"
  done
} >"$calls/$number.env"

case "${FAKE_MUSE_MODE:-ok}" in
  sleep)
    sleep "${FAKE_MUSE_SLEEP:-30}" &
    child_pid=$!
    [ -z "${FAKE_MUSE_CHILD_PID_FILE:-}" ] || printf '%s\n' "$child_pid" >"$FAKE_MUSE_CHILD_PID_FILE"
    wait "$child_pid"
    exit 0
    ;;
  partial)
    printf '%s\n' '{"stream":{"kind":"session","id":"session-partial"},"payload_type":"run.model.configured","payload":{"model_id":"model-partial"}}'
    printf '%s\n' '{"payload_type":"tool.result","payload":{"edit_facts":{"tool_name":"write_file","path":"first.txt"}}}'
    printf '%s' '{"payload_type":"tool.result","payload":{"edit_facts":{"tool_name":"write_file","path":"trailing'
    : >"$calls/partial-ready"
    sleep "${FAKE_MUSE_SLEEP:-4}"
    printf '%s\n' '.txt"}}}'
    printf '%s\n' '{"payload_type":"run.terminal.completed","payload":{"terminal":"completed","text":"Detached final answer."}}'
    exit "${FAKE_MUSE_EXIT:-0}"
    ;;
  commit) git commit --allow-empty -q -m fake || exit $? ;;
esac

cat "${FAKE_MUSE_FIXTURE:?}"
if [ -n "${FAKE_MUSE_STDERR:-}" ]; then cat "$FAKE_MUSE_STDERR" >&2; fi
exit "${FAKE_MUSE_EXIT:-0}"
