#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONFIG="createReleaseConfig.json"
DEFAULT_BRANCH="ngwpc-candidate"
DEFAULT_MODE="any"   # merges | any

usage() {
  cat <<'EOF'
Usage:
  findMerges.sh -a "<after-datetime>" [-c <config.json>] [-b <branch>] [-v] [--mode merges|any] [-h]

Description:
  Scans repo_directory entries in a JSON config file.

  Modes:
    --mode any (default) : shows any commits added to the branch after the cutoff time (catches rebase/squash)
    --mode merges        : shows only merge commits (will NOT catch rebase/squash fast-forward merges)

  By default (non-verbose), it prints only the repositories that had changes.
  With -v (verbose), it prints the matching commits in the summary table.

Required:
  -a "<after-datetime>"   Examples:
                            "2026-01-27"
                            "2026-01-27 19:15:08"
                            "2026-01-27 19:15:08 -0500"

Optional:
  -c <config.json>        Config file (default: createReleaseConfig.json)
  -b <branch>             Branch to check (default: ngwpc-candidate)
  -v                      Verbose output (commit list)
  --mode merges|any       Matching mode (default: any)
  -h                      Show this help
EOF
}

CONFIG_FILE="$DEFAULT_CONFIG"
AFTER_DATETIME=""
BRANCH="$DEFAULT_BRANCH"
VERBOSE=0
MODE="$DEFAULT_MODE"

# Parse short opts first; then handle long opts
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --mode=*)
      MODE="${1#*=}"
      shift
      ;;
    --)
      shift
      ARGS+=("$@")
      break
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional parameters for getopts
set -- "${ARGS[@]}"

while getopts ":c:a:b:vh" opt; do
  case "$opt" in
    c) CONFIG_FILE="$OPTARG" ;;
    a) AFTER_DATETIME="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: Unknown option -$OPTARG" >&2; echo >&2; usage >&2; exit 2 ;;
    :)  echo "ERROR: Option -$OPTARG requires an argument." >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$AFTER_DATETIME" ]]; then
  echo "ERROR: -a <after-datetime> is required." >&2
  echo >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 2
fi

if [[ "$MODE" != "merges" && "$MODE" != "any" ]]; then
  echo "ERROR: --mode must be 'merges' or 'any' (got: $MODE)" >&2
  exit 2
fi

# Rows:
#   non-verbose: repo
#   verbose:     repo|date|hash|msg
declare -a TABLE_ROWS=()

echo
echo "Scanning repositories..."
echo "  Config  : $CONFIG_FILE"
echo "  Branch  : $BRANCH"
echo "  After   : $AFTER_DATETIME"
echo "  Mode    : $MODE"
echo "  Verbose : $([[ $VERBOSE -eq 1 ]] && echo yes || echo no)"
echo

while IFS= read -r repo_dir; do
  repo_dir="${repo_dir/#\~/$HOME}"
  repo_name="$(basename "$repo_dir")"

  echo "Checking repository: $repo_dir"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "  WARNING: Repository not found or not a git repo; skipping."
    continue
  fi
  pushd "$repo_dir" >/dev/null

  git fetch origin "$BRANCH" >/dev/null 2>&1 || true

  if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    REF="origin/$BRANCH"
  elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    REF="$BRANCH"
  else
    popd >/dev/null
    continue
  fi

  if [[ "$MODE" == "merges" ]]; then
    if [[ $VERBOSE -eq 1 ]]; then
      mapfile -t HITS < <(
        git log "$REF" \
          --after="$AFTER_DATETIME" \
          --merges \
          --pretty=format:"%ad|%h|%s" \
          --date=short \
          || true
      )
      if [[ ${#HITS[@]} -gt 0 ]]; then
        for line in "${HITS[@]}"; do
          TABLE_ROWS+=("$repo_name|$line")
        done
      fi
    else
      COUNT="$(
        git log "$REF" --after="$AFTER_DATETIME" --merges --pretty=format:"1" | wc -l | tr -d ' '
      )"
      if [[ "$COUNT" -gt 0 ]]; then
        TABLE_ROWS+=("$repo_name")
      fi
    fi

  else
    # MODE=any: find any commits added since the cutoff time.
    # Find the branch tip at or before the cutoff; if none, treat as "from the beginning".
    BASE="$(git rev-list -n 1 --before="$AFTER_DATETIME" "$REF" 2>/dev/null || true)"

    if [[ $VERBOSE -eq 1 ]]; then
      if [[ -n "$BASE" ]]; then
        RANGE="${BASE}..${REF}"
      else
        RANGE="${REF}"
      fi

      mapfile -t HITS < <(
        git log "$RANGE" \
          --pretty=format:"%ad|%h|%s" \
          --date=short \
          || true
      )

      if [[ ${#HITS[@]} -gt 0 ]]; then
        for line in "${HITS[@]}"; do
          TABLE_ROWS+=("$repo_name|$line")
        done
      fi
    else
      if [[ -n "$BASE" ]]; then
        # Count commits in (BASE..REF]
        COUNT="$(git rev-list --count "${BASE}..${REF}" 2>/dev/null || echo 0)"
      else
        # No commit existed before cutoff, count all reachable commits (rare for your use case)
        COUNT="$(git rev-list --count "${REF}" 2>/dev/null || echo 0)"
      fi

      if [[ "$COUNT" -gt 0 ]]; then
        TABLE_ROWS+=("$repo_name")
      fi
    fi
  fi

  popd >/dev/null
done < <(jq -r '.[].repo_directory' "$CONFIG_FILE")

echo
if [[ ${#TABLE_ROWS[@]} -eq 0 ]]; then
  if [[ "$MODE" == "merges" ]]; then
    echo "No merge commits found on '$BRANCH' after $AFTER_DATETIME."
  else
    echo "No commits found on '$BRANCH' after $AFTER_DATETIME."
  fi
  exit 0
fi

# --- Compute unique repo count for the title ---
if [[ $VERBOSE -eq 1 ]]; then
  REPOS_WITH_CHANGES_COUNT="$(
    printf "%s\n" "${TABLE_ROWS[@]}" | awk -F'|' '{print $1}' | sort -u | wc -l | tr -d ' '
  )"
else
  REPOS_WITH_CHANGES_COUNT="$(
    printf "%s\n" "${TABLE_ROWS[@]}" | sort -u | wc -l | tr -d ' '
  )"
fi

if [[ $VERBOSE -eq 1 ]]; then
  echo "Summary (verbose) — Repositories with changes (${REPOS_WITH_CHANGES_COUNT})"
  echo "============================================================="
  printf "%-25s | %-10s | %-8s | %s\n" "Repository" "Date" "Commit" "Message"
  echo "-------------------------------------------------------------"
  for row in "${TABLE_ROWS[@]}"; do
    IFS='|' read -r repo date hash msg <<< "$row"
    printf "%-25s | %-10s | %-8s | %s\n" "$repo" "$date" "$hash" "$msg"
  done
else
  echo "Repositories with changes (${REPOS_WITH_CHANGES_COUNT})"
  echo "============================================================="
  printf "%s\n" "${TABLE_ROWS[@]}" | sort -u
fi
