#!/usr/bin/env bash
set -u

readonly USAGE_EXIT=64
readonly PREFLIGHT_FAILED_EXIT=70
readonly NOT_FOUND_EXIT=127
readonly DEFAULT_STEPS=60
readonly AI_CLIS="claude, codex, copilot, agy, gemini, ollama, cursor-agent, muse"
readonly CONSTRAINTS="Constraints: work directly in this workspace following the instructions above. Do not invoke other AI CLIs ($AI_CLIS). Do not commit, push, reset, checkout, clean, switch branches or delete files. If a command is denied by policy, stop and report it — do not look for another way to run it. Leave your changes in the working tree and end with a short list of the files you touched."
readonly READ_ONLY_CONSTRAINTS="Constraints: this is a read-only run: do not edit files or run shell commands; report findings and proposed changes as text. Do not invoke other AI CLIs ($AI_CLIS)."
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly RESCUE_HOME=$(rescue_home=${MUSE_RESCUE_HOME:-$HOME/.muse-rescue};
  if command -v cygpath >/dev/null 2>&1; then cygpath -au "$rescue_home";
  elif [[ $rescue_home = /* ]]; then printf '%s' "$rescue_home";
  else printf '%s/%s' "$PWD" "$rescue_home"; fi)

OPT_MODEL=""
OPT_REASONING=""
OPT_STEPS=$DEFAULT_STEPS
OPT_READ_ONLY=0
MUSE_LAUNCHER=""
RUN_TASK_FILE=""
RUN_PROMPT_FILE=""
RUN_STDERR_FILE=""
RUN_META_FILE=""

usage_error() {
  printf '[muse-rescue] %s\n' "$1" >&2
  exit "$USAGE_EXIT"
}

validate_model() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    usage_error "invalid model slug: $1"
}

parse_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      --model)
        [ $# -ge 2 ] || usage_error "--model needs a value"
        validate_model "$2"
        OPT_MODEL=$2
        shift 2
        ;;
      --reasoning-effort)
        [ $# -ge 2 ] || usage_error "--reasoning-effort needs a value"
        case $2 in
          none|minimal|low|medium|high|xhigh|max|ultra) OPT_REASONING=$2 ;;
          *) usage_error "invalid reasoning effort: $2" ;;
        esac
        shift 2
        ;;
      --max-model-steps)
        [ $# -ge 2 ] || usage_error "--max-model-steps needs a value"
        [[ $2 =~ ^[1-9][0-9]*$ ]] || usage_error "max model steps must be a positive integer"
        OPT_STEPS=$2
        shift 2
        ;;
      --read-only) OPT_READ_ONLY=1; shift ;;
      --yolo|--disable-sandbox|--disable-approval|--trust-workspace)
        usage_error "refusing unsafe option: $1"
        ;;
      --sandbox-network)
        [ $# -ge 2 ] || usage_error "--sandbox-network needs a value"
        [ "$2" = enabled ] && usage_error "refusing unsafe option: --sandbox-network enabled"
        usage_error "unsupported option: --sandbox-network $2"
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
}

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

find_launcher() {
  local install_dir version selected candidate uname_s
  if [ -n "${MUSE_BIN:-}" ]; then
    MUSE_LAUNCHER=$MUSE_BIN
    [ -f "$MUSE_LAUNCHER" ] && return 0
    return 1
  fi

  install_dir="${LOCALAPPDATA:-}/Programs/muse"
  if [ -n "${LOCALAPPDATA:-}" ] && [ -d "$install_dir" ]; then
    version=""
    if [ -r "$install_dir/.muse-version" ]; then
      IFS= read -r version <"$install_dir/.muse-version" || :
      version=${version%$'\r'}
    fi
    if [[ $version =~ ^[A-Za-z0-9._-]+$ ]]; then
      selected="$install_dir/muse-bin-$version.exe"
      if [ -f "$selected" ]; then
        MUSE_LAUNCHER=$selected
        return 0
      fi
    fi
    candidate=$(printf '%s\n' "$install_dir"/muse-bin-*.exe | LC_ALL=C sort -V | tail -n 1)
    [ -f "$candidate" ] || candidate=""
    if [ -n "$candidate" ]; then
      MUSE_LAUNCHER=$candidate
      return 0
    fi
  fi

  uname_s=$(uname -s 2>/dev/null || :)
  case $uname_s in
    MINGW*|MSYS*|CYGWIN*) return 1 ;;
  esac
  if command -v muse >/dev/null 2>&1; then
    MUSE_LAUNCHER=$(command -v muse)
    return 0
  fi
  return 1
}

require_node() {
  command -v node >/dev/null 2>&1 && return 0
  printf '[muse-rescue] node is required on PATH for JSONL output filtering\n' >&2
  return "$NOT_FOUND_EXIT"
}

require_launcher() {
  find_launcher && return 0
  printf '[muse-rescue] muse not found — install Muse Code or set MUSE_BIN, then run /muse:setup\n' >&2
  return "$NOT_FOUND_EXIT"
}

auth_present() {
  [ -n "${META_API_KEY:-}" ] && return 0
  local auth_file
  auth_file="${HOME}/.config/muse/auth.json"
  [ -r "$auth_file" ] || return 1
  node -e '
    const fs = require("fs");
    try {
      const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const meta = auth && auth.providers && auth.providers.meta;
      process.exit(meta && ((typeof meta.access_token === "string" && meta.access_token.length > 0) ||
        (typeof meta.api_key === "string" && meta.api_key.length > 0)) ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' "$auth_file" >/dev/null 2>&1
}

check_windows_sandbox() {
  local status output
  is_windows || return 0
  output=$("$MUSE_LAUNCHER" sandbox windows check 2>/dev/null) || output=""
  status=$(printf '%s\n' "$output" | sed -n 's/^status=//p' | sed -n '1p')
  [ "$status" = ready ] && return 0
  printf '[muse-rescue] Windows sandbox is not ready — run "muse sandbox windows setup" once from an elevated terminal, then /muse:setup\n' >&2
  return 78
}

preflight() {
  require_node || return $?
  require_launcher || return $?
  if ! auth_present; then
    printf '[muse-rescue] no Muse credentials — run "muse login" once in a normal terminal, then /muse:setup\n' >&2
    return "$PREFLIGHT_FAILED_EXIT"
  fi
  cleanup_orphans || return $?
  check_windows_sandbox || return $?
  local version
  version=$("$MUSE_LAUNCHER" --version 2>&1 | sed -n '1p')
  printf '[muse-rescue] preflight: muse %s, authentication ready\n' "${version:-unknown}"
  [ -n "$OPT_MODEL" ] && printf 'model: %s\n' "$OPT_MODEL"
  [ -n "$OPT_REASONING" ] && printf 'reasoning-effort: %s\n' "$OPT_REASONING"
  return 0
}

git_state() {
  local head branch stash config hooks git_dir common_dir hooks_dir
  git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || return 1
  head=$(git rev-parse -q --verify HEAD 2>/dev/null || printf none)
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || printf detached)
  stash=$(git rev-list --walk-reflogs --count refs/stash -- 2>/dev/null || printf 0)
  config=$(cksum "$common_dir/config" "$git_dir/config.worktree" 2>/dev/null | cksum | awk '{print $1 ":" $2}')
  [ -n "$config" ] || config=none
  hooks=$(find "$hooks_dir" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort | cksum | awk '{print $1 ":" $2}')
  [ -n "$hooks" ] || hooks=none
  printf 'HEAD\t%s\nbranch\t%s\nstash\t%s\nconfig\t%s\nhooks\t%s\n' "$head" "$branch" "$stash" "$config" "$hooks"
}

warn_git_changes() {
  local before=$1 after key old new
  [ -n "$before" ] || return 0
  after=$(git_state) || {
    printf '[muse-rescue] WARNING: git repository state is no longer readable — review before your next git command\n'
    return 0
  }
  while IFS=$'\t' read -r key old; do
    new=$(printf '%s\n' "$after" | awk -F '\t' -v k="$key" '$1 == k {print $2}')
    [ "$old" = "$new" ] && continue
    printf '[muse-rescue] WARNING: %s changed — review before your next git command\n' "$key"
  done <<<"$before"
}

is_windows() {
  case "${MUSE_RESCUE_FORCE_WINDOWS:-0}:$(uname -s 2>/dev/null || :)" in
    1:*|*:MINGW*|*:MSYS*|*:CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

invoke_taskkill() {
  local pid=$1 taskkill_bin
  if [ -n "${MUSE_RESCUE_KILL:-}" ]; then
    MSYS_NO_PATHCONV=1 "$MUSE_RESCUE_KILL" /T /F /PID "$pid"
    return $?
  fi
  taskkill_bin=$(command -v taskkill) ||
    taskkill_bin=$(cygpath -u "${SYSTEMROOT:-${WINDIR:-C:/Windows}}/System32/taskkill.exe") || return 1
  "$taskkill_bin" //T //F //PID "$pid"
}

cleanup_orphans() {
  is_windows || return 0
  local ps_bin=${MUSE_RESCUE_PS:-powershell.exe} processes ids pid count=0
  processes=$("$ps_bin" -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,CommandLine | ConvertTo-Json -Compress') || return 1
  ids=$(printf '%s' "$processes" | node -e '
    let input = "";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      // Windows PowerShell 5.1 ConvertTo-Json leaves some control characters in CommandLine unescaped
      const text = input.replace(/^\uFEFF/, "").replace(/[\u0000-\u001F]/g, " ");
      let parsed;
      try {
        parsed = JSON.parse(text || "[]");
      } catch (error) {
        console.error("[muse-rescue] WARNING: could not read the process list; orphan cleanup skipped (" + error.message + ")");
        return;
      }
      const rows = Array.isArray(parsed) ? parsed : [parsed];
      const alive = new Set(rows.map(row => Number(row.ProcessId)));
      for (const row of rows) {
        if (String(row.CommandLine || "").includes("__tbh_internal_windows_sandbox_read_worker") &&
            !alive.has(Number(row.ParentProcessId)) && Number(row.ProcessId) > 0) {
          console.log(Number(row.ProcessId));
        }
      }
    });
  ') || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    invoke_taskkill "$pid" >/dev/null 2>&1 || return 1
    count=$((count + 1))
  done <<<"$ids"
  [ "$count" -eq 0 ] || printf '[muse-rescue] killed %s orphan Muse sandbox worker(s) left by an interrupted run\n' "$count"
  return 0
}

positive_seconds() {
  [[ $2 =~ ^[0-9]{1,8}$ ]] || usage_error "$1 needs positive integer seconds"
  [ "$((10#$2))" -gt 0 ] || usage_error "$1 needs positive integer seconds"
}

read_task() {
  local task
  task=$(cat)
  [ -n "${task//[[:space:]]/}" ] || usage_error "no task on stdin"
  printf '%s' "$task"
}

prepare_run() {
  require_node || return $?
  require_launcher || return $?
  if ! auth_present; then
    printf '[muse-rescue] no Muse credentials — run "muse login" once in a normal terminal, then /muse:setup\n' >&2
    return "$PREFLIGHT_FAILED_EXIT"
  fi
  check_windows_sandbox || return $?
}

warn_appdata_workspace() {
  [ -n "${USERPROFILE:-}" ] || return 0
  local folded_workspace folded_profile
  folded_workspace=$(native_path "$PWD" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
  folded_profile=$(printf '%s' "$USERPROFILE" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
  if [[ $folded_workspace == "$folded_profile"/appdata || $folded_workspace == "$folded_profile"/appdata/* ]]; then
    printf "[muse-rescue] WARNING: workspace is under your profile's AppData — Muse's sandboxed shell hangs there; use a repo outside your profile\n" >&2
  fi
}

append_safe_directory() {
  local count=${GIT_CONFIG_COUNT:-0} workspace
  [[ $count =~ ^[0-9]{1,8}$ ]] || usage_error "GIT_CONFIG_COUNT must be a non-negative integer"
  count=$((10#$count))
  workspace=$(native_path "$PWD" | tr '\\' '/')
  export "GIT_CONFIG_KEY_$count=safe.directory" "GIT_CONFIG_VALUE_$count=$workspace"
  export GIT_CONFIG_COUNT=$((count + 1))
}

muse_env() {
  export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes'
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
  append_safe_directory
}

write_prompt() {
  local constraints=$CONSTRAINTS
  [ "$OPT_READ_ONLY" -eq 1 ] && constraints=$READ_ONLY_CONSTRAINTS
  printf '%s\n\n%s' "$2" "$constraints" >"$1"
}

muse_args() {
  printf '%s\0' exec --json --prompt-file "$(native_path "$1")" --workspace "$(native_path "$PWD")" \
    --approval-mode never --approval-judge off --no-foreign-personal-context \
    --user-input-auto-resolve --max-model-steps "$OPT_STEPS"
  [ -n "$OPT_MODEL" ] && printf '%s\0' --model "$OPT_MODEL"
  [ -n "$OPT_REASONING" ] && printf '%s\0' --reasoning-effort "$OPT_REASONING"
  [ "$OPT_READ_ONLY" -eq 1 ] && printf '%s\0' --disable-write --disable-shell
  return 0
}

windows_pid() {
  ps -p "$1" -l 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "WINPID") column = i; next } column { print $column; exit }'
}

kill_descendants() {
  local pid=$1 child children
  children=$(ps -e -o pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  for child in $children; do kill_descendants "$child"; done
  kill -KILL "$pid" 2>/dev/null || :
}

kill_windows_tree() {
  local pid=$1 children child native_pid
  children=$(ps -e | awk -v parent="$pid" 'NR > 1 && $2 == parent { print $1 }')
  # MSYS fork children can have native parents outside taskkill's tree.
  for child in $children; do kill_windows_tree "$child" || return 1; done
  native_pid=$(windows_pid "$pid")
  if [ -z "$native_pid" ] && [ -n "${MUSE_RESCUE_KILL:-}" ]; then native_pid=$pid; fi
  [ -n "$native_pid" ] || return 0
  if ! invoke_taskkill "$native_pid" >/dev/null 2>&1; then
    kill -0 "$pid" 2>/dev/null && return 1
  fi
  return 0
}

kill_tree() {
  if is_windows; then kill_windows_tree "$1"; else kill_descendants "$1"; fi
}

print_stderr() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && printf '%s\n' "$line"
  done <"$1"
  return 0
}

meta_field() {
  node -e 'try {
    const meta = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(meta[process.argv[2]] || process.argv[3]));
  } catch (_) { process.stdout.write(process.argv[3]); }' "$1" "$2" "$3"
}

write_summary() {
  local meta=$1 rc=$2 elapsed=$3 status=error
  [ "$rc" -eq 0 ] && [ "$(meta_field "$meta" failed 0)" = 0 ] && status=done
  printf '[muse-rescue] %s in %ss, session %s, model %s\n' "$status" "$elapsed" \
    "$(meta_field "$meta" sessionId unknown)" "$(meta_field "$meta" modelId default)"
}

run_task() {
  local task args=() item pid filter_pid rc start end deadline seconds=${MUSE_RESCUE_TIMEOUT:-540}
  task=$(read_task) || return $?
  positive_seconds MUSE_RESCUE_TIMEOUT "$seconds"
  prepare_run || return $?
  RUN_PROMPT_FILE=$(mktemp) || return 1
  RUN_STDERR_FILE=$(mktemp) || return 1
  RUN_META_FILE=$(mktemp) || return 1
  RUN_TASK_FILE=$(mktemp) || return 1
  trap 'rm -f "$RUN_TASK_FILE" "$RUN_PROMPT_FILE" "$RUN_STDERR_FILE" "$RUN_META_FILE"' EXIT
  write_prompt "$RUN_PROMPT_FILE" "$task"
  warn_appdata_workspace
  local before
  before=$(git_state 2>/dev/null || :)
  while IFS= read -r -d '' item; do args+=("$item"); done < <(muse_args "$RUN_PROMPT_FILE")
  start=$(date +%s)
  deadline=$((start + 10#$seconds))
  export MUSE_RESCUE_META_FILE=$(native_path "$RUN_META_FILE")
  exec 3> >(node "$SCRIPT_DIR/stream-filter.js")
  filter_pid=$!
  ( muse_env; exec "$MUSE_LAUNCHER" "${args[@]}" </dev/null >&3 2>"$RUN_STDERR_FILE" ) &
  pid=$!
  exec 3>&-
  rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill_tree "$pid" || return 1
      rc=124
      break
    fi
    sleep 0.1
  done
  if [ "$rc" -eq 0 ]; then wait "$pid"; rc=$?; else wait "$pid" 2>/dev/null || :; fi
  wait "$filter_pid" || return 1
  end=$(date +%s)
  print_stderr "$RUN_STDERR_FILE"
  [ "$rc" -ne 124 ] || printf '[muse-rescue] timed out after %ss — edits made until then are in the working tree\n' "$((10#$seconds))"
  write_summary "$RUN_META_FILE" "$rc" "$((end - start))"
  warn_git_changes "$before"
  printf '[muse-rescue] exit %s\n' "$rc"
  return "$rc"
}

job_path() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "unknown job: $1"
  [ -d "$RESCUE_HOME/jobs/$1" ] || usage_error "unknown job: $1"
  printf '%s/jobs/%s' "$RESCUE_HOME" "$1"
}

write_job_argv() {
  { printf '%s\0' "$MUSE_LAUNCHER"; muse_args "$1/prompt"; } >"$1/argv"
  command -v node >"$1/node-bin"
}

detach_job() {
  local job=$1 pid
  ( muse_env; nohup bash "$SCRIPT_DIR/muse-forward.sh" __job "$job" </dev/null >"$job/wrapper-log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" >"$job/pid"
    disown "$pid"
  )
}

run_job_wrapper() {
  local job=$1 argv=() item pid rc
  while IFS= read -r -d '' item; do argv+=("$item"); done <"$job/argv"
  "${argv[@]}" </dev/null >"$job/stdout" 2>"$job/stderr" &
  pid=$!
  printf '%s\n' "$pid" >"$job/cli-pid"
  wait "$pid"
  rc=$?
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit.tmp"
  mv "$job/exit.tmp" "$job/exit"
  return "$rc"
}

start_task() {
  local task max_seconds=${MUSE_RESCUE_MAX_SECONDS:-2700} job id started
  task=$(read_task) || return $?
  positive_seconds MUSE_RESCUE_MAX_SECONDS "$max_seconds"
  prepare_run || return $?
  mkdir -p "$RESCUE_HOME/jobs" || return 1
  id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  job="$RESCUE_HOME/jobs/$id"
  mkdir "$job" || return 1
  started=$(date +%s)
  printf '%s\n' "$(native_path "$PWD")" >"$job/workspace"
  printf '%s\n' "$started" >"$job/started"
  printf '%s\n' "$((started + 10#$max_seconds))" >"$job/deadline"
  printf '0\n' >"$job/offset"
  : >"$job/stdout"
  : >"$job/stderr"
  git_state >"$job/git-before" 2>/dev/null || :
  printf '%s' "$task" >"$job/task"
  write_prompt "$job/prompt" "$task"
  write_job_argv "$job" || return 1
  warn_appdata_workspace
  detach_job "$job" || return 1
  printf '[muse-rescue] started job %s\n' "$id"
}

job_filter() {
  local job=$1 node_bin
  shift
  node_bin=$(cat "$job/node-bin")
  "$node_bin" "$SCRIPT_DIR/stream-filter.js" "$@"
}

print_job_progress() {
  local job=$1 final=${2:-} statuses=()
  export MUSE_RESCUE_META_FILE=$(native_path "$job/meta")
  export MUSE_RESCUE_STATE_FILE=$(native_path "$job/filter-state")
  export MUSE_RESCUE_OFFSET_FILE=$(native_path "$job/offset")
  job_filter "$job" --read-slice "$(native_path "$job/stdout")" "$(native_path "$job/offset")" "$final" | job_filter "$job"
  statuses=("${PIPESTATUS[@]}")
  [ "${statuses[0]}" -eq 0 ] && [ "${statuses[1]}" -eq 0 ]
}

mark_job_stopped() {
  local job=$1 rc=$2 pid
  pid=$(cat "$job/pid")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill_tree "$pid" || return 1
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit"
  [ "$rc" != 124 ] || printf 'timeout\n' >"$job/stopped"
}

write_job_summary() {
  local job=$1 rc=$2 elapsed=$3
  write_summary "$job/meta" "$rc" "$elapsed" >"$job/summary"
  if [ -f "$job/stopped" ]; then
    printf '[muse-rescue] timed out after %ss — edits made until then are in the working tree\n' \
      "$(($(cat "$job/deadline") - $(cat "$job/started")))" >>"$job/summary"
  fi
}

finish_job_workspace() {
  local job=$1 workspace
  workspace=$(cat "$job/workspace")
  cd "$workspace" || {
    printf '[muse-rescue] WARNING: job workspace is no longer readable — review before your next git command\n'
    return 0
  }
  warn_git_changes "$(cat "$job/git-before")"
}

clean_job() {
  local job=$1
  rm -f "$job/task" "$job/prompt" "$job/argv" "$job/stdout" "$job/stderr" "$job/meta" \
    "$job/filter-state" "$job/filter-state.tmp" "$job/offset" "$job/offset.pending" \
    "$job/git-before" "$job/node-bin" "$job/wrapper-log" "$job/exit.tmp"
}

finish_job() {
  local job=$1 rc elapsed
  rc=$(cat "$job/exit")
  if [ -f "$job/finished" ]; then cat "$job/summary"; return "$rc"; fi
  print_job_progress "$job" final || return 1
  elapsed=$(($(cat "$job/ended") - $(cat "$job/started")))
  print_stderr "$job/stderr"
  write_job_summary "$job" "$rc" "$elapsed"
  cat "$job/summary"
  ( finish_job_workspace "$job" )
  printf '[muse-rescue] exit %s\n' "$rc" | tee -a "$job/summary"
  clean_job "$job"
  : >"$job/finished"
  return "$rc"
}

parse_slice() {
  [ $# -eq 0 ] && { printf '480'; return 0; }
  [ $# -eq 2 ] && [ "$1" = --slice ] || usage_error "usage: muse-forward.sh wait <id> [--slice <seconds>]"
  positive_seconds --slice "$2"
  [ "$((10#$2))" -le 540 ] || usage_error "--slice must be at most 540 seconds"
  printf '%s' "$((10#$2))"
}

wait_job() {
  local id=${1:-} job slice slice_end deadline now elapsed
  [ $# -gt 0 ] || usage_error "wait needs a job id"
  shift
  job=$(job_path "$id") || return "$USAGE_EXIT"
  slice=$(parse_slice "$@") || return "$USAGE_EXIT"
  slice_end=$(($(date +%s) + slice))
  deadline=$(cat "$job/deadline")
  while :; do
    [ -f "$job/exit" ] && { finish_job "$job"; return $?; }
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      mark_job_stopped "$job" 124 || return 1
      finish_job "$job"
      return $?
    fi
    print_job_progress "$job" || return 1
    if [ "$now" -ge "$slice_end" ]; then
      elapsed=$((now - $(cat "$job/started")))
      printf '[muse-rescue] job %s still running (%ss) — call wait again\n' "$id" "$elapsed"
      return 75
    fi
    sleep 1
  done
}

cancel_job() {
  local job
  [ $# -eq 1 ] || usage_error "cancel needs a job id"
  job=$(job_path "$1") || return "$USAGE_EXIT"
  [ -f "$job/exit" ] || mark_job_stopped "$job" 130 || return 1
  finish_job "$job"
}

main() {
  local command=${1:-}
  [ $# -gt 0 ] && shift
  case $command in
    preflight) parse_options "$@"; preflight ;;
    run) parse_options "$@"; run_task ;;
    start) parse_options "$@"; start_task ;;
    wait) wait_job "$@" ;;
    cancel) cancel_job "$@" ;;
    __job) run_job_wrapper "$@" ;;
    *) usage_error "usage: muse-forward.sh preflight|run|start|wait|cancel [options]" ;;
  esac
}

main "$@"
