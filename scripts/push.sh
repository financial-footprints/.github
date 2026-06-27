#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(pwd)"

# Repo keys in default processing order (dependency chain).
DEFAULT_REPOS=(csv sync dom readme)

declare -A REPO_DIRS=(
  [readme]="README"
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [dom]="NetworthDOM"
)

declare -A REPO_LABELS=(
  [readme]="README"
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [dom]="NetworthDOM"
)

AMEND=false
PUSH_FORCE=false
SELECTED_REPOS=()

usage() {
  cat <<'EOF'
Push all financial-footprints git repositories (add, commit, push).

Usage:
  push.sh [OPTIONS] [REPO...]

Options:
  -h, --help    Print this help and exit
  --amend       Use `git commit --amend` instead of `git commit`
  --force       Use `git push --force`

Repos (optional; default: all four, in dependency order):
  readme | README       Meta / policies repository
  csv    | NetworthCSV  PDF/email to CSV pipeline
  sync   | NetworthSync HTTP API over NetworthCSV
  dom    | NetworthDOM  Browser UI

Examples:
  ./scripts/push.sh            # all repos (run from workspace root)
  ./scripts/push.sh csv sync   # only NetworthCSV and NetworthSync
  ./scripts/push.sh --amend dom
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
      --force)
        PUSH_FORCE=true
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

process_repo() {
  local key="$1"
  local dir="${REPO_DIRS[$key]}"
  local label="${REPO_LABELS[$key]}"
  local repo_path="$WORKSPACE_ROOT/$dir"

  if [[ ! -d "$repo_path" ]]; then
    echo "[$key] skipped: directory not found: $repo_path" >&2
    return 2
  fi

  if [[ ! -d "$repo_path/.git" ]]; then
    echo "[$key] skipped: not a git repository: $repo_path" >&2
    return 2
  fi

  (
    cd "$repo_path"

    echo "[$key] adding all changes in $label..."
    git add -A

    if git diff --cached --quiet; then
      echo "[$key] no staged changes; skipping commit"
    else
      local message
      if [[ "$AMEND" == true ]]; then
        read -r -p "[$key] Amend message for $label (empty to keep current): " message
        if [[ -z "$message" ]]; then
          echo "[$key] amending commit (no message change)..."
          git commit --amend --no-edit
        else
          echo "[$key] amending commit..."
          git commit --amend -m "$message"
        fi
      else
        read -r -p "[$key] Commit message for $label: " message
        if [[ -z "$message" ]]; then
          echo "[$key] empty commit message; skipping commit"
        else
          echo "[$key] committing..."
          git commit -m "$message"
        fi
      fi
    fi

    echo "[$key] pushing..."
    if [[ "$PUSH_FORCE" == true ]]; then
      git push --force
    else
      git push
    fi
  )
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
