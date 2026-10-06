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
  local uname_s status output
  uname_s=$(uname -s 2>/dev/null || :)
  case "${MUSE_RESCUE_FORCE_WINDOWS:-0}:$uname_s" in
    1:*|*:MINGW*|*:MSYS*|*:CYGWIN*) ;;
    *) return 0 ;;
  esac
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

run_task() {
  local workspace_native before start end rc constraints timeout_bin line session model task
  local -a args
  RUN_TASK_FILE=$(mktemp) || return 1
  RUN_PROMPT_FILE=$(mktemp) || { rm -f "$RUN_TASK_FILE"; return 1; }
  RUN_STDERR_FILE=$(mktemp) || { rm -f "$RUN_TASK_FILE" "$RUN_PROMPT_FILE"; return 1; }
  RUN_META_FILE=$(mktemp) || { rm -f "$RUN_TASK_FILE" "$RUN_PROMPT_FILE" "$RUN_STDERR_FILE"; return 1; }
  trap 'rm -f "$RUN_TASK_FILE" "$RUN_PROMPT_FILE" "$RUN_STDERR_FILE" "$RUN_META_FILE"' EXIT
  cat >"$RUN_TASK_FILE"
  if ! grep -q '[^[:space:]]' "$RUN_TASK_FILE"; then
    usage_error "no task on stdin"
  fi
  task=$(cat "$RUN_TASK_FILE")
  require_node || return $?
  require_launcher || return $?
  if ! auth_present; then
    printf '[muse-rescue] no Muse credentials — run "muse login" once in a normal terminal, then /muse:setup\n' >&2
    return "$PREFLIGHT_FAILED_EXIT"
  fi
  check_windows_sandbox || return $?

  constraints=$CONSTRAINTS
  [ "$OPT_READ_ONLY" -eq 1 ] && constraints=$READ_ONLY_CONSTRAINTS
  printf '%s\n\n%s' "$task" "$constraints" >"$RUN_PROMPT_FILE"

  workspace_native=$(native_path "$PWD")
  if [ -n "${USERPROFILE:-}" ]; then
    local folded_workspace folded_profile
    folded_workspace=$(printf '%s' "$workspace_native" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
    folded_profile=$(printf '%s' "$USERPROFILE" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
    if [[ $folded_workspace == "$folded_profile"/appdata || $folded_workspace == "$folded_profile"/appdata/* ]]; then
      printf '[muse-rescue] WARNING: workspace is under your profile'\''s AppData — Muse'\''s sandboxed shell hangs there; use a repo outside your profile\n' >&2
    fi
  fi

  before=$(git_state 2>/dev/null || :)
  export MUSE_RESCUE_META_FILE=$(native_path "$RUN_META_FILE")
  args=(exec --json --prompt-file "$(native_path "$RUN_PROMPT_FILE")" --workspace "$workspace_native"
    --approval-mode never --approval-judge off --no-foreign-personal-context
    --user-input-auto-resolve --max-model-steps "$OPT_STEPS")
  [ -n "$OPT_MODEL" ] && args+=(--model "$OPT_MODEL")
  [ -n "$OPT_REASONING" ] && args+=(--reasoning-effort "$OPT_REASONING")
  [ "$OPT_READ_ONLY" -eq 1 ] && args+=(--disable-write --disable-shell)
  timeout_bin=$(command -v timeout 2>/dev/null || :)
  if [ -z "$timeout_bin" ]; then
    printf '[muse-rescue] timeout is required on PATH to enforce the 9-minute cap\n' >&2
    return "$NOT_FOUND_EXIT"
  fi
  start=$(date +%s)
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND='ssh -o BatchMode=yes'
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
  "$timeout_bin" "${MUSE_RESCUE_TIMEOUT:-540}" "$MUSE_LAUNCHER" "${args[@]}" </dev/null 2>"$RUN_STDERR_FILE" |
    node "$SCRIPT_DIR/stream-filter.js"
  rc=${PIPESTATUS[0]}
  end=$(date +%s)
  while IFS= read -r line; do [ -n "$line" ] && printf '%s\n' "$line"; done <"$RUN_STDERR_FILE"
  session=$(node -e 'try { process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).sessionId || "unknown"); } catch (_) { process.stdout.write("unknown"); }' "$RUN_META_FILE")
  model=$(node -e 'try { process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).modelId || "default"); } catch (_) { process.stdout.write("default"); }' "$RUN_META_FILE")
  local json_failed
  json_failed=$(node -e 'try { process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).failed ? "1" : "0"); } catch (_) { process.stdout.write("0"); }' "$RUN_META_FILE")
  if [ "$rc" -eq 0 ] && [ "$json_failed" = 0 ]; then
    printf '[muse-rescue] done in %ss, session %s, model %s\n' "$((end - start))" "$session" "$model"
  else
    case $rc in
      124|137|142) printf '[muse-rescue] timed out after %ss — edits made until then are in the working tree\n' "${MUSE_RESCUE_TIMEOUT:-540}" ;;
    esac
    printf '[muse-rescue] error in %ss, session %s, model %s\n' "$((end - start))" "$session" "$model"
  fi
  warn_git_changes "$before"
  printf '[muse-rescue] exit %s\n' "$rc"
  return "$rc"
}

main() {
  local command=${1:-}
  [ $# -gt 0 ] && shift
  case $command in
    preflight) parse_options "$@"; preflight ;;
    run) parse_options "$@"; run_task ;;
    *) usage_error "usage: muse-forward.sh preflight|run [options]" ;;
  esac
}

main "$@"
