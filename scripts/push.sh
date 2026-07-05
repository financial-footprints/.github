#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_REPOS=(csv sync dom readme)

declare -A REPOS=(
  [readme]=README
  [csv]=NetworthCSV
  [sync]=NetworthSync
  [dom]=NetworthDOM
)

AMEND=false
FORCE_AMEND=false
PUSH_FORCE=false
ASK_BODY=false
SELECTED_REPOS=()

COMMIT_SUBJECT=""
COMMIT_BODY=""

usage() {
  cat <<'EOF'
Push all financial-footprints git repositories (add, commit, push).

Usage:
  push.sh [OPTIONS] [REPO...]

Options:
  -h, --help      Print this help and exit
  --amend         Amend the previous commit when there are staged changes
  --force-amend   Amend the previous commit even with no staged changes
  --body          Prompt for subject (one line) then body (multi-line, finish with Enter twice)
  --force         Use `git push --force` (also automatic after --amend)

Repos (optional; default: all four, in dependency order):
  readme | README       Meta / policies repository
  csv    | NetworthCSV  PDF/email to CSV pipeline
  sync   | NetworthSync HTTP API over NetworthCSV
  dom    | NetworthDOM  Browser UI

Examples:
  ./scripts/push.sh            # all repos (from any directory)
  ./scripts/push.sh csv sync   # only NetworthCSV and NetworthSync
  ./scripts/push.sh --amend dom
  ./scripts/push.sh --force-amend --body csv
  ./scripts/push.sh --body sync
  ./scripts/push.sh --body csv sync
  ./scripts/push.sh --amend --body dom
  ./scripts/push.sh --force readme
EOF
}

normalize_repo() {
  local input
  input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$input" in
    readme) printf '%s\n' readme ;;
    csv | networthcsv) printf '%s\n' csv ;;
    sync | networthsync) printf '%s\n' sync ;;
    dom | networthdom) printf '%s\n' dom ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --amend)
        AMEND=true
        shift
        ;;
      --force-amend)
        AMEND=true
        FORCE_AMEND=true
        shift
        ;;
      --force)
        PUSH_FORCE=true
        shift
        ;;
      --body)
        ASK_BODY=true
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "error: unknown option: $1" >&2
        echo "Run 'push.sh --help' for usage." >&2
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  while [[ $# -gt 0 ]]; do
    local key
    if ! key="$(normalize_repo "$1")"; then
      echo "error: unknown repository: $1" >&2
      echo "Run 'push.sh --help' for valid repo names." >&2
      exit 1
    fi
    SELECTED_REPOS+=("$key")
    shift
  done

  if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
    SELECTED_REPOS=("${DEFAULT_REPOS[@]}")
  fi
}

repo_log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

prompt_subject() {
  local key="$1" label="$2" amend="$3"

  echo "" >&2
  if [[ "$amend" == true ]]; then
    repo_log "$key" "Enter subject for $label (one line only; press Enter to keep current):"
  else
    repo_log "$key" "Enter subject for $label (one line only):"
  fi
  repo_log "$key" "  Do not paste the body here — you will be asked for it next."
  read -r -p "[$key] > " COMMIT_SUBJECT
}

# Two consecutive empty lines finish input; single empty lines are paragraph breaks.
prompt_body() {
  local key="$1" label="$2"
  local line text="" pending_empty=false

  COMMIT_BODY=""
  echo "" >&2
  repo_log "$key" "Enter body for $label:"
  repo_log "$key" "  Type your message. Blank lines between paragraphs are allowed."
  repo_log "$key" "  Press Enter twice on empty lines when you are done."
  repo_log "$key" "  Press Enter twice now to skip the body."
  echo "" >&2

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      if [[ "$pending_empty" == true ]]; then
        break
      fi
      pending_empty=true
      if [[ -n "$text" ]]; then
        text="${text}"$'\n'
      fi
    else
      pending_empty=false
      if [[ -z "$text" ]]; then
        text="$line"
      else
        text="${text}"$'\n'"${line}"
      fi
    fi
  done

  COMMIT_BODY="$text"
}

collect_commit_message() {
  local key="$1" label="$2"

  COMMIT_SUBJECT=""
  COMMIT_BODY=""

  if [[ "$ASK_BODY" == true ]]; then
    prompt_subject "$key" "$label" "$AMEND"
    prompt_body "$key" "$label"
    return
  fi

  if [[ "$AMEND" == true ]]; then
    read -r -p "[$key] Amend message for $label (empty to keep current): " COMMIT_SUBJECT
  else
    read -r -p "[$key] Commit message for $label: " COMMIT_SUBJECT
  fi
}

has_staged_changes() {
  ! git diff --cached --quiet
}

git_write_commit() {
  local amend="$1" subject="$2" body="$3"
  local -a cmd=(git commit)

  [[ "$amend" == true ]] && cmd+=(--amend)
  cmd+=(-m "$subject")
  [[ -n "$body" ]] && cmd+=(-m "$body")
  "${cmd[@]}"
}

git_push() {
  if [[ "$PUSH_FORCE" == true || "$AMEND" == true ]]; then
    git push --force
  else
    git push
  fi
}

should_commit() {
  local key="$1" has_staged="$2"

  if [[ "$has_staged" == true ]]; then
    return 0
  fi
  if [[ "$AMEND" == true && "$FORCE_AMEND" == true ]]; then
    return 0
  fi
  if [[ "$AMEND" == true ]]; then
    echo "[$key] no staged changes; skipping commit (use --force-amend to amend anyway)"
  else
    echo "[$key] no staged changes; skipping commit"
  fi
  return 1
}

perform_commit() {
  local key="$1" has_staged="$2"
  local subject="$COMMIT_SUBJECT" body="$COMMIT_BODY"

  if [[ "$AMEND" != true ]]; then
    if [[ -z "$subject" ]]; then
      echo "[$key] empty subject; skipping commit"
      return
    fi
    echo "[$key] committing..."
    git_write_commit false "$subject" "$body"
    return
  fi

  if [[ -z "$subject" && -z "$body" ]]; then
    if [[ "$has_staged" == false ]]; then
      echo "[$key] nothing to amend; skipping"
    else
      echo "[$key] amending commit (no message change)..."
      git commit --amend --no-edit
    fi
    return
  fi

  local resolved="$subject"
  [[ -z "$resolved" ]] && resolved="$(git log -1 --format=%s)"

  echo "[$key] amending commit..."
  git_write_commit true "$resolved" "$body"
}

process_repo() {
  local key="$1"
  local label="${REPOS[$key]}"
  local repo_path="$WORKSPACE_ROOT/$label"
  local start_dir="$PWD"
  local has_staged=false

  if [[ ! -d "$repo_path" ]]; then
    echo "[$key] skipped: directory not found: $repo_path" >&2
    return 2
  fi

  if [[ ! -d "$repo_path/.git" ]]; then
    echo "[$key] skipped: not a git repository: $repo_path" >&2
    return 2
  fi

  cd "$repo_path"

  echo "[$key] adding all changes in $label..."
  git add -A

  if has_staged_changes; then
    has_staged=true
  fi

  if should_commit "$key" "$has_staged"; then
    if [[ "$AMEND" == true && "$has_staged" == false ]]; then
      echo "[$key] no staged changes; force-amending previous commit..."
    fi
    collect_commit_message "$key" "$label"
    perform_commit "$key" "$has_staged"
  fi

  echo "[$key] pushing..."
  git_push

  cd "$start_dir"
}

main() {
  parse_args "$@"

  local succeeded=0
  local failed=0
  local skipped=0
  local key

  for key in "${SELECTED_REPOS[@]}"; do
    if process_repo "$key"; then
      succeeded=$((succeeded + 1))
    else
      local status=$?
      if [[ "$status" -eq 2 ]]; then
        skipped=$((skipped + 1))
      else
        failed=$((failed + 1))
        echo "[$key] failed" >&2
      fi
    fi
  done

  echo
  echo "Summary: $succeeded succeeded, $failed failed, $skipped skipped"

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
