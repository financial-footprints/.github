#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Repo keys in default processing order (dependency chain).
DEFAULT_REPOS=(csv sync dom)

declare -A REPO_DIRS=(
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [dom]="NetworthDOM"
)

declare -A REPO_LABELS=(
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [dom]="NetworthDOM"
)

SELECTED_REPOS=()

usage() {
  cat <<'EOF'
Run `make dev-ci` in financial-footprints repositories (format, lint, test).

Stops at the first error or warning. Remaining repos are not run.

Usage:
  ci.sh [OPTIONS] [REPO...]

Options:
  -h, --help    Print this help and exit

Repos (optional; default: all three, in dependency order):
  csv    | NetworthCSV  PDF/email to CSV pipeline
  sync   | NetworthSync HTTP API over NetworthCSV
  dom    | NetworthDOM  Browser UI

Examples:
  ./scripts/ci.sh            # all repos (from any directory)
  ./scripts/ci.sh csv sync   # only NetworthCSV and NetworthSync
  ./scripts/ci.sh dom
EOF
}

normalize_repo() {
  local input
  input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$input" in
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
      --)
        shift
        break
        ;;
      -*)
        echo "error: unknown option: $1" >&2
        echo "Run 'ci.sh --help' for usage." >&2
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
      echo "Run 'ci.sh --help' for valid repo names." >&2
      exit 1
    fi
    SELECTED_REPOS+=("$key")
    shift
  done

  if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
    SELECTED_REPOS=("${DEFAULT_REPOS[@]}")
  fi
}

failed_make_target() {
  local output_file="$1"
  grep -oE 'make: \*\*\* \[Makefile:[0-9]+: [a-zA-Z0-9_-]+\]' "$output_file" 2>/dev/null | tail -1 | sed -E 's/.*: ([a-zA-Z0-9_-]+)\]$/\1/' || true
}

extract_issues() {
  local output_file="$1"
  grep -E ' - (error|warning): |error TS[0-9]+|✖|× ' "$output_file" 2>/dev/null || true
}

report_failure() {
  local key="$1"
  local label="$2"
  local output_file="$3"
  local target

  target="$(failed_make_target "$output_file")"

  echo >&2
  if [[ -n "$target" ]]; then
    echo "CI stopped: $label ($key) failed during make $target." >&2
  else
    echo "CI stopped: $label ($key) failed during make dev-ci." >&2
  fi

  local issues
  issues="$(extract_issues "$output_file")"
  if [[ -n "$issues" ]]; then
    echo >&2
    echo "Error or warning location(s):" >&2
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done <<<"$issues"
  fi
  echo >&2
}

process_repo() {
  local key="$1"
  local dir="${REPO_DIRS[$key]}"
  local label="${REPO_LABELS[$key]}"
  local repo_path="$WORKSPACE_ROOT/$dir"
  local output_file

  if [[ ! -d "$repo_path" ]]; then
    echo "[$key] skipped: directory not found: $repo_path" >&2
    return 2
  fi

  if [[ ! -f "$repo_path/Makefile" ]]; then
    echo "[$key] skipped: no Makefile in $repo_path" >&2
    return 2
  fi

  output_file="$(mktemp)"

  echo "[$key] running make dev-ci in $label..."
  if (cd "$repo_path" && make dev-ci) 2>&1 | tee "$output_file"; then
    rm -f "$output_file"
    return 0
  fi

  report_failure "$key" "$label" "$output_file"
  rm -f "$output_file"
  return 1
}

main() {
  parse_args "$@"

  local key
  local completed=()
  local skipped=0

  for key in "${SELECTED_REPOS[@]}"; do
    if process_repo "$key"; then
      completed+=("$key")
    else
      local status=$?
      if [[ "$status" -eq 2 ]]; then
        skipped=$((skipped + 1))
        echo "[$key] skipped" >&2
      else
        exit 1
      fi
    fi
  done

  if [[ ${#completed[@]} -eq 0 ]]; then
    echo "CI did not run: no repositories found under $WORKSPACE_ROOT" >&2
    exit 1
  fi

  echo
  if [[ ${#completed[@]} -eq 1 ]]; then
    echo "CI passed for ${REPO_LABELS[${completed[0]}]}."
  else
    local names=()
    local k
    for k in "${completed[@]}"; do
      names+=("${REPO_LABELS[$k]}")
    done
    echo "CI passed for ${names[*]}."
  fi
}

main "$@"
