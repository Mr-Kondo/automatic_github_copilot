#!/bin/zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

# =========================================================
# Copilot implementation-review auto loop with auto-commit
# - implementer: Claude Sonnet
# - reviewer: GPT-5.4
# - repeats until PASS with zero issues
# - auto-commits only after PASS
#
# Design notes:
# - Prompts passed to copilot are intentionally short.
# - Large data (task details, review JSON, diff logs, check logs) are read via file paths.
# - *_CMD values are restricted to simple argv-style commands.
#   Shell composition (pipes, redirects, command substitution, env expansion) is intentionally rejected.
# =========================================================

: "${MAX_ITERS:=5}"
: "${LOG_DIR:=.copilot-loop-logs}"
: "${AUTO_COMMIT:=1}"
: "${INCLUDE_TASK_FILE_IN_COMMIT:=0}"
: "${TASK_FILE:=task.md}"
: "${IMPLEMENTER_AGENT:=implementer}"
: "${REVIEWER_AGENT:=reviewer}"
: "${COMMIT_MESSAGE:=}"
: "${UNTRACKED_DIFF_MAX_BYTES:=524288}"  # 512 KiB

: "${TEST_CMD:=}"
: "${LINT_CMD:=}"
: "${TYPECHECK_CMD:=}"
: "${EXTRA_IMPL_INSTR:=}"
: "${ENABLE_LOG_CONTEXT:=1}"
: "${APP_LOG_DIR:=log}"
: "${APP_LOG_MAX_PROMPT_LINES:=120}"
: "${LOG_CONTEXT_FILE:=.copilot-loop-logs/context.md}"
: "${LOG_CONTEXT_MAX_BYTES:=262144}"   # 256 KiB
: "${LOG_CONTEXT_KEEP_GENERATIONS:=3}"

usage() {
  cat <<'EOF'
Usage:
  ./copilot-review-loop.zsh [options]

Options:
  -t, --task-file FILE            Task description file (default: task.md)
  -n, --max-iters NUM             Max review loop iterations (default: 5)
  --test-cmd CMD                  Test command (simple argv-style only)
  --lint-cmd CMD                  Lint command (simple argv-style only)
  --typecheck-cmd CMD             Typecheck command (simple argv-style only)
  --log-dir DIR                   Log directory (default: .copilot-loop-logs)
  --app-log-dir DIR               Application log directory to read latest from (default: log)
  --app-log-max-lines NUM         Max lines from latest app log to include in prompt (default: 120)
  --log-context-file FILE         Managed markdown context log path (default: .copilot-loop-logs/context.md)
  --log-context-max-bytes NUM     Rotate managed context log when exceeded (default: 262144)
  --log-context-keep NUM          Number of rotated generations to keep (default: 3)
  --no-log-context                Disable app log context injection
  --implementer-agent NAME        Custom agent name for implementation
  --reviewer-agent NAME           Custom agent name for review
  --commit-message MSG            Commit message after PASS
  --no-auto-commit                Do not auto-commit even if PASS
  --include-task-file             Include task file in commit
  -h, --help                      Show help

Command parsing policy:
- Supported:
    --message "hello world"
    pytest -q
    pnpm test -- --runInBand
- Rejected intentionally:
    echo hi | sed ...
    FOO=bar pytest
    python -c "..."
    cmd > out.txt
    $(subcommand)
    $HOME/bin/tool
- If you need shell composition, wrap it in a script file and call that script.
EOF
}

log() { print -r -- "[INFO] $*"; }
warn() { print -r -- "[WARN] $*" >&2; }
err() { print -r -- "[ERROR] $*" >&2; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "Required command not found: $cmd"
    exit 1
  }
}

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

run_cmd_string() {
  local label="$1"
  local cmd_str="$2"
  local -a argv

  if [[ -z "$cmd_str" ]]; then
    return 0
  fi

  if [[ "$cmd_str" == *$'\n'* ||
        "$cmd_str" == *"|"* ||
        "$cmd_str" == *";"* ||
        "$cmd_str" == *"&"* ||
        "$cmd_str" == *">"* ||
        "$cmd_str" == *"<"* ||
        "$cmd_str" == *'$'* ||
        "$cmd_str" == *'`'* ]]; then
    err "${label}: unsupported shell syntax in *_CMD value."
    err "${label}: use a wrapper script if you need pipes, redirects, env expansion, or command substitution."
    return 90
  fi

  argv=(${(z)cmd_str})

  if (( ${#argv} == 0 )); then
    return 0
  fi

  {
    print -- "===== ${label} ====="
    print -- "\$ ${cmd_str}"
    "${argv[@]}"
    print
  }
}

git_diff_file() {
  local out="$1"
  local raw_untracked=""
  local -a candidate_untracked
  local -a untracked_files
  local file_path
  local fsize
  local log_dir_filter_local="$LOG_DIR_FILTER"

  raw_untracked="$(git ls-files --others --exclude-standard || true)"

  if [[ -n "$raw_untracked" ]]; then
    candidate_untracked=("${(@f)raw_untracked}")
  else
    candidate_untracked=()
  fi

  untracked_files=()
  for file_path in "${candidate_untracked[@]}"; do
    if [[ -n "$log_dir_filter_local" ]]; then
      if [[ "$file_path" == "$log_dir_filter_local" || "$file_path" == "$log_dir_filter_local/"* ]]; then
        continue
      fi
    fi
    untracked_files+=("$file_path")
  done

  {
    print -- "### git branch --show-current"
    git branch --show-current || true
    print

    print -- "### git status --short"
    git status --short || true
    print

    print -- "### git diff --stat (tracked unstaged)"
    git diff --stat || true
    print

    print -- "### git diff (tracked unstaged)"
    git diff || true
    print

    print -- "### git diff --cached (staged)"
    git diff --cached || true
    print

    print -- "### untracked files (LOG_DIR excluded)"
    if (( ${#untracked_files[@]} > 0 )); then
      printf '%s\n' "${untracked_files[@]}"
    else
      print -- "(none)"
    fi
    print

    print -- "### git diff for untracked files"
    if (( ${#untracked_files[@]} > 0 )); then
      for file_path in "${untracked_files[@]}"; do
        if [[ -f "$file_path" ]]; then
          fsize="$(wc -c < "$file_path" 2>/dev/null | tr -d '[:space:]' || true)"
          [[ -z "$fsize" ]] && fsize=0
          if [[ "$fsize" == <-> ]] && (( fsize > UNTRACKED_DIFF_MAX_BYTES )); then
            print -- "--- $file_path (skipped: file too large, ${fsize} bytes)"
            print
            continue
          fi
        fi

        print -- "--- $file_path"
        git diff --no-index -- /dev/null "$file_path" || true
        print
      done
    else
      print -- "(none)"
    fi
  } > "$out"
}

run_project_checks() {
  local out_file="$1"
  : > "$out_file"

  local had_any=0

  if [[ -n "${LINT_CMD}" ]]; then
    had_any=1
    run_cmd_string "LINT" "$LINT_CMD" >> "$out_file" 2>&1 || return 10
  fi

  if [[ -n "${TYPECHECK_CMD}" ]]; then
    had_any=1
    run_cmd_string "TYPECHECK" "$TYPECHECK_CMD" >> "$out_file" 2>&1 || return 11
  fi

  if [[ -n "${TEST_CMD}" ]]; then
    had_any=1
    run_cmd_string "TEST" "$TEST_CMD" >> "$out_file" 2>&1 || return 12
  fi

  if [[ "$had_any" -eq 0 ]]; then
    {
      print -- "No project checks configured."
      print -- "Set one or more of:"
      print -- "  TEST_CMD"
      print -- "  LINT_CMD"
      print -- "  TYPECHECK_CMD"
    } >> "$out_file"
  fi

  return 0
}

validate_review_json() {
  local review_file="$1"
  jq -e '
    type == "object" and
    (.status == "PASS" or .status == "FAIL") and
    (.issues | type == "array") and
    (
      .issues[]? |
      type == "object" and
      (.severity | type == "string") and
      (.severity | length > 0) and
      (.file | type == "string") and
      ((.line == null) or (.line | type == "number")) and
      (.title | type == "string") and
      (.detail | type == "string") and
      (.suggested_fix | type == "string")
    )
  ' "$review_file" >/dev/null
}

summarize_review() {
  local review_file="$1"
  local status issue_count
  status="$(jq -r '.status' "$review_file")"
  issue_count="$(jq -r '.issues | length' "$review_file")"

  print -- "status=${status}, issues=${issue_count}"

  if [[ "$issue_count" -gt 0 ]]; then
    jq -r '.issues[] | "- [\(.severity // "UNKNOWN")] \(.file):\(.line // 0) \(.title)"' "$review_file"
  fi
}

find_latest_app_log() {
  local log_dir="$1"
  local latest_file=""
  local latest_mtime=-1
  local -a candidates
  local candidate
  local mtime

  if [[ ! -d "$log_dir" ]]; then
    return 0
  fi

  candidates=("$log_dir"/*(.N))
  if (( ${#candidates[@]} == 0 )); then
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || true)"
    if [[ "$mtime" == <-> ]] && (( mtime > latest_mtime )); then
      latest_mtime="$mtime"
      latest_file="$candidate"
    fi
  done

  if [[ -n "$latest_file" ]]; then
    print -r -- "$latest_file"
  fi
}

rotate_managed_context_log() {
  local context_file="$1"
  local max_bytes="$2"
  local keep_generations="$3"
  local current_size
  local idx
  local src
  local dst
  local context_dir="${context_file:h}"

  mkdir -p "$context_dir"

  if [[ ! -f "$context_file" ]]; then
    return 0
  fi

  current_size="$(wc -c < "$context_file" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -z "$current_size" ]] && current_size=0

  if ! [[ "$current_size" == <-> ]]; then
    return 0
  fi

  if (( current_size <= max_bytes )); then
    return 0
  fi

  if (( keep_generations <= 0 )); then
    : > "$context_file"
    return 0
  fi

  for (( idx = keep_generations; idx >= 1; idx-- )); do
    dst="$context_file.$idx"
    if (( idx == keep_generations )) && [[ -f "$dst" ]]; then
      rm -f -- "$dst"
    fi

    if (( idx == 1 )); then
      src="$context_file"
    else
      src="$context_file.$((idx - 1))"
    fi

    if [[ -f "$src" ]]; then
      mv -f -- "$src" "$dst"
    fi
  done

  : > "$context_file"
}

append_managed_context_log() {
  local context_file="$1"
  local app_log_file="$2"
  local status="$3"
  local issue_count="$4"
  local review_json_file="$5"

  rotate_managed_context_log "$context_file" "$LOG_CONTEXT_MAX_BYTES" "$LOG_CONTEXT_KEEP_GENERATIONS"

  {
    print -- "## $(timestamp)"
    print -- "status: ${status}, issues: ${issue_count}"
    if [[ -n "$app_log_file" ]]; then
      print -- "latest_app_log: ${app_log_file}"
    else
      print -- "latest_app_log: (none)"
    fi

    if [[ -f "$review_json_file" ]]; then
      print -- ""
      print -- "### reviewer_findings"
      jq -r '.issues[]? | "- [\(.severity // \"UNKNOWN\")] \(.file):\(.line // 0) \(.title)"' "$review_json_file" || true
    fi
    print -- ""
  } >> "$context_file"
}

build_log_context_section() {
  local app_log_file="$1"
  local context_file="$2"
  local has_any=0

  if [[ -n "$app_log_file" && -f "$app_log_file" ]]; then
    has_any=1
  fi
  if [[ -n "$context_file" && -f "$context_file" ]]; then
    has_any=1
  fi

  if [[ "$has_any" -ne 1 ]]; then
    return 0
  fi

  print -- ""
  print -- "Additional context files:"
  if [[ -n "$app_log_file" && -f "$app_log_file" ]]; then
    print -- "- Latest app run log: ${app_log_file}"
  fi
  if [[ -n "$context_file" && -f "$context_file" ]]; then
    print -- "- Managed implementation context log: ${context_file}"
  fi
}

build_impl_prompt_initial() {
  local task_file="$1"
  local app_log_file="$2"
  local context_file="$3"
  local log_context_section=""

  if [[ "$ENABLE_LOG_CONTEXT" -eq 1 ]]; then
    log_context_section="$(build_log_context_section "$app_log_file" "$context_file")"
  fi

  cat <<EOF
Implement the task described in this repository file:
- ${task_file}
${log_context_section}

Instructions:
- Read ${task_file} directly from the repository before making changes.
- Read additional context files when available.
- Edit code directly in the working tree.
- Keep changes minimal and localized.
- Do not modify unrelated files.
- Run relevant project checks when appropriate.
- If a check fails, fix the issue before concluding.
- Summarize changed files, what was fixed, checks run, and remaining risks.

Additional instructions:
${EXTRA_IMPL_INSTR}
EOF
}

build_impl_prompt_revision() {
  local task_file="$1"
  local review_json_file="$2"
  local app_log_file="$3"
  local context_file="$4"
  local log_context_section=""

  if [[ "$ENABLE_LOG_CONTEXT" -eq 1 ]]; then
    log_context_section="$(build_log_context_section "$app_log_file" "$context_file")"
  fi

  cat <<EOF
Revise the implementation using these sources:
- Task file: ${task_file}
- Review findings JSON: ${review_json_file}
${log_context_section}

Instructions:
- Read both files directly before making changes.
- Read additional context files when available.
- Fix every material issue from the review findings.
- Keep changes minimal and localized.
- Do not modify unrelated files.
- Re-run relevant project checks when appropriate.
- If a check fails, fix the issue before concluding.
- Summarize changed files, what was fixed, checks run, and remaining risks.

Additional instructions:
${EXTRA_IMPL_INSTR}
EOF
}

build_review_prompt() {
  local task_file="$1"
  local checks_file="$2"
  local diff_file="$3"
  cat <<EOF
Review the current repository state using these files:
- Task file: ${task_file}
- Latest project checks: ${checks_file}
- Prepared git diff log: ${diff_file}

Instructions:
- Return JSON only, exactly matching the reviewer schema.
- Produce one final verdict only.
- Do not use iterative continuation behavior.
- Read the provided files directly as needed.
- Focus on material correctness, safety, maintainability, and task compliance.
- Prefer concrete findings over style nits.
- If there are no material issues, return:
  {"status":"PASS","issues":[]}
EOF
}

sanitize_commit_subject() {
  local raw="$1"
  raw="$(print -r -- "$raw" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  raw="$(print -r -- "$raw" | sed 's/["`$\\]//g')"
  print -r -- "$raw"
}

default_commit_message_from_task() {
  local first_line
  first_line="$(grep -m 1 -v '^[[:space:]]*$' "$TASK_FILE" || true)"
  if [[ -z "$first_line" ]]; then
    first_line="Implement task via Copilot review loop"
  fi
  first_line="$(sanitize_commit_subject "$first_line")"
  first_line="${first_line[1,72]}"
  print -r -- "feat: ${first_line}"
}

stage_files_for_commit() {
  git add -A

  if [[ -e "$LOG_DIR" ]]; then
    git reset -q HEAD -- "$LOG_DIR" 2>/dev/null || true
  fi

  if [[ -e "$LOG_CONTEXT_FILE" ]]; then
    git reset -q HEAD -- "$LOG_CONTEXT_FILE" 2>/dev/null || true
  fi

  git reset -q HEAD -- ":(glob)$LOG_CONTEXT_FILE.*" 2>/dev/null || true

  if [[ "$INCLUDE_TASK_FILE_IN_COMMIT" -ne 1 && -e "$TASK_FILE" ]]; then
    git reset -q HEAD -- "$TASK_FILE" 2>/dev/null || true
  fi
}

has_staged_changes() {
  ! git diff --cached --quiet --exit-code
}

show_commit_summary() {
  print -- "### staged diff --stat"
  git diff --cached --stat || true
  print
  print -- "### staged files"
  git diff --cached --name-only || true
}

perform_auto_commit() {
  local commit_msg="$1"

  if ! has_staged_changes; then
    warn "No staged changes to commit after exclusions."
    return 20
  fi

  log "Committing changes..."
  git commit -m "$commit_msg"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--task-file)
      TASK_FILE="$2"
      shift 2
      ;;
    -n|--max-iters)
      MAX_ITERS="$2"
      shift 2
      ;;
    --test-cmd)
      TEST_CMD="$2"
      shift 2
      ;;
    --lint-cmd)
      LINT_CMD="$2"
      shift 2
      ;;
    --typecheck-cmd)
      TYPECHECK_CMD="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --app-log-dir)
      APP_LOG_DIR="$2"
      shift 2
      ;;
    --app-log-max-lines)
      APP_LOG_MAX_PROMPT_LINES="$2"
      shift 2
      ;;
    --log-context-file)
      LOG_CONTEXT_FILE="$2"
      shift 2
      ;;
    --log-context-max-bytes)
      LOG_CONTEXT_MAX_BYTES="$2"
      shift 2
      ;;
    --log-context-keep)
      LOG_CONTEXT_KEEP_GENERATIONS="$2"
      shift 2
      ;;
    --no-log-context)
      ENABLE_LOG_CONTEXT=0
      shift 1
      ;;
    --implementer-agent)
      IMPLEMENTER_AGENT="$2"
      shift 2
      ;;
    --reviewer-agent)
      REVIEWER_AGENT="$2"
      shift 2
      ;;
    --commit-message)
      COMMIT_MESSAGE="$2"
      shift 2
      ;;
    --no-auto-commit)
      AUTO_COMMIT=0
      shift 1
      ;;
    --include-task-file)
      INCLUDE_TASK_FILE_IN_COMMIT=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

require_cmd git
require_cmd jq
require_cmd cp
require_cmd copilot
require_cmd python3
require_cmd sed
require_cmd tr
require_cmd grep
require_cmd date
require_cmd wc
require_cmd stat
require_cmd tail

if ! [[ "$MAX_ITERS" == <-> ]] || (( MAX_ITERS <= 0 )); then
  err "MAX_ITERS must be a positive integer, got: $MAX_ITERS"
  exit 1
fi

if ! [[ "$UNTRACKED_DIFF_MAX_BYTES" == <-> ]] || (( UNTRACKED_DIFF_MAX_BYTES < 0 )); then
  err "UNTRACKED_DIFF_MAX_BYTES must be a non-negative integer, got: $UNTRACKED_DIFF_MAX_BYTES"
  exit 1
fi

if ! [[ "$APP_LOG_MAX_PROMPT_LINES" == <-> ]] || (( APP_LOG_MAX_PROMPT_LINES <= 0 )); then
  err "APP_LOG_MAX_PROMPT_LINES must be a positive integer, got: $APP_LOG_MAX_PROMPT_LINES"
  exit 1
fi

if ! [[ "$LOG_CONTEXT_MAX_BYTES" == <-> ]] || (( LOG_CONTEXT_MAX_BYTES < 0 )); then
  err "LOG_CONTEXT_MAX_BYTES must be a non-negative integer, got: $LOG_CONTEXT_MAX_BYTES"
  exit 1
fi

if ! [[ "$LOG_CONTEXT_KEEP_GENERATIONS" == <-> ]] || (( LOG_CONTEXT_KEEP_GENERATIONS < 0 )); then
  err "LOG_CONTEXT_KEEP_GENERATIONS must be a non-negative integer, got: $LOG_CONTEXT_KEEP_GENERATIONS"
  exit 1
fi

if ! [[ "$ENABLE_LOG_CONTEXT" == <-> ]] || (( ENABLE_LOG_CONTEXT != 0 && ENABLE_LOG_CONTEXT != 1 )); then
  err "ENABLE_LOG_CONTEXT must be 0 or 1, got: $ENABLE_LOG_CONTEXT"
  exit 1
fi

LOG_DIR="${LOG_DIR%/}"
case "$LOG_DIR" in
  ./*)
    LOG_DIR_FILTER="${LOG_DIR#./}"
    ;;
  *)
    LOG_DIR_FILTER="$LOG_DIR"
    ;;
esac

if [[ "$LOG_CONTEXT_FILE" == ".copilot-loop-logs/context.md" && "$LOG_DIR" != ".copilot-loop-logs" ]]; then
  LOG_CONTEXT_FILE="$LOG_DIR/context.md"
fi

[[ -f "$TASK_FILE" ]] || {
  err "Task file not found: $TASK_FILE"
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  err "Current directory is not a git repository."
  exit 1
}

mkdir -p "$LOG_DIR"

if [[ -z "$COMMIT_MESSAGE" ]]; then
  COMMIT_MESSAGE="$(default_commit_message_from_task)"
fi

REVIEW_JSON=""
PASS_FLAG=0

log "Started at $(timestamp)"
log "Task file: $TASK_FILE"
log "Max iterations: $MAX_ITERS"
log "Log dir: $LOG_DIR"
log "Log dir filter: $LOG_DIR_FILTER"
log "Untracked diff size limit: $UNTRACKED_DIFF_MAX_BYTES bytes"
log "Log context enabled: $ENABLE_LOG_CONTEXT"
log "App log dir: $APP_LOG_DIR"
log "App log lines for prompt: $APP_LOG_MAX_PROMPT_LINES"
log "Managed context log file: $LOG_CONTEXT_FILE"
log "Managed context log rotate bytes: $LOG_CONTEXT_MAX_BYTES"
log "Managed context log generations: $LOG_CONTEXT_KEEP_GENERATIONS"
log "Implementer agent: $IMPLEMENTER_AGENT"
log "Reviewer agent: $REVIEWER_AGENT"
log "Auto commit: $AUTO_COMMIT"
log "Commit message: $COMMIT_MESSAGE"

integer iter
for (( iter = 1; iter <= MAX_ITERS; iter++ )); do
  log "============================================"
  log "Iteration $iter / $MAX_ITERS"

  ITER_DIR="$LOG_DIR/iter-$iter"
  mkdir -p "$ITER_DIR"

  IMPL_PROMPT_FILE="$ITER_DIR/impl_prompt.txt"
  IMPL_OUT_FILE="$ITER_DIR/impl_output.txt"
  CHECKS_FILE="$ITER_DIR/checks.txt"
  DIFF_FILE="$ITER_DIR/diff.txt"
  REVIEW_PROMPT_FILE="$ITER_DIR/review_prompt.txt"
  REVIEW_RAW_FILE="$ITER_DIR/review_raw.txt"
  REVIEW_JSON_FILE="$ITER_DIR/review.json"

  local_impl_prompt=""
  local_review_prompt=""
  latest_app_log_file=""
  latest_app_log_for_prompt=""

  if [[ "$ENABLE_LOG_CONTEXT" -eq 1 ]]; then
    latest_app_log_file="$(find_latest_app_log "$APP_LOG_DIR")"
    if [[ -n "$latest_app_log_file" ]]; then
      latest_app_log_for_prompt="$ITER_DIR/latest_app_log_snippet.txt"
      {
        print -- "# source: ${latest_app_log_file}"
        print -- "# captured_at: $(timestamp)"
        print -- ""
        tail -n "$APP_LOG_MAX_PROMPT_LINES" "$latest_app_log_file" || true
      } > "$latest_app_log_for_prompt"
    fi
  fi

  if [[ -z "$REVIEW_JSON" ]]; then
    local_impl_prompt="$(build_impl_prompt_initial "$TASK_FILE" "$latest_app_log_for_prompt" "$LOG_CONTEXT_FILE")"
  else
    print -r -- "$REVIEW_JSON" > "$REVIEW_JSON_FILE"
    local_impl_prompt="$(build_impl_prompt_revision "$TASK_FILE" "$REVIEW_JSON_FILE" "$latest_app_log_for_prompt" "$LOG_CONTEXT_FILE")"
  fi
  print -r -- "$local_impl_prompt" > "$IMPL_PROMPT_FILE"

  log "Running implementation agent..."
  {
    print -- "### IMPLEMENTER START $(timestamp)"
    copilot \
      --agent "$IMPLEMENTER_AGENT" \
      --autopilot \
      --no-ask-user \
      --allow-tool='write, shell(git:*), shell(cat:*), shell(pytest:*), shell(python:*), shell(uv:*), shell(poetry:*), shell(pip:*), shell(ruff:*), shell(mypy:*), shell(npm:*), shell(pnpm:*), shell(yarn:*), shell(bun:*), shell(go:*), shell(cargo:*), shell(mvn:*), shell(gradle:*), shell(make:*), shell(just:*)' \
      -p "$local_impl_prompt"
    print -- "### IMPLEMENTER END $(timestamp)"
  } > "$IMPL_OUT_FILE" 2>&1 || {
    err "Implementation agent failed in iteration $iter. See: $IMPL_OUT_FILE"
    exit 2
  }

  log "Running local project checks..."
  if run_project_checks "$CHECKS_FILE"; then
    log "Project checks completed."
  else
    warn "Some project checks failed. Review will still inspect current state."
  fi

  log "Capturing git diff..."
  git_diff_file "$DIFF_FILE"

  local_review_prompt="$(build_review_prompt "$TASK_FILE" "$CHECKS_FILE" "$DIFF_FILE")"
  print -r -- "$local_review_prompt" > "$REVIEW_PROMPT_FILE"

  log "Running reviewer agent..."
  {
    copilot \
      --agent "$REVIEWER_AGENT" \
      --no-ask-user \
      --allow-tool='shell(git:*), shell(cat:*), shell(pytest:*), shell(python:*), shell(uv:*), shell(poetry:*), shell(pip:*), shell(ruff:*), shell(mypy:*), shell(npm:*), shell(pnpm:*), shell(yarn:*), shell(bun:*), shell(go:*), shell(cargo:*), shell(mvn:*), shell(gradle:*), shell(make:*), shell(just:*)' \
      -s \
      -p "$local_review_prompt"
  } > "$REVIEW_RAW_FILE" 2>&1 || {
    err "Reviewer agent failed in iteration $iter. See: $REVIEW_RAW_FILE"
    exit 3
  }

  if jq -e . "$REVIEW_RAW_FILE" >/dev/null 2>&1; then
    cp "$REVIEW_RAW_FILE" "$REVIEW_JSON_FILE"
  else
    python3 - "$REVIEW_RAW_FILE" "$REVIEW_JSON_FILE" <<'PY' || {
import json, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, "r", encoding="utf-8", errors="ignore").read()

decoder = json.JSONDecoder()
best = None
best_end = -1
for i, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, end = decoder.raw_decode(text[i:])
        if end > best_end:
            best = obj
            best_end = end
    except Exception:
        pass

if best is None:
    raise SystemExit(1)

with open(dst, "w", encoding="utf-8") as f:
    json.dump(best, f, ensure_ascii=False, indent=2)
PY
      err "Failed to extract JSON object from reviewer output."
      err "  raw output: $REVIEW_RAW_FILE"
      exit 4
    }
  fi

  if ! validate_review_json "$REVIEW_JSON_FILE"; then
    err "Reviewer output is not valid schema JSON."
    err "  raw : $REVIEW_RAW_FILE"
    err "  json: $REVIEW_JSON_FILE"
    exit 4
  fi

  REVIEW_JSON="$(cat "$REVIEW_JSON_FILE")"

  log "Review summary:"
  summarize_review "$REVIEW_JSON_FILE"

  STATUS="$(jq -r '.status' "$REVIEW_JSON_FILE")"
  ISSUE_COUNT="$(jq -r '.issues | length' "$REVIEW_JSON_FILE")"

  if [[ "$ENABLE_LOG_CONTEXT" -eq 1 ]]; then
    append_managed_context_log "$LOG_CONTEXT_FILE" "$latest_app_log_file" "$STATUS" "$ISSUE_COUNT" "$REVIEW_JSON_FILE"
  fi

  if [[ "$STATUS" == "PASS" && "$ISSUE_COUNT" -eq 0 ]]; then
    PASS_FLAG=1
    log "Review passed with zero findings."
    break
  fi
done

log "============================================"

if [[ "$PASS_FLAG" -ne 1 ]]; then
  warn "Reached MAX_ITERS without PASS."
  warn "Inspect logs under: $LOG_DIR"
  exit 5
fi

if [[ "$AUTO_COMMIT" -eq 1 ]]; then
  log "Preparing auto-commit..."
  stage_files_for_commit

  if has_staged_changes; then
    show_commit_summary
    perform_auto_commit "$COMMIT_MESSAGE"
    log "Auto-commit completed."
    print -- ""
    print -- "Last commit:"
    git --no-pager log -1 --stat
    exit 0
  else
    warn "Auto-commit skipped because nothing remained to commit."
    exit 0
  fi
else
  log "PASS reached. Auto-commit disabled."
  print -- ""
  print -- "Next suggested commands:"
  print -- "  git add -A"
  print -- "  git commit -m \"$COMMIT_MESSAGE\""
  exit 0
fi
