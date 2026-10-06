#!/usr/bin/env bash
set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
FIXTURES="$TEST_DIR/fixtures"
FORWARDER="$ROOT/scripts/muse-forward.sh"
FILTER=${1:-}
REAL_GIT=$(command -v git 2>/dev/null || :)
REAL_NODE=$(command -v node 2>/dev/null || :)
REAL_BASH=$(command -v bash 2>/dev/null || :)
REAL_GIT_DIR=${REAL_GIT%/*}
REAL_NODE_DIR=${REAL_NODE%/*}
TOTAL=0
FAILED=0
RUN_COUNT=0
TEST_FAILED=0
CALL_ARGS=()

fail() { printf '  FAIL: %s\n' "$1"; TEST_FAILED=1; }
assert_status() { [ "$1" = "$2" ] || fail "$3 (expected exit $1, got $2)"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing: $2)" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected: $2)" ;; *) ;; esac; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

new_sandbox() {
  SANDBOX=$(mktemp -d) || exit 1
  export HOME="$SANDBOX/home"
  export USERPROFILE="$HOME"
  if command -v cygpath >/dev/null 2>&1; then USERPROFILE=$(cygpath -w "$HOME"); export USERPROFILE; fi
  export LOCALAPPDATA="$HOME/AppData/Local"
  export FAKE_MUSE_CALLS="$HOME/calls"
  export FAKE_MUSE_FIXTURE="$FIXTURES/completed.jsonl"
  mkdir -p "$HOME" "$LOCALAPPDATA" "$FAKE_MUSE_CALLS" "$HOME/bin"
  printf '%s\n' '{"schema_version":1,"providers":{"meta":{"access_token":"fake-test-value"}}}' >"$HOME/.config-placeholder"
  mkdir -p "$HOME/.config/muse"
  cp "$HOME/.config-placeholder" "$HOME/.config/muse/auth.json"
  rm -f "$HOME/.config-placeholder"
  cp "$TEST_DIR/fake-muse.sh" "$HOME/bin/fake-muse"
  chmod +x "$HOME/bin/fake-muse"
  export MUSE_BIN="$HOME/bin/fake-muse"
  export MUSE_RESCUE_HOME="$HOME/.muse-rescue"
  cp "$TEST_DIR/fake-kill.sh" "$HOME/bin/fake-kill"
  cp "$TEST_DIR/fake-powershell.sh" "$HOME/bin/fake-powershell"
  chmod +x "$HOME/bin/fake-kill" "$HOME/bin/fake-powershell"
  export MUSE_RESCUE_PS="$HOME/bin/fake-powershell"
  export FAKE_MUSE_PS_CALLS="$HOME/ps.calls" FAKE_MUSE_PS_FIXTURE="$HOME/processes.json"
  export FAKE_MUSE_KILL_CALLS="$HOME/kill.calls"
  printf '[]\n' >"$FAKE_MUSE_PS_FIXTURE"
  unset META_API_KEY FAKE_MUSE_MODE FAKE_MUSE_EXIT FAKE_MUSE_STDERR
  unset FAKE_MUSE_SLEEP FAKE_MUSE_CHILD_PID_FILE FAKE_MUSE_KILL_RECORD_ONLY
  unset MUSE_RESCUE_MAX_SECONDS MUSE_RESCUE_KILL
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MUSE_RESCUE_KILL="$HOME/bin/fake-kill" ;;
  esac
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
  unset GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
  unset MUSE_RESCUE_TIMEOUT MUSE_RESCUE_FORCE_WINDOWS FAKE_MUSE_SANDBOX_STATUS FAKE_MUSE_SANDBOX_EXIT
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL GIT_TERMINAL_PROMPT GIT_SSH_COMMAND MUSE_RESCUE_META_FILE
  PATH="$HOME/bin:/usr/bin:/bin"
  [ -n "$REAL_GIT_DIR" ] && PATH="$PATH:$REAL_GIT_DIR"
  [ -n "$REAL_NODE_DIR" ] && PATH="$PATH:$REAL_NODE_DIR"
  export PATH
  BASE_TEST_PATH=$PATH
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.name "Muse Rescue Test"
  git config --global user.email "muse-rescue-test@example.invalid"
  mkdir -p "$HOME/repo"
  (
    cd "$HOME/repo" || exit 1
    git init -q &&
      printf '%s\n' 'test workspace' >README.md &&
      git add README.md &&
      git commit -q -m initial
  ) || exit 1
  : >"$HOME/task.txt"
}

invoke_args() {
  LAST_OUTPUT=$(cd "$HOME/repo" && "$REAL_BASH" "$FORWARDER" "$@" 2>&1)
  LAST_STATUS=$?
}
invoke_file() {
  input=$1
  shift
  LAST_OUTPUT=$(cd "$HOME/repo" && "$REAL_BASH" "$FORWARDER" "$@" <"$input" 2>&1)
  LAST_STATUS=$?
}
invoke_text() {
  text=$1
  shift
  LAST_OUTPUT=$(cd "$HOME/repo" && printf '%s' "$text" | "$REAL_BASH" "$FORWARDER" "$@" 2>&1)
  LAST_STATUS=$?
}

load_call_args() {
  CALL_ARGS=()
  while IFS= read -r -d '' arg; do CALL_ARGS[${#CALL_ARGS[@]}]=$arg; done <"$FAKE_MUSE_CALLS/$1.args"
}
has_arg() {
  for arg in "${CALL_ARGS[@]}"; do [ "$arg" = "$1" ] && return 0; done
  return 1
}
arg_value() {
  local wanted=$1 i
  for ((i=0; i<${#CALL_ARGS[@]}; i++)); do
    if [ "${CALL_ARGS[$i]}" = "$wanted" ]; then
      [ $((i + 1)) -lt "${#CALL_ARGS[@]}" ] && printf '%s' "${CALL_ARGS[$((i + 1))]}"
      return 0
    fi
  done
  return 1
}
assert_arg() { has_arg "$1" || fail "$2 (missing argument: $1)"; }
assert_no_arg() { has_arg "$1" && fail "$2 (unexpected argument: $1)" || :; }

test_preflight_auth_file() {
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "Auth-file preflight"
  assert_contains "$LAST_OUTPUT" 'Muse Code 1.4.3' "Muse version"
  assert_not_contains "$LAST_OUTPUT" 'fake-test-value' "Credential is not printed"
}
test_preflight_api_key() {
  rm -f "$HOME/.config/muse/auth.json"
  export META_API_KEY=fake-api-key
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "META_API_KEY preflight"
}
test_preflight_no_auth() {
  rm -f "$HOME/.config/muse/auth.json"
  unset META_API_KEY
  invoke_args preflight
  assert_status 70 "$LAST_STATUS" "Missing-auth preflight"
  assert_contains "$LAST_OUTPUT" 'muse login' "Login guidance"
}
test_node_missing() {
  PATH="$HOME/bin"
  export PATH
  invoke_args preflight
  assert_status 127 "$LAST_STATUS" "Missing Node preflight"
  assert_contains "$LAST_OUTPUT" 'node is required on PATH' "Node guidance"
  PATH=$BASE_TEST_PATH
  export PATH
}
test_preflight_windows_ready() {
  export MUSE_RESCUE_FORCE_WINDOWS=1 FAKE_MUSE_SANDBOX_STATUS=ready
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "Windows sandbox ready"
}
test_preflight_windows_not_ready() {
  export MUSE_RESCUE_FORCE_WINDOWS=1 FAKE_MUSE_SANDBOX_STATUS=missing
  invoke_args preflight
  assert_status 78 "$LAST_STATUS" "Windows sandbox missing"
  assert_contains "$LAST_OUTPUT" 'muse sandbox windows setup' "Windows setup guidance"
}
test_launcher_override() {
  install="$LOCALAPPDATA/Programs/muse"
  mkdir -p "$install"
  cp "$TEST_DIR/fake-muse.sh" "$install/muse-bin-9.9.9.exe"
  chmod +x "$install/muse-bin-9.9.9.exe"
  printf '%s\n' '9.9.9' >"$install/.muse-version"
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "MUSE_BIN launcher"
  [ -f "$MUSE_BIN" ] || fail "MUSE_BIN fake file missing"
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "MUSE_BIN launcher priority"
  assert_equal "$MUSE_BIN" "$(cat "$FAKE_MUSE_CALLS/1.launcher")" "MUSE_BIN overrides installed binary"
}
test_launcher_version_file() {
  unset MUSE_BIN
  install="$LOCALAPPDATA/Programs/muse"
  mkdir -p "$install"
  cp "$TEST_DIR/fake-muse.sh" "$install/muse-bin-1.4.3-R5018.1.exe"
  chmod +x "$install/muse-bin-1.4.3-R5018.1.exe"
  printf '%s\n' '1.4.3-R5018.1' >"$install/.muse-version"
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Versioned launcher run"
  assert_equal "$install/muse-bin-1.4.3-R5018.1.exe" "$(cat "$FAKE_MUSE_CALLS/1.launcher")" "Versioned binary selected"
}
test_exact_exec_argv_prompt_and_env() {
  invoke_text 'specific task' run --model 'Muse-1.4' --reasoning-effort xhigh --max-model-steps 17
  assert_status 0 "$LAST_STATUS" "Configured run"
  load_call_args 1
  for fixed in exec --json --prompt-file --workspace --approval-mode never --approval-judge off \
    --no-foreign-personal-context --user-input-auto-resolve --max-model-steps 17 \
    --model Muse-1.4 --reasoning-effort xhigh; do
    assert_arg "$fixed" "Fixed/optional exec argument"
  done
  assert_equal never "$(arg_value --approval-mode)" "Approval mode value"
  assert_equal off "$(arg_value --approval-judge)" "Approval judge value"
  assert_equal 17 "$(arg_value --max-model-steps)" "Max model steps"
  assert_equal Muse-1.4 "$(arg_value --model)" "Model value"
  assert_equal xhigh "$(arg_value --reasoning-effort)" "Reasoning value"
  expected_workspace="$HOME/repo"
  if command -v cygpath >/dev/null 2>&1; then expected_workspace=$(cygpath -w "$expected_workspace"); fi
  assert_equal "$expected_workspace" "$(arg_value --workspace)" "Workspace path"
  expected_args=(exec --json --prompt-file "$(arg_value --prompt-file)" --workspace "$expected_workspace"
    --approval-mode never --approval-judge off --no-foreign-personal-context
    --user-input-auto-resolve --max-model-steps 17 --model Muse-1.4 --reasoning-effort xhigh)
  assert_equal "${#expected_args[@]}" "${#CALL_ARGS[@]}" "Exact argv length"
  for ((i=0; i<${#expected_args[@]}; i++)); do
    assert_equal "${expected_args[$i]}" "${CALL_ARGS[$i]}" "Exact argv item $i"
  done
  prompt=$(cat "$FAKE_MUSE_CALLS/1.prompt")
  expected_prompt=$(printf '%s\n\n%s' 'specific task' 'Constraints: work directly in this workspace following the instructions above. Do not invoke other AI CLIs (claude, codex, copilot, agy, gemini, ollama, cursor-agent, muse). Do not commit, push, reset, checkout, clean, switch branches or delete files. If a command is denied by policy, stop and report it — do not look for another way to run it. Leave your changes in the working tree and end with a short list of the files you touched.')
  assert_equal "$expected_prompt" "$prompt" "Exact prompt task and constraints"
  assert_equal '' "$(cat "$FAKE_MUSE_CALLS/1.stdin")" "Child stdin is closed"
  assert_equal 0 "$(wc -c <"$FAKE_MUSE_CALLS/1.stdin" | tr -d ' ')" "No task passed on stdin"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_TERMINAL_PROMPT=0' "Git prompt disabled"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_SSH_COMMAND=ssh -o BatchMode=yes' "Batch SSH"
}
test_default_flags() {
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Default run"
  load_call_args 1
  assert_equal 60 "$(arg_value --max-model-steps)" "Default max model steps"
  assert_no_arg --model "Default model omitted"
  assert_no_arg --reasoning-effort "Default reasoning omitted"
}
test_read_only() {
  invoke_text 'review this code' run --read-only
  assert_status 0 "$LAST_STATUS" "Read-only run"
  load_call_args 1
  assert_arg --disable-write "Read-only write disable"
  assert_arg --disable-shell "Read-only shell disable"
  prompt=$(cat "$FAKE_MUSE_CALLS/1.prompt")
  expected_prompt=$(printf '%s\n\n%s' 'review this code' 'Constraints: this is a read-only run: do not edit files or run shell commands; report findings and proposed changes as text. Do not invoke other AI CLIs (claude, codex, copilot, agy, gemini, ollama, cursor-agent, muse).')
  assert_equal "$expected_prompt" "$prompt" "Read-only prompt and constraints"
}
test_progress_and_final_once() {
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Progress run"
  assert_contains "$LAST_OUTPUT" '  ~ opening meta model stream attempt 2/10' "Retry progress"
  assert_contains "$LAST_OUTPUT" '  > write_file hello.txt' "Write progress"
  assert_contains "$LAST_OUTPUT" '  x write_file: tool failed: absolute path is outside the workspace' "Denied write progress"
  assert_contains "$LAST_OUTPUT" '  > powershell curl -s -m 5 -o NUL' "Shell progress"
  assert_contains "$LAST_OUTPUT" "  x powershell: Invoke-WebRequest : The parameter name 'm' is ambiguous." "Shell failure"
  assert_contains "$LAST_OUTPUT" 'Muse completed the requested change.' "Terminal answer"
  assert_not_contains "$LAST_OUTPUT" 'Partial answer that must not print' "Deltas suppressed"
  assert_equal 1 "$(printf '%s\n' "$LAST_OUTPUT" | grep -c 'Muse completed the requested change\.')" "Final answer once"
  assert_contains "$LAST_OUTPUT" 'session session-muse-abc, model muse-test-model' "Run summary metadata"
}
test_failed_terminal() {
  export FAKE_MUSE_FIXTURE="$FIXTURES/failed-terminal.jsonl" FAKE_MUSE_EXIT=1
  invoke_text task run
  assert_status 1 "$LAST_STATUS" "Failed terminal passthrough"
  assert_contains "$LAST_OUTPUT" 'Muse run failed: model execution stopped' "Failure reason printed"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] error in' "Error summary"
}
test_rate_limit() {
  export FAKE_MUSE_FIXTURE="$FIXTURES/rate-limit.jsonl" FAKE_MUSE_EXIT=1
  invoke_text task run
  assert_status 1 "$LAST_STATUS" "Rate-limit exit passthrough"
  assert_contains "$LAST_OUTPUT" '429 rate limit: usage limit reached' "Rate-limit reason surfaced"
}
test_forbidden_flags() {
  local flag
  for flag in --yolo --disable-sandbox --disable-approval --trust-workspace; do
    invoke_text task run "$flag"
    assert_status 64 "$LAST_STATUS" "Refusal $flag"
    [ ! -e "$FAKE_MUSE_CALLS/1.args" ] || fail "$flag reached Muse"
  done
  invoke_text task run --sandbox-network enabled
  assert_status 64 "$LAST_STATUS" "Refusal sandbox network enabled"
  [ ! -e "$FAKE_MUSE_CALLS/1.args" ] || fail "Unsafe network setting reached Muse"
}
test_invalid_options() {
  invoke_text task run --model 'bad model'
  assert_status 64 "$LAST_STATUS" "Invalid model"
  invoke_text task run --reasoning-effort extreme
  assert_status 64 "$LAST_STATUS" "Invalid reasoning effort"
  invoke_text task run --unknown
  assert_status 64 "$LAST_STATUS" "Unknown option"
  invoke_text '   ' run
  assert_status 64 "$LAST_STATUS" "Empty task"
  [ ! -e "$FAKE_MUSE_CALLS/1.args" ] || fail "Invalid request reached Muse"
}
test_appdata_warning() {
  export USERPROFILE="$HOME"
  if command -v cygpath >/dev/null 2>&1; then USERPROFILE=$(cygpath -w "$HOME"); fi
  export USERPROFILE
  appdata_workspace="$HOME/AppData/Local/Temp/private"
  mkdir -p "$appdata_workspace"
  LAST_OUTPUT=$(cd "$appdata_workspace" && printf task | "$REAL_BASH" "$FORWARDER" run 2>&1)
  LAST_STATUS=$?
  assert_status 0 "$LAST_STATUS" "AppData warning run"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] WARNING: workspace is under your profile' "AppData warning"
  assert_contains "$LAST_OUTPUT" 'Muse'\''s sandboxed shell hangs there' "Warning explains hang"
}
test_timeout() {
  export MUSE_RESCUE_TIMEOUT=2 FAKE_MUSE_MODE=sleep
  invoke_text task run
  case $LAST_STATUS in 124|137|142) ;; *) fail "Timeout exit code $LAST_STATUS" ;; esac
  assert_contains "$LAST_OUTPUT" 'timed out after 2s' "Timeout notice"
}
test_exit_passthrough_and_git_warning() {
  export FAKE_MUSE_MODE=commit
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Commit warning run"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] WARNING: HEAD changed' "Commit warning"

  export FAKE_MUSE_MODE=ok FAKE_MUSE_EXIT=23
  invoke_text task run
  assert_status 23 "$LAST_STATUS" "CLI exit passthrough"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] exit 23' "Exit summary"
}
test_manifests() {
  plugin_version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -n 1)
  marketplace_versions=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/marketplace.json")
  changelog_version=$(sed -n 's/^## \([^ ]*\).*/\1/p' "$ROOT/CHANGELOG.md" | head -n 1)
  assert_equal 0.2.0 "$plugin_version" "Plugin version"
  assert_equal "$plugin_version" "$changelog_version" "Changelog version"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '1p')" "Marketplace metadata version"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '2p')" "Marketplace plugin version"
}

await_file() {
  local attempt=0
  while [ ! -f "$1" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$1" ] || fail "Fake launcher did not create $1"
}

start_job() {
  invoke_text 'detached task' start "$@"
  assert_status 0 "$LAST_STATUS" "Detached start"
  JOB_ID=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^\[muse-rescue\] started job //p')
  [ -n "$JOB_ID" ] || fail "Start returned no job id"
  JOB_DIR="$MUSE_RESCUE_HOME/jobs/$JOB_ID"
}

assert_child_stopped() {
  local child_pid attempt=0
  child_pid=$(cat "$FAKE_MUSE_CHILD_PID_FILE")
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempt" -lt 30 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill -0 "$child_pid" 2>/dev/null && fail "Child process $child_pid survived termination" || :
}

test_start_metadata() {
  export FAKE_MUSE_MODE=sleep FAKE_MUSE_SLEEP=30
  start_job --model Muse-1.4 --reasoning-effort high --max-model-steps 17 --read-only
  assert_not_contains "$LAST_OUTPUT" 'done in' "Start returns before completion"
  for file in pid workspace started deadline git-before task prompt; do
    [ -s "$JOB_DIR/$file" ] || fail "Missing job metadata $file"
  done
  [ ! -e "$JOB_DIR/exit" ] || fail "Start waited for sleeping job"
  assert_equal 2700 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Default job deadline"
  await_file "$FAKE_MUSE_CALLS/1.env"
  load_call_args 1
  assert_arg --json "Detached JSON flag"
  assert_arg --disable-write "Detached read-only write disable"
  assert_arg --disable-shell "Detached read-only shell disable"
  assert_equal Muse-1.4 "$(arg_value --model)" "Detached model"
  assert_equal high "$(arg_value --reasoning-effort)" "Detached reasoning"
  assert_equal 17 "$(arg_value --max-model-steps)" "Detached steps"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.prompt")" 'Constraints: this is a read-only run' "Detached read-only constraints"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Metadata job cleanup"
}

test_wait_partial_progress() {
  export FAKE_MUSE_MODE=partial FAKE_MUSE_SLEEP=4
  start_job
  await_file "$FAKE_MUSE_CALLS/partial-ready"
  invoke_args wait "$JOB_ID" --slice 1
  assert_status 75 "$LAST_STATUS" "Running slice"
  assert_contains "$LAST_OUTPUT" '  > write_file first.txt' "Initial progress"
  assert_contains "$LAST_OUTPUT" "job $JOB_ID still running" "Running slice message"
  assert_not_contains "$LAST_OUTPUT" 'trailing' "Incomplete JSON remains buffered"
  [ -s "$JOB_DIR/offset" ] || fail "Wait did not persist stdout offset"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Completed later slice"
  assert_not_contains "$LAST_OUTPUT" 'first.txt' "Earlier progress not repeated"
  assert_contains "$LAST_OUTPUT" '  > write_file trailing.txt' "Split JSON completed"
  assert_contains "$LAST_OUTPUT" 'Detached final answer.' "Final answer"
  assert_equal 1 "$(printf '%s\n' "$LAST_OUTPUT" | grep -c 'Detached final answer.')" "Final answer printed once"
  assert_contains "$LAST_OUTPUT" 'session session-partial, model model-partial' "Cumulative metadata"
  for file in task prompt argv stdout stderr; do
    [ ! -e "$JOB_DIR/$file" ] || fail "Finished job retained $file"
  done
  invoke_args wait "$JOB_ID"
  assert_status 0 "$LAST_STATUS" "Cached completed wait"
  assert_contains "$LAST_OUTPUT" 'session session-partial, model model-partial' "Cached metadata"
  assert_not_contains "$LAST_OUTPUT" 'Detached final answer.' "Cached wait does not replay answer"
}

test_wait_final_without_newline() {
  printf '%s' '{"stream":{"kind":"session","id":"session-no-newline"},"payload_type":"run.terminal.completed","payload":{"terminal":"completed","text":"Final without a newline."}}' >"$HOME/no-newline.jsonl"
  export FAKE_MUSE_FIXTURE="$HOME/no-newline.jsonl"
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Unterminated JSON completion"
  assert_contains "$LAST_OUTPUT" 'Final without a newline.' "Unterminated final preserved"
  assert_contains "$LAST_OUTPUT" 'session session-no-newline' "Unterminated final session"
}

test_wait_nonzero_exit() {
  export FAKE_MUSE_FIXTURE="$FIXTURES/failed-terminal.jsonl" FAKE_MUSE_EXIT=23
  printf 'distinct stderr failure\n' >"$HOME/error.txt"
  export FAKE_MUSE_STDERR="$HOME/error.txt"
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 23 "$LAST_STATUS" "Detached failure passthrough"
  assert_contains "$LAST_OUTPUT" 'distinct stderr failure' "Detached failure stderr"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] error in' "Detached failure summary"
  invoke_args wait "$JOB_ID"
  assert_status 23 "$LAST_STATUS" "Cached detached failure"
  assert_not_contains "$LAST_OUTPUT" 'distinct stderr failure' "Cached stderr not replayed"
}

test_wait_workspace_warning() {
  export FAKE_MUSE_MODE=commit
  start_job
  LAST_OUTPUT=$(cd "$HOME" && "$REAL_BASH" "$FORWARDER" wait "$JOB_ID" --slice 10 2>&1)
  LAST_STATUS=$?
  assert_status 0 "$LAST_STATUS" "Wait outside job workspace"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] WARNING: HEAD changed' "Detached workspace HEAD warning"
}

test_wait_relative_home() {
  export MUSE_RESCUE_HOME=.relative-rescue
  start_job
  JOB_DIR="$HOME/repo/$MUSE_RESCUE_HOME/jobs/$JOB_ID"
  [ -s "$JOB_DIR/workspace" ] || fail "Relative home workspace metadata missing"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Relative job-home completion"
  [ -f "$JOB_DIR/finished" ] || fail "Relative home completion missing"
  invoke_args wait "$JOB_ID"
  assert_status 0 "$LAST_STATUS" "Relative job-home cached completion"
}

test_wait_deadline_tree() {
  export FAKE_MUSE_MODE=sleep FAKE_MUSE_SLEEP=30 MUSE_RESCUE_MAX_SECONDS=2
  export FAKE_MUSE_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  assert_equal 2 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Configured deadline"
  await_file "$FAKE_MUSE_CHILD_PID_FILE"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 124 "$LAST_STATUS" "Detached deadline"
  assert_contains "$LAST_OUTPUT" 'timed out after 2s' "Deadline notice"
  assert_contains "$LAST_OUTPUT" 'edits made until then are in the working tree' "Deadline edits message"
  assert_child_stopped
  invoke_args wait "$JOB_ID"
  assert_status 124 "$LAST_STATUS" "Cached deadline"
}

test_cancel_tree() {
  export FAKE_MUSE_MODE=sleep FAKE_MUSE_SLEEP=30
  export FAKE_MUSE_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  await_file "$FAKE_MUSE_CHILD_PID_FILE"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Detached cancel"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] exit 130' "Cancelled exit"
  assert_child_stopped
  invoke_args wait "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Cached cancellation"
}

check_windows_kill() {
  [ -s "$FAKE_MUSE_KILL_CALLS" ] || { fail "Windows tree kill was not called"; return; }
  local line
  while IFS= read -r line; do
    [[ $line =~ ^/T\ /F\ /PID\ [0-9]+$ ]] || fail "Wrong Windows tree kill arguments: $line"
  done <"$FAKE_MUSE_KILL_CALLS"
  assert_child_stopped
}

windows_sleep() {
  export MUSE_RESCUE_FORCE_WINDOWS=1 MUSE_RESCUE_KILL="$HOME/bin/fake-kill"
  export FAKE_MUSE_MODE=sleep FAKE_MUSE_SLEEP=30 FAKE_MUSE_CHILD_PID_FILE="$HOME/child.pid"
}

test_windows_cancel_tree() {
  windows_sleep
  start_job
  await_file "$FAKE_MUSE_CHILD_PID_FILE"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Windows cancel"
  check_windows_kill
}

test_windows_deadline_tree() {
  windows_sleep
  export MUSE_RESCUE_MAX_SECONDS=2
  start_job
  await_file "$FAKE_MUSE_CHILD_PID_FILE"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 124 "$LAST_STATUS" "Windows deadline"
  check_windows_kill
}

test_windows_run_timeout_tree() {
  windows_sleep
  export MUSE_RESCUE_TIMEOUT=2
  invoke_text task run
  assert_status 124 "$LAST_STATUS" "Windows short run timeout"
  assert_contains "$LAST_OUTPUT" 'timed out after 2s' "Short run timeout notice"
  check_windows_kill
}

test_preflight_orphan_cleanup() {
  export MUSE_RESCUE_FORCE_WINDOWS=1 MUSE_RESCUE_KILL="$HOME/bin/fake-kill"
  export FAKE_MUSE_KILL_RECORD_ONLY=1
  printf '%s\n' '[{"ProcessId":401,"ParentProcessId":999,"CommandLine":"muse-bin __tbh_internal_windows_sandbox_read_worker orphan"},{"ProcessId":402,"ParentProcessId":403,"CommandLine":"muse-bin __tbh_internal_windows_sandbox_read_worker live"},{"ProcessId":403,"ParentProcessId":1,"CommandLine":"muse-bin interactive"},{"ProcessId":404,"ParentProcessId":999,"CommandLine":"unrelated process"}]' >"$FAKE_MUSE_PS_FIXTURE"
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "Orphan cleanup preflight"
  assert_equal '/T /F /PID 401' "$(cat "$FAKE_MUSE_KILL_CALLS")" "Only orphan Muse worker killed"
  assert_contains "$LAST_OUTPUT" '[muse-rescue] killed 1 orphan Muse sandbox worker(s) left by an interrupted run' "Orphan cleanup notice"
  [ -s "$FAKE_MUSE_PS_CALLS" ] || fail "PowerShell inventory was not requested"
}

assert_safe_directory() {
  local call=$1 index=$2 expected="$HOME/repo"
  if command -v cygpath >/dev/null 2>&1; then expected=$(cygpath -m "$expected"); fi
  assert_contains "$(cat "$FAKE_MUSE_CALLS/$call.env")" "GIT_CONFIG_KEY_$index=safe.directory" "Safe-directory key"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/$call.env")" "GIT_CONFIG_VALUE_$index=$expected" "Forward-slash safe-directory workspace"
}

test_git_safe_directory_unset() {
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Safe-directory short run"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_CONFIG_COUNT=1' "First config entry count"
  assert_safe_directory 1 0
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Safe-directory detached run"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/2.env")" 'GIT_CONFIG_COUNT=1' "Detached config count"
  assert_safe_directory 2 0
}

test_git_safe_directory_append() {
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1=/preserved/workspace
  invoke_text task run
  assert_status 0 "$LAST_STATUS" "Appended safe-directory run"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_CONFIG_COUNT=3' "Appended config count"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_CONFIG_KEY_0=core.autocrlf' "Existing key preserved"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_CONFIG_VALUE_0=false' "Existing value preserved"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/1.env")" 'GIT_CONFIG_VALUE_1=/preserved/workspace' "Existing safe directory preserved"
  assert_safe_directory 1 2
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Appended detached config run"
  assert_contains "$(cat "$FAKE_MUSE_CALLS/2.env")" 'GIT_CONFIG_COUNT=3' "Detached appended config count"
  assert_safe_directory 2 2
  assert_equal 2 "$GIT_CONFIG_COUNT" "Caller config environment preserved"
  assert_not_contains "$(cat "$GIT_CONFIG_GLOBAL")" 'safe' "Global Git config unchanged"
}

test_detached_invalid_arguments() {
  for command in wait cancel; do
    invoke_args "$command" unknown-job
    assert_status 64 "$LAST_STATUS" "Unknown $command id"
    invoke_args "$command"
    assert_status 64 "$LAST_STATUS" "Missing $command id"
    invoke_args "$command" ../escape
    assert_status 64 "$LAST_STATUS" "Unsafe $command id"
  done
  invoke_text task start --model 'bad model'
  assert_status 64 "$LAST_STATUS" "Detached invalid model"
  invoke_text task start --unknown
  assert_status 64 "$LAST_STATUS" "Detached unknown option"
  for seconds in 0 invalid -1; do
    export MUSE_RESCUE_MAX_SECONDS=$seconds
    invoke_text task start
    assert_status 64 "$LAST_STATUS" "Invalid deadline $seconds"
  done
  unset MUSE_RESCUE_MAX_SECONDS
  start_job
  for slice in 0 541 invalid; do
    invoke_args wait "$JOB_ID" --slice "$slice"
    assert_status 64 "$LAST_STATUS" "Invalid slice $slice"
  done
  invoke_args wait "$JOB_ID" --unknown
  assert_status 64 "$LAST_STATUS" "Unknown wait option"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Validation job completion"
}

run_case() {
  local name=$1 function=$2
  if [ -n "$FILTER" ] && [ "$FILTER" != "$name" ] && [ "$FILTER" != "$function" ]; then return; fi
  RUN_COUNT=$((RUN_COUNT + 1))
  TOTAL=$((TOTAL + 1))
  TEST_FAILED=0
  new_sandbox
  "$function"
  if [ "$TEST_FAILED" -eq 0 ]; then printf 'PASS %s\n' "$name"
  else printf 'FAIL %s\n' "$name"; FAILED=$((FAILED + 1)); fi
  rm -rf "$SANDBOX"
}

run_case preflight-auth-file test_preflight_auth_file
run_case preflight-api-key test_preflight_api_key
run_case preflight-no-auth test_preflight_no_auth
run_case node-missing test_node_missing
run_case preflight-windows-ready test_preflight_windows_ready
run_case preflight-windows-not-ready test_preflight_windows_not_ready
run_case launcher-override test_launcher_override
run_case launcher-version-file test_launcher_version_file
run_case exact-argv-prompt-env test_exact_exec_argv_prompt_and_env
run_case default-flags test_default_flags
run_case read-only test_read_only
run_case progress-final test_progress_and_final_once
run_case failed-terminal test_failed_terminal
run_case rate-limit test_rate_limit
run_case forbidden-flags test_forbidden_flags
run_case invalid-options test_invalid_options
run_case appdata-warning test_appdata_warning
run_case timeout test_timeout
run_case exit-passthrough-git-warning test_exit_passthrough_and_git_warning
run_case start-metadata test_start_metadata
run_case wait-partial-progress test_wait_partial_progress
run_case wait-final-without-newline test_wait_final_without_newline
run_case wait-nonzero-exit test_wait_nonzero_exit
run_case wait-workspace-warning test_wait_workspace_warning
run_case wait-relative-home test_wait_relative_home
run_case wait-deadline-tree test_wait_deadline_tree
run_case cancel-tree test_cancel_tree
run_case windows-cancel-tree test_windows_cancel_tree
run_case windows-deadline-tree test_windows_deadline_tree
run_case windows-run-timeout-tree test_windows_run_timeout_tree
run_case preflight-orphan-cleanup test_preflight_orphan_cleanup
run_case git-safe-directory-unset test_git_safe_directory_unset
run_case git-safe-directory-append test_git_safe_directory_append
run_case detached-invalid-arguments test_detached_invalid_arguments
run_case manifests test_manifests

[ "$RUN_COUNT" -gt 0 ] || printf 'FAIL no test matched filter: %s\n' "$FILTER"
printf '%s/%s tests passed\n' "$((TOTAL - FAILED))" "$TOTAL"
[ "$RUN_COUNT" -gt 0 ] && [ "$FAILED" -eq 0 ]
