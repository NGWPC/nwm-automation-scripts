#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONFIG="owpRepoSyncConfig.json"
DEFAULT_DEV_BRANCH="development"
DEFAULT_PARENT_ORG="NOAA-OWP"
DEFAULT_HOST="github.com"
DEFAULT_PROTO="ssh"   # ssh | https

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [-c <config.json>] [-d <dev-branch>] [-p <parent-org>] [-H <host>] [--https] [-v] [-h]

Description:
  Report-only: compares parent default branch (main/master) against:
    - your fork default branch (origin/HEAD -> origin/<default>)
    - your fork development branch (development or origin/development)

  Outputs counts of commits present on parent default that are missing from:
    - fork default
    - development

Config fields (per entry):
  repo_directory      (required)
  upstream_repo       (optional) e.g. "NOAA-OWP/cfe"
  upstream_url        (optional) e.g. "git@github.com:NOAA-OWP/cfe.git"
  upstream_default    (optional) e.g. "main" or "master" (if omitted, detected via ls-remote HEAD)
  skip               (optional) true|false (if true, entry is silently ignored)

If neither upstream_repo nor upstream_url are present, parent is assumed:
  <parent-org>/<basename(repo_directory)>

Options:
  -c <config.json>   Config file (default: ${DEFAULT_CONFIG})
  -d <dev-branch>    Dev branch (default: ${DEFAULT_DEV_BRANCH})
  -p <parent-org>    Parent org/user (default: ${DEFAULT_PARENT_ORG})
  -H <host>          Git host (default: ${DEFAULT_HOST})
  --https            Use https URLs instead of ssh (default is ssh)
  -v                 Verbose: after summary, list missing commits per repo
  -h                 Help
EOF
}

CONFIG_FILE="$DEFAULT_CONFIG"
DEV_BRANCH="$DEFAULT_DEV_BRANCH"
PARENT_ORG="$DEFAULT_PARENT_ORG"
HOST="$DEFAULT_HOST"
PROTO="$DEFAULT_PROTO"
VERBOSE=0

# Handle long opts
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --https) PROTO="https"; shift ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

while getopts ":c:d:p:H:vh" opt; do
  case "$opt" in
    c) CONFIG_FILE="$OPTARG" ;;
    d) DEV_BRANCH="$OPTARG" ;;
    p) PARENT_ORG="$OPTARG" ;;
    H) HOST="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: Unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
    :)  echo "ERROR: Option -$OPTARG requires an argument." >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 2
fi

make_url_from_repo() {
  local owner_repo="$1"  # OWNER/REPO
  if [[ "$PROTO" == "https" ]]; then
    echo "https://${HOST}/${owner_repo}.git"
  else
    echo "git@${HOST}:${owner_repo}.git"
  fi
}

detect_parent_default_branch() {
  local url="$1"
  local ref
  ref="$(git ls-remote --symref "$url" HEAD 2>/dev/null | awk '/^ref: /{print $2; exit}')"
  [[ -n "$ref" ]] || { echo ""; return; }
  echo "${ref##refs/heads/}"
}

detect_origin_default_branch() {
  local head_ref
  head_ref="$(git symbolic-ref -q "refs/remotes/origin/HEAD" 2>/dev/null || true)"
  if [[ -n "$head_ref" ]]; then
    echo "${head_ref##*/}"
    return
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/master"; then
    echo "master"; return
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/main"; then
    echo "main"; return
  fi
  echo ""
}

tmpref_base="refs/tmp/parent-default"

declare -a ROWS=()
declare -a SKIPS=()
declare -A COMMIT_TABLES=()   # repo_name -> preformatted table text (verbose only)

echo
echo "Parent vs Fork-default vs Dev report (report-only)"
echo "  Config     : $CONFIG_FILE"
echo "  Dev branch : $DEV_BRANCH"
echo "  Parent org : $PARENT_ORG"
echo "  Host/Proto : $HOST / $PROTO"
echo

while IFS= read -r entry; do
  repo_dir="$(echo "$entry" | jq -r '.repo_directory')"
  upstream_repo="$(echo "$entry" | jq -r '.upstream_repo // empty')"
  upstream_url="$(echo "$entry" | jq -r '.upstream_url // empty')"
  upstream_default_cfg="$(echo "$entry" | jq -r '.upstream_default // empty')"
  upstream_local_branch="$(echo "$entry" | jq -r '.upstream_local_branch // empty')"
  skip_entry="$(echo "$entry" | jq -r '.skip // false')"

  # Silently skip if skip=true
  if [[ "$skip_entry" == "true" ]]; then
    continue
  fi

  repo_dir="${repo_dir/#\~/$HOME}"
  repo_name="$(basename "$repo_dir")"

  echo "Checking repository: $repo_dir"

  if [[ ! -d "$repo_dir/.git" ]]; then
    SKIPS+=("${repo_name}: not a git repo")
    echo
    continue
  fi

  pushd "$repo_dir" >/dev/null

  # Ensure origin tracking refs are current (read-only)
  git fetch origin >/dev/null 2>&1 || true

  # Dev ref (prefer local branch, else origin/dev)
  dev_ref=""
  dev_label=""
  if git show-ref --verify --quiet "refs/heads/${DEV_BRANCH}"; then
    dev_ref="refs/heads/${DEV_BRANCH}"
    dev_label="${DEV_BRANCH}"
  elif git show-ref --verify --quiet "refs/remotes/origin/${DEV_BRANCH}"; then
    dev_ref="refs/remotes/origin/${DEV_BRANCH}"
    dev_label="origin/${DEV_BRANCH}"
  else
    SKIPS+=("${repo_name}: dev branch not found (${DEV_BRANCH})")
    popd >/dev/null
    echo
    continue
  fi

  # Parent URL
  parent_url=""
  if [[ -n "$upstream_url" ]]; then
    parent_url="$upstream_url"
  elif [[ -n "$upstream_repo" ]]; then
    parent_url="$(make_url_from_repo "$upstream_repo")"
  else
    parent_url="$(make_url_from_repo "${PARENT_ORG}/${repo_name}")"
  fi

  # Parent branch: use config upstream_default if provided, else detect via ls-remote HEAD
  parent_branch=""
  if [[ -n "$upstream_default_cfg" ]]; then
    parent_branch="$upstream_default_cfg"
  else
    parent_branch="$(detect_parent_default_branch "$parent_url")"
  fi

  if [[ -z "$parent_branch" ]]; then
    SKIPS+=("${repo_name}: cannot determine parent default (${parent_url})")
    popd >/dev/null
    echo
    continue
  fi

  # Fork like-named ref (match upstream default branch name)
  fork_like_ref="refs/remotes/origin/${parent_branch}"
  fork_like_label="origin/${parent_branch}"

  if ! git show-ref --verify --quiet "${fork_like_ref}"; then
    SKIPS+=("${repo_name}: fork missing like-named branch (${fork_like_label})")
    popd >/dev/null
    echo
    continue
  fi

  parent_display="$parent_branch"

  if [[ -n "$upstream_local_branch" ]] && [[ "$upstream_local_branch" != "$parent_branch" ]]; then
    parent_display="${parent_branch} (local=${upstream_local_branch})"
  fi

  tmpref="${tmpref_base}/${repo_name}"

  # Fetch parent default into temp ref (no remotes created/modified)
  if ! git fetch -q "$parent_url" "refs/heads/${parent_branch}:${tmpref}"; then
    SKIPS+=("${repo_name}: fetch failed for parent ${parent_branch} (${parent_url})")
    popd >/dev/null
    echo
    continue
  fi

  # Counts of parent commits missing from fork default and dev
  missing_from_fork_like="$(git rev-list --count "${fork_like_ref}..${tmpref}" 2>/dev/null || echo 0)"
  missing_from_dev="$(git rev-list --count "${dev_ref}..${tmpref}" 2>/dev/null || echo 0)"

  ROWS+=("${repo_name}|${parent_display}|${fork_like_label}|${missing_from_fork_like}|${missing_from_dev}")

  # Verbose: build commit tables for repos with changes, but print only after summary.
  if [[ $VERBOSE -eq 1 ]] && { [[ "$missing_from_fork_like" -gt 0 ]] || [[ "$missing_from_dev" -gt 0 ]]; }; then
    # Build a hash -> missing-from label map (fork/dev/both)
    declare -A miss_map=()

    while IFS= read -r h; do
      [[ -n "$h" ]] || continue
      miss_map["$h"]="fork"
    done < <(git rev-list "${fork_default_ref}..${tmpref}")

    while IFS= read -r h; do
      [[ -n "$h" ]] || continue
      if [[ -n "${miss_map[$h]+x}" ]]; then
        miss_map["$h"]="both"
      else
        miss_map["$h"]="dev"
      fi
    done < <(git rev-list "${dev_ref}..${tmpref}")

    # Walk parent history (newest->oldest) and emit rows for union set
    table="$(
      printf "%-10s | %-10s | %-4s | %s\n" "Hash" "Date" "Miss" "Subject"
      printf "%-10s-+-%-10s-+-%-4s-+-%s\n" "----------" "----------" "----" "----------------------------------------"
      git log "${tmpref}" --date=short --pretty=format:'%H|%h|%ad|%s' | \
      while IFS='|' read -r full short date subj; do
        if [[ -n "${miss_map[$full]+x}" ]]; then
          printf "%-10s | %-10s | %-4s | %s\n" "$short" "$date" "${miss_map[$full]}" "$subj"
        fi
      done
    )"

    COMMIT_TABLES["$repo_name"]="$table"
  fi

  popd >/dev/null
  echo
done < <(jq -c '.[]' "$CONFIG_FILE")

# Final report
echo
echo "Summary"
echo "=========================================================================================================="
printf "%-25s | %-10s | %-12s | %-22s | %-18s\n" \
  "Repository" "Parent" "Fork default" "Parent missing from fork" "Parent missing from dev"
echo "--------------------------+------------+--------------+--------------------------+------------------------"
for row in "${ROWS[@]}"; do
  IFS='|' read -r r parent forkdef missfork missdev <<< "$row"
  printf "%-25s | %-10s | %-12s | %-24s | %-18s\n" "$r" "$parent" "$forkdef" "$missfork" "$missdev"
done

if [[ ${#SKIPS[@]} -gt 0 ]]; then
  echo
  echo "Skipped"
  echo "=================================================================================================="
  for s in "${SKIPS[@]}"; do
    echo "  - $s"
  done
fi

if [[ $VERBOSE -eq 1 ]] && [[ ${#COMMIT_TABLES[@]} -gt 0 ]]; then
  echo
  echo "Verbose commit details (parent commits missing from fork/dev)"
  echo "=================================================================================================="
  # Print in the same order as summary rows
  for row in "${ROWS[@]}"; do
    IFS='|' read -r r _ _ missfork missdev <<< "$row"
    if [[ -n "${COMMIT_TABLES[$r]+x}" ]]; then
      echo
      echo "Repository: $r"
      echo "  Missing from fork: $missfork   Missing from dev: $missdev"
      echo "${COMMIT_TABLES[$r]}"
    fi
  done
fi
