#!/bin/bash

# Start logging everything to a file
LOGFILE="createRelease_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(sed -r "s/\x1B\[[0-9;]*[mK]//g" >> "$LOGFILE")) 2>&1
echo "All output will be logged to: $LOGFILE"

declare -a TEMP_BRANCHES

# Unified release branch used across all repositories for OFFICIAL releases.
RELEASE_BRANCH="ngwpc-release"
RELEASE_CANDIDATE_BRANCH='ngwpc-candidate'

# Toggle for printing the exact 'gh' commands being executed.
# Printed commands go to STDERR so that JSON captures using $(...) are not polluted.
DEBUG_GH=true

#-----------------------------------------
# Function: usage
# Displays usage information and exits.
#-----------------------------------------
usage() {
  echo "Usage: $(basename "$0") <RELEASE_TYPE> [JSON_FILE] [WAIT_TIME]"
  echo
  echo "This script automates the release process for GitHub repositories, handling merges,"
  echo "submodules, and versioning."
  echo "It performs the following steps based on the release type:"
  echo
  echo "🔹 RC (Release Candidate) Process:"
  echo "  1. Merge from 'development' to '\$RELEASE_CANDIDATE_BRANCH' (except for RC1)."
  echo "  2. If submodules exist, ensure they are on the correct branch."
  echo "  3. Create a GitHub release for the RC."
  echo "  4. Merge '\$RELEASE_CANDIDATE_BRANCH' back into 'development' (except for RC1)."
  echo
  echo "🔹 Official Release Process:"
  echo "  1. Merge from '\$RELEASE_CANDIDATE_BRANCH' to '\$RELEASE_BRANCH'."
  echo "  2. If submodules exist, ensure they are on the correct branch."
  echo "  3. Create a GitHub release for the official version."
  echo
  echo "🔹 Handling Submodules:"
  echo "  - Submodules are checked out to match the parent's target branch"
  echo "    ('\$RELEASE_CANDIDATE_BRANCH', 'development', or '\$RELEASE_BRANCH'), then committed in the parent."
  echo "  - A temporary branch is created for submodule updates, ensuring consistency across modules."
  echo "  - The temporary branch is then merged back into the appropriate target branch."
  echo
  echo "Arguments:"
  echo "  RELEASE_TYPE : REQUIRED. Must be either 'OFFICIAL' or 'RC'."
  echo "  JSON_FILE    : Optional. Path to the configuration JSON file."
  echo "                 Default is 'createReleaseConfig.json'."
  echo "  WAIT_TIME    : Optional. Wait time for mergeable check in seconds."
  echo "                 Default is 300 seconds."
  echo
  echo "Example:"
  echo "  $(basename "$0") RC release_config.json 300"
  echo
  exit 0
}

# If the first argument is -h or --help, display usage.
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

# Define color codes
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

#-----------------------------------------
# Function: git_push
# Quiet wrapper around `git push` that suppresses routine output
# (e.g., GitHub's "Create a pull request" hint) but still surfaces
# real errors. It:
#   - runs `git push -q` with all arguments passed through
#   - captures stderr/stdout on failure and prints them
#
# Arguments:
#   $@ - Arguments passed directly to `git push`
#
# Returns:
#   0 on success; 1 on failure (after printing the captured error output)
#-----------------------------------------
git_push() {
  if ! out=$(git push -q "$@" 2>&1); then
    echo -e "${RED}git push failed: git push $*${NC}"
    echo "$out" >&2
    return 1
  fi
  return 0
}

#-----------------------------------------
# Function: run_gh
# Prints and executes a `gh` command.
#
# WHY:
#   We want to see the exact `gh` command lines that run (for debugging).
#
# BEHAVIOR:
#   - If DEBUG_GH=true, prints:  Executing: gh <args...>
#   - The print goes to STDERR so that callers that capture STDOUT via $(...) do not
#     get the "Executing:" line mixed into JSON or other command output.
#   - Returns `gh`'s exit status and streams `gh`'s STDOUT/STDERR unchanged.
#
# USAGE:
#   run_gh release create ...
#   json=$(run_gh pr create --json number)
#-----------------------------------------
run_gh() {
  local args=("$@")
  if [ "$DEBUG_GH" = true ]; then
    printf 'Executing: ' >&2; printf '%q ' gh "${args[@]}" >&2; echo >&2
  fi
  gh "${args[@]}"
}

#-----------------------------------------
# Function: clean_and_encode_project
# Normalizes a GitHub remote URL to the canonical "owner/repo" form.
# Works for HTTPS and SSH remotes, and strips embedded credentials and .git suffix.
#-----------------------------------------
clean_and_encode_project() {
  local project_url="$1"
  project_url=$(echo "$project_url" | sed -e 's#^https\?://[^/]*@#https://#')
  project_url=$(echo "$project_url" | sed -e 's#^https://github\.com/##')
  project_url=$(echo "$project_url" | sed -e 's#^git@github\.com:##')
  project_url=$(echo "$project_url" | sed -e 's#\.git$##')
  echo "$project_url"
}

#-----------------------------------------
# (Deprecated) Function: determine_release_branch
# Determines whether the remote repository has a branch named "main" or "master"
# by querying the Git remote directly (no GitHub API).
#
# Behavior:
#   - Checks `origin` for refs/heads/main first, then refs/heads/master.
#   - On success, echoes the found branch name and returns 0.
#   - If neither exists, prints a clear error (to STDERR) and returns 1.
#
# Returns:
#   0 with "main" or "master" on stdout; 1 if neither exists.
#-----------------------------------------
# determine_release_branch() {
#   if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
#     echo "main"
#     return 0
#   fi
#   if git ls-remote --exit-code --heads origin master >/dev/null 2>&1; then
#     echo "master"
#     return 0
#   fi
#
#   # Neither found
#   echo -e "${RED}Error: Neither 'main' nor 'master' branch exists on remote 'origin' for repo $(git rev-parse --show-toplevel 2>/dev/null || echo "(unknown repo)")${NC}" >&2
#
#   return 1
# }

#-----------------------------------------
# Function: create_merge_request
# Creates a pull request using the GitHub CLI (`gh`).
#
# Arguments:
#   $1 - Source branch (head)
#   $2 - Target branch (base)
#   $3 - Title for the pull request
#
# Behavior:
#   - Uses `gh api` to POST the PR and echoes the PR number on success.
#   - If a matching open PR already exists (HTTP 422 case), queries for it and echoes its number.
#
# Requires:
#   REPO_PROJECT to be set to "owner/repo".
#
# Returns:
#   0 if a PR was created or an existing one was found; 1 otherwise.
#-----------------------------------------
create_merge_request() {
  local source_branch="$1"
  local target_branch="$2"
  local title="$3"

  echo
  echo -e "Creating pull request from ${GREEN}$source_branch${NC} to ${GREEN}$target_branch${NC}" >&2

  # Try to create PR via REST API and capture its number
  if pr_num=$(run_gh api \
        -X POST "repos/$REPO_PROJECT/pulls" \
        -f title="$title" \
        -f head="$source_branch" \
        -f base="$target_branch" \
        --jq '.number'); then
    if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
      echo "$pr_num"
      return 0
    fi
  fi

  # If it already exists (typical 422 case), look up the open PR matching head/base
  local owner="${REPO_PROJECT%%/*}"
  if pr_num=$(run_gh api \
        -X GET "repos/$REPO_PROJECT/pulls?state=open&head=${owner}:${source_branch}&base=${target_branch}" \
        --jq '.[0].number' 2>/dev/null); then
    if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
      echo "$pr_num"
      return 0
    fi
  fi

  echo -e "${RED}Error creating Pull Request from $source_branch to $target_branch${NC}" >&2
  return 1
}

#-----------------------------------------
# Function: trigger_merge
# Triggers merging a pull request using the GitHub CLI (`gh`).
#
# Arguments:
#   $1 - Pull request number
#   $2 - (Optional) delete branch flag:
#        "true"  -> delete source branch after merge (default)
#        "false" -> preserve source branch
#
# Behavior:
#   - If delete flag is true, passes --delete-branch to gh.
#   - Attempts immediate merge first; if not allowed, falls back to auto-merge.
#   - Logs clearly whether the branch will be deleted or preserved.
#
# Returns:
#   0 on success, 1 on failure.
#-----------------------------------------
trigger_merge() {
  local pr_number="$1"
  local delete_branch="${2:-true}"   # default: true
  local delete_flag=()

  if [[ "$delete_branch" == "true" ]]; then
    delete_flag=(--delete-branch)
    echo "Triggering merge for PR #$pr_number (source branch WILL be deleted)..."
  else
    echo "Triggering merge for PR #$pr_number (source branch will be PRESERVED)..."
  fi


  # 1) Try to merge immediately (non-auto). Deletes source branch on success.
  if run_gh pr merge "$pr_number" --merge "${delete_flag[@]}" >/dev/null 2>&1; then
    echo "Merge triggered successfully."
    echo
    return 0
  fi

  # 2) Fall back to auto-merge (queues merge once requirements are met).
  if run_gh pr merge "$pr_number" --merge --auto "${delete_flag[@]}" >/dev/null 2>&1; then
    echo "Auto-merge enabled (will merge when requirements are met)."
    echo
    return 0
  fi

  echo -e "${RED}Error triggering merge for PR $pr_number.${NC}"
  return 1
}

#-----------------------------------------
# Function: poll_merge_status
# Polls the pull request via `gh` until its status is either "MERGED" or "CLOSED".
#
# Arguments:
#   $1 - Pull request number
#
# Behavior:
#   Continuously queries the pull request state and displays progress until the state
#   is either "MERGED" or "CLOSED".
#-----------------------------------------
poll_merge_status() {
  local pr_number="$1"

  echo "Waiting for pull request $pr_number to complete..."
  while true; do
    local state
    # We suppress gh's own stderr here to keep logs tidy; the wrapper's
    # "Executing:" line is printed to STDERR and will also be suppressed.
    state=$(run_gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "")
    if [[ "$state" == "MERGED" ]]; then
      echo "Merge is complete."
      break
    elif [[ "$state" == "CLOSED" ]]; then
      echo "Pull request closed without merging."
      break
    else
      echo "Current pull request state: ${state:-unknown}. Waiting 10 seconds..."
      sleep 10
    fi
  done
}

#-----------------------------------------
# Function: wait_until_mergeable
#
# Waits until a PR is "merge-button eligible":
#   - NOT a draft, and
#   - NOT in conflict (mergeStateStatus != DIRTY), and
#   - NOT explicitly blocked (mergeStateStatus != BLOCKED).
#
# We DO allow: CLEAN, UNSTABLE, BEHIND, HAS_HOOKS, UNKNOWN
# Rationale: The UI shows the "Merge" button for those states when branch
#            protection doesn’t require passing checks. The merge API will
#            still 405 if rules block you, so don’t pre-block here.
#
# Arguments:
#   $1 - Pull Request number
#   $2 - Maximum wait time in seconds
#
# gh pr view output:
#   Command: gh pr view <PR#> --json isDraft,mergeStateStatus
#   Example return:
#     {
#       "isDraft": false,
#       "mergeStateStatus": "CLEAN"
#     }
#
#   Common values for mergeStateStatus:
#     CLEAN     -> mergeable right now (no conflicts, requirements met)
#     DIRTY     -> conflicts must be resolved
#     BLOCKED   -> explicitly blocked (e.g. required reviews not approved)
#     DRAFT     -> draft PR, cannot merge
#     UNSTABLE  -> checks pending/failing, but merge button may still be available
#     BEHIND    -> branch behind base, may need update (only blocks if required)
#     HAS_HOOKS -> waiting on external hooks
#     UNKNOWN   -> status not yet computed
#
# Behavior:
#   - Polls the PR and returns success once the PR is not draft/dirty/blocked.
#   - If the timeout is reached, prompts the user to Continue waiting or Skip.
#
# Returns:
#   0 if the PR becomes mergeable within the timeout,
#   1 on timeout (if user chooses Skip).
#-----------------------------------------
wait_until_mergeable() {
  local pr_number="$1"
  local max_wait="$2"
  local elapsed=0

  echo "Waiting up to $max_wait seconds for PR $pr_number to be mergeable..."

  while true; do
    # Query both draft state and merge state from GitHub
    local checks_state
    checks_state=$(gh pr view "$pr_number" --json isDraft,mergeStateStatus \
                     -q '[.isDraft, .mergeStateStatus]' 2>/dev/null || echo '["",""]')
    local is_draft state
    is_draft=$(echo "$checks_state" | jq -r '.[0]')
    state=$(echo "$checks_state"   | jq -r '.[1] // "UNKNOWN"')

    echo "PR $pr_number status: isDraft=$is_draft, mergeStateStatus=$state"

    # Proceed if not a draft, not in conflict, not explicitly blocked
    if [[ "$is_draft" != "true" && "$state" != "DIRTY" && "$state" != "BLOCKED" ]]; then
      echo "Pull request $pr_number appears mergeable (state: $state)"
      return 0
    fi

    if (( elapsed >= max_wait )); then
      while true; do
        read -n 1 -s -r -p "Pull Request $pr_number not ready (state: ${state:-unknown}). (C)ontinue waiting, (S)kip: " choice
        echo
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        case "$choice" in
          C) echo "Continuing to wait..."; elapsed=0; break;;
          S) echo "Skipping repository due to timeout."; return 1;;
          *) echo "Invalid option. Please enter C to continue waiting or S to skip.";;
        esac
      done
    fi

    echo "Waiting for PR $pr_number to be mergeable (state: ${state:-unknown})..."
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

#-----------------------------------------
# Function: create_release
# Creates a GitHub release using the GitHub CLI (`gh release create`).
#
# Arguments:
#   $1 - Release tag (e.g., "v1.1")
#   $2 - Release name (e.g., "Release 1.1")
#   $3 - Release notes (description)
#   $4 - Ref branch (the branch to base the release on)
#
# Behavior:
#   - Invokes `gh release create` and captures its stdout (the release URL).
#   - Prints the URL with a clear label: "New release: <url>".
#
# Returns:
#   0 on success, 1 on failure.
#-----------------------------------------
create_release() {
  local release_tag="$1"
  local release_name="$2"
  local release_notes="$3"
  local ref_branch="$4"

  local prerelease_flag=""
  [[ "$RELEASE_TYPE" == "RC" ]] && prerelease_flag="--prerelease"

  # Capture stdout from gh (which is the release URL on success). Our run_gh
  # prints the "Executing:" line to STDERR, so it won't pollute this capture.
  local release_url
  if release_url=$(run_gh release create "$release_tag" \
        --title "$release_name" \
        --notes "$release_notes" \
        --target "$ref_branch" \
        $prerelease_flag); then
    # Print with context so the URL isn't a naked line in logs
    echo -e "Release ${GREEN}$release_url${NC} created successfully."
    return 0
  fi

  echo -e "${RED}Error creating release.${NC}"
  return 1
}

#-----------------------------------------
# Function: execute_merge_request
# Combines creating a pull request, waiting until it becomes mergeable, and triggering the merge.
# We validate it locally before creating the PR to better ensure that it will succeed.
#
# Arguments:
#   $1 - Source branch
#   $2 - Target branch
#   $3 - Title for the pull request
#   $4 - Wait time (seconds)
#
# Behavior:
#   - Checks if the source branch has changes compared to the target.
#   - Attempts a local merge to detect conflicts before creating a pull request.
#   - Only proceeds to create the PR (via `gh`) if the merge is clean or only submodule-pointer conflicts exist.
#
# Returns:
#   0 on success; 1 on failure.
#-----------------------------------------
execute_merge_request() {
  local source_branch="$1"
  local target_branch="$2"
  local title="$3"
  local wait_time="$4"

  local branch_created=0  # Flag to track if the target branch was just created
  local previous_branch
  previous_branch=$(git rev-parse --abbrev-ref HEAD)  # Save current branch

  # Check if the target branch exists in the remote repository
  # echo Checking if $target_branch exists...
  if ! git ls-remote --exit-code --heads origin "$target_branch" > /dev/null 2>&1; then
    ### for debugging
    git ls-remote --exit-code --heads origin "$target_branch" || true
    ###
    echo -e "${YELLOW}Target branch $target_branch does not exist. Creating it from $source_branch...${NC}"

    # Create the target branch locally from the source branch
    git checkout --quiet "$source_branch"
    git checkout --quiet -b "$target_branch"
    git_push --set-upstream origin "$target_branch" || return 1

    echo -e "${GREEN}Successfully created and pushed branch $target_branch from $source_branch.${NC}"
    branch_created=1  # Mark that we just created the branch
  fi

  # If the target branch was just created, skip the pull request
  if [ "$branch_created" -eq 1 ]; then
    echo -e "${YELLOW}Skipping pull request since $target_branch was just created from $source_branch.${NC}"
    git checkout --quiet "$previous_branch"  # Restore original branch
    return 0
  fi

  echo
  echo -e "${YELLOW}Checking merge viability between $source_branch and $target_branch...${NC}"

  # Ensure we have the latest updates for source and target branches
  git checkout --quiet "$source_branch"
  git pull --quiet
  git fetch --quiet origin "$target_branch"    # <- ensure target is up-to-date

  # Definitive check: is source actually ahead of target?
  # Format: "behind ahead" (target behind source, source ahead of target)
  local behind ahead
  read behind ahead < <(git rev-list --left-right --count "origin/$target_branch...origin/$source_branch")
  if [[ "${ahead:-0}" -eq 0 ]]; then
    echo -e "${YELLOW}No changes detected in $source_branch relative to $target_branch (ahead=$ahead). Skipping pull request.${NC}"
    git checkout --quiet "$previous_branch"
    return 0
  fi

  # Create a temporary test merge branch (delete if it already exists)
  local temp_merge_branch="merge_test_${source_branch}_to_${target_branch}"
  git branch --quiet -D "$temp_merge_branch" >/dev/null 2>&1 || true
  git checkout --quiet -b "$temp_merge_branch" "origin/$target_branch"
  TEMP_BRANCHES+=("$temp_merge_branch")

  # Attempt to merge the source branch into the target branch quietly
  if ! git merge --no-commit --no-ff "origin/$source_branch" ; then
    echo -e "${YELLOW}Merge conflicts detected between $source_branch and $target_branch.. Checking if they are only submodule pointers...${NC}"

    # Get list of conflicting files
    local conflict_files non_submodule_conflicts
    conflict_files=$(git diff --name-only --diff-filter=U)
    non_submodule_conflicts=$(echo "$conflict_files" | grep -vE '^extern/[^/]+(/[^/]+)?$' || true)

    if [[ -n "$non_submodule_conflicts" ]]; then
      echo -e "${RED}Merge has conflicts outside submodules. Pull request will not be created.${NC}"
      echo
      echo -e "${YELLOW}Conflicting files:${NC}"
      echo "$conflict_files"
      git merge --abort
      git checkout --quiet "$previous_branch"
      git branch --quiet -D "$temp_merge_branch"
      return 1
    else
      echo -e "${GREEN}Only submodule pointer conflicts detected. Safe to ignore due to .gitattributes.${NC}"
    fi
  fi

  echo -e "${GREEN}Local merge test successful. Proceeding with create pull request...${NC}"
  echo
  git checkout --quiet "$previous_branch"
  git branch --quiet -D "$temp_merge_branch"

  # Now, create the pull request
  local pr_number
  pr_number=$(create_merge_request "$source_branch" "$target_branch" "$title" | tr -d '\n')
  # Our return code check isn't always working, so also check if we have a pr_number
  if [ $? -ne 0 ] || [ -z "$pr_number" ]; then
    echo -e "${RED}Error: Pull Request creation failed for merging $source_branch into $target_branch.${NC}"
    return 1
  fi

  echo "Waiting up to $wait_time seconds for pull request $pr_number to become mergeable..."
  wait_until_mergeable "$pr_number" "$wait_time"
  local ret=$?

  # Leave these as if statements.  It is clearer that way
  if [ $ret -ne 0 ]; then
    echo -e "${RED}Timeout or error waiting for pull request $pr_number to become mergeable.${NC}"
    return 1
  fi

  # Decide whether to delete the source branch
  if [[ "$source_branch" == "$RELEASE_CANDIDATE_BRANCH" || "$source_branch" == "$RELEASE_BRANCH" ]]; then
    trigger_merge "$pr_number" false
  else
    trigger_merge "$pr_number" true
  fi
  if [ $? -ne 0 ]; then
    echo -e "${RED}Merge trigger failed for PR $pr_number.${NC}"
    return 1
  fi

  poll_merge_status "$pr_number"
  return 0
}

#-----------------------------------------
# Function: get_next_rc_number
# Determines the next available release-candidate (rcX) number.
#
# Arguments:
#   $1 - Release number (e.g., "10.2")
#
# Behavior:
#   - Lists existing Git tags matching the pattern "<release_number>-rcX".
#   - Extracts the numeric portion (X) from those tags.
#   - Finds the highest existing rc number and increments it.
#   - If no matching tags exist, starts at "rc1".
#
# Returns:
#   The next available release candidate tag (e.g., "10.2-rc1", "10.2-rc2").
#-----------------------------------------
get_next_rc_number() {
  local release_number="$1"  # e.g., "10.2"

  # Update our local tags
  git fetch --tags --prune --prune-tags

  # List tags, filter for those matching "<release_number>-rcX", extract the X part
  local highest_rc
  highest_rc=$(git tag | grep -E "^${release_number}-rc[0-9]+$" | sed -E "s/^${release_number}-rc([0-9]+)$/\1/" | sort -nr | head -n1)

  # Determine the next rc number
  if [[ -z "$highest_rc" ]]; then
    echo "${release_number}-rc1"
  else
    local next_rc=$((highest_rc + 1))
    echo "${release_number}-rc${next_rc}"
  fi
}

#-----------------------------------------
# Function: generate_changelog
# Generates a changelog for the upcoming release by listing commit
# messages between the most recent official (previous) tag and HEAD.
#
# Behavior:
#   - Finds the most recent tag that follows the format "X.Y" (e.g., "10.2"),
#     excluding pre-release tags like "10.2-rc1".
#   - If a previous tag is found, sets the commit range as "previous_tag..HEAD".
#     Otherwise, uses HEAD as the range.
#   - Retrieves commit messages (excluding merge commits) in reverse chronological order.
#   - Ensures that the 'changelogs' directory exists in the script's original execution location.
#   - Extracts the last segment of <REPO_PROJECT> (after the last '/') for the filename.
#   - Outputs the changelog to "changelogs/<last_part_of_repo_project>_<RELEASE_NUMBER>_changelog.txt".
#
# Returns:
#   0 on success.
#-----------------------------------------
generate_changelog() {
  # Find the most recent official release tag (numbers and dots only, no rc/beta/etc.)
  local previous_tag
  previous_tag=$(git tag | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -n1)

  local commit_range
  if [ -n "$previous_tag" ]; then
    commit_range="${previous_tag}..HEAD"
  else
    commit_range="HEAD"
  fi

  # Get the date and time of the HEAD commit
  local head_date
  head_date=$(git log -1 --pretty=format:'%ad' --date='format:%Y-%m-%d %H:%M:%S' HEAD)

  # Extract the last part of REPO_PROJECT (everything after the last '/')
  local repo_name
  repo_name=$(basename "$REPO_PROJECT")

  # Ensure the changelogs directory exists in the script's original execution location
  local changelog_dir="${SCRIPT_DIR}/changelogs"
  mkdir -p "$changelog_dir"

  # Define the output file path
  local changelog_file="${changelog_dir}/${repo_name}_${RELEASE_NUMBER}_changelog.txt"

  # Print header for the upcoming release into the changelog file (single line)
  printf "## Changelog for %s %s (%s)\n\n" "$REPO_PROJECT" "$RELEASE_NUMBER" "$head_date" > "$changelog_file"

  # Append the commit messages (excluding merge commits) to the changelog file
  git log $commit_range --oneline --reverse | grep -v Merge >> "$changelog_file"

  echo -e "${GREEN}Changelog saved to $changelog_file${NC}"
  return 0
}

#-----------------------------------------
# Function: process_submodules
# Processes all submodules in the repository.
#
# Arguments:
#   $1 - Target branch (e.g., "$RELEASE_CANDIDATE_BRANCH", "development", or "$RELEASE_BRANCH")
#
# Behavior:
#   - Iterates over all submodules.
#   - Uses the same branch as the parent's target branch.
#   - Checks out each valid submodule to that branch and updates it.
#   - Creates a temporary branch in the parent repository for submodule updates and triggers a merge request.
#-----------------------------------------
process_submodules() {
  local target_branch="$1"

  echo -e "${GREEN}Processing all submodules for target branch: $target_branch${NC}"

  echo "------------------------------------------------------------"
  echo " Submodule Processing Required "
  echo "------------------------------------------------------------"
  echo
  echo "This repository has submodules that must be updated, committed,"
  echo "and pushed before proceeding with the release process."
  echo
  echo "Please perform the following manually:"
  echo "  1. Enter each submodule directory."
  echo "  2. Checkout or update to the correct branch/tag."
  echo "  3. Commit any changes in the submodule."
  echo "  4. Push those commits to the remote."
  echo "  5. Update the submodule reference in the parent repo and commit it."
  echo
  echo "When all submodules are ready and committed in the parent repo,"
  echo "return here to continue."
  echo

  # Wait for user confirmation
  while true; do
    read -r -p "Have you finished handling all submodules? (Y to continue, N to abort): " ans
    case "$ans" in
      [Yy]* )
        echo "Continuing with release process..."
        echo "Running recursive submodule update to ensure all submodules are in sync..."
        git submodule update --init --recursive
        echo -e "${GREEN}Submodules updated successfully.${NC}"
        return 0
        ;;
      [Nn]* )
        echo "Aborting as requested."
        return 1
        ;;
      * )
        echo "Please answer Y or N."
        ;;
    esac
  done


}

#-----------------------------------------
# Function: process_repo
# Processes a single repository given its directory, a base release number and release notes.
#
# For RC releases the base number is processed through get_next_rc_number so that RELEASE_NUMBER
# is set (e.g. “10.2-rc1” or “10.2-rc2”). Then, if RELEASE_NUMBER ends with "-rc1" (or if the release
# is OFFICIAL), the script creates an initial merge request from the source branch to the target
# branch. For subsequent RC releases (i.e. not candidate 1), the initial merge is skipped
# (assuming the target branch already has all required changes).  Tagging/release creation still occurs
#
# Arguments:
#   $1 - Repository directory
#   $2 - Base release number (e.g., "1.2")
#   $3 - Release notes
#   $4 - (Optional) has_submodules flag
#-----------------------------------------
process_repo() {
  local repo_directory="$1"
  local base_release_number="$2"
  local release_notes="$3"
  local has_submodules="$4"

  local start_time
  start_time=$(date +"%Y-%m-%d %H:%M:%S")
  local start_seconds=$SECONDS  # Capture start time in seconds
  export start_seconds

  TEMP_BRANCHES=()

  echo "----------------------------------------------------------"

  local return_code=0  # Default to success
  local quit_requested=false  # Track if user chose Quit

  # Convert full path to tilde-prefixed path if it starts with $HOME
  if [[ $repo_directory == "$HOME"* ]]; then
    repo_directory_short="~${repo_directory#$HOME}"
  else
    repo_directory_short="$repo_directory"
  fi

  # Expand "~" to $HOME for the actual filesystem path
  if [[ $repo_directory == ~* ]]; then
    repo_directory="${repo_directory/#\~/$HOME}"
  fi

  # If the directory doesn't exist, record a FAILED status and continue
  if [[ ! -d "$repo_directory" ]]; then
    echo -e "${RED}Path does not exist:${NC} $repo_directory"
    # Record a failed entry so the summary table isn't empty
    repo_status["$repo_directory_short"]="$RELEASE_NUMBER | FAILED | 0s | (no repo)"
    repo_order+=("$repo_directory_short")
    return 1
  fi

  # Always cd into the repository before any gh/git calls
  if ! cd "$repo_directory"; then
    echo "Cannot cd to $repo_directory"
    # Record a failed entry so the summary table isn't empty
    repo_status["$repo_directory_short"]="$RELEASE_NUMBER | FAILED | 0s | (cd failed)"
    repo_order+=("$repo_directory_short")
    return 1
  fi

  # Set the global RELEASE_NUMBER based on RELEASE_TYPE
  if [ "$RELEASE_TYPE" = "RC" ]; then
    RELEASE_NUMBER=$(get_next_rc_number "$base_release_number")
  else
    RELEASE_NUMBER="$base_release_number"
  fi
  export RELEASE_NUMBER

  # We echo here so we can show the full release number.  So technically, we are missing out the timing for the get_next_rc_number
  echo -e "$start_time ${GREEN}Processing repository: $repo_directory (Release: $RELEASE_NUMBER)${NC}"
  echo

  # --- PR MODE: create a branch ngwpc-<release> based on $RELEASE_BRANCH and exit ---
  if [ "$RELEASE_TYPE" = "PR" ]; then
    local new_branch="ngwpc-$base_release_number"

    echo -e "${GREEN}PR mode: Creating branch $new_branch from $RELEASE_BRANCH...${NC}"

    git fetch --quiet origin "$RELEASE_BRANCH"
    git checkout --quiet -b "$new_branch" "origin/$RELEASE_BRANCH"

    if git_push --set-upstream origin "$new_branch"; then
      echo -e "${GREEN}Created and pushed $new_branch successfully.${NC}"
    else
      echo -e "${RED}Failed to push $new_branch.${NC}"
      return 1
    fi

    # Nothing else to do for PR mode
    return 0
  fi


  echo -e "${YELLOW}Proceed with processing this repository? (C)ontinue, (S)kip, (Q)uit [default: C in 60s]:${NC}"
  read -t 60 -n 1 -s -r user_input
  echo

  # Default to Continue if no input is provided
  user_input="${user_input:-C}"
  user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]')

  case "$user_input" in
    Q)
      echo -e "${RED}Quit requested. Will exit after summary.${NC}"
      quit_requested=true
      ;;
    S)
      echo -e "${YELLOW}Skipping this repository.${NC}"
      return 1
      ;;
    C|*)
      echo -e "${GREEN}Continuing with $repo_directory...${NC}"
      ;;
  esac

  # Get the remote URL.
  repo_remote=$(git remote get-url origin)

  # Derive the canonical "owner/repo" once and use it everywhere.
  REPO_PROJECT=$(clean_and_encode_project "$repo_remote")

  echo "Remote URL: $repo_remote"

  # Ensure cleanup_repo always runs when this function returns
  trap "cleanup_repo '$REPO_PROJECT' '$repo_directory_short'; trap - RETURN; if [ \"$quit_requested\" = true ]; then exit 2; fi" RETURN


  # Ensure gh is operating on this repo (sanity)
  if ! run_gh repo view >/dev/null 2>&1; then
    echo -e "${RED}gh cannot determine repository context in $repo_directory. Is this a GitHub repo and are you authenticated?${NC}"
    return_code=1
    return
  fi

  # Fetch the list of tags from the remote repository and check if the release tag already exists.
  local remote_tags
  remote_tags=$(git ls-remote --tags origin | awk '{print $2}' | sed 's#refs/tags/##')
  if echo "$remote_tags" | grep -Fxq "$RELEASE_NUMBER"; then
    echo -e "${RED}Tag '$RELEASE_NUMBER' already exists in the remote repository. Please choose a different release number.${NC}"
    return_code=1
    return
  fi

  # Determine source and target branches *before* handling submodules
  local SOURCE_BRANCH TARGET_BRANCH
  if [ "$RELEASE_TYPE" = "RC" ]; then
    SOURCE_BRANCH="development"
    TARGET_BRANCH="$RELEASE_CANDIDATE_BRANCH"
  else
    SOURCE_BRANCH="$RELEASE_CANDIDATE_BRANCH"
    TARGET_BRANCH="$RELEASE_BRANCH"
  fi

  echo -e "Source branch: ${GREEN}$SOURCE_BRANCH${NC}"
  echo -e "Target branch: ${GREEN}$TARGET_BRANCH${NC}"

  echo -e "Pulling latest updates for branch ${GREEN}${SOURCE_BRANCH}${NC}..."
  git checkout --quiet "$SOURCE_BRANCH" && git pull --quiet

  # Perform the merge request for the initial RC1 or Official release
  if [ "$RELEASE_TYPE" = "OFFICIAL" ] || [[ "$RELEASE_NUMBER" =~ -rc1$ ]]; then
    if ! execute_merge_request "$SOURCE_BRANCH" "$TARGET_BRANCH" \
         "Merge $SOURCE_BRANCH into $TARGET_BRANCH for release $RELEASE_NUMBER" "$WAIT_TIME"; then
      return_code=1
      return
    fi
  else
    # For subsequent RC releases, we assume that TARGET_BRANCH already has all needed changes.
    echo -e "${YELLOW}Subsequent RC (> RC1) release detected. Skipping merge from $SOURCE_BRANCH.${NC}"
  fi

  # Pull the latest updates for the target branch.
  echo -e "Pulling latest updates for branch ${GREEN}$TARGET_BRANCH${NC}..."
  git checkout --quiet "$TARGET_BRANCH" && git pull --quiet
  echo

  if [ "$has_submodules" = "true" ]; then
    echo Calling process_submodules for $TARGET_BRANCH
    process_submodules "$TARGET_BRANCH"
  fi

  # Create changelog for OFFICIAL releases
  if [ "$RELEASE_TYPE" = "OFFICIAL" ]; then
    echo
    # Generate the changelog for the current release tag.
    echo "Generating changelog for tag $RELEASE_NUMBER:"
    generate_changelog
  fi

  # Create GitHub release
  echo -e "${GREEN}Creating GitHub release for $REPO_PROJECT $RELEASE_NUMBER...${NC}"
  if ! create_release "$RELEASE_NUMBER" "Release $RELEASE_NUMBER" "$release_notes" "$TARGET_BRANCH"; then
    echo -e "${RED}Error: GitHub release creation for $REPO_PROJECT $RELEASE_NUMBER failed.${NC}"
    return_code=1
    return
  fi

  # Merge the target branch back to development only for RC releases that are not -rc1
  if [[ "$RELEASE_TYPE" == "RC" && ! "$RELEASE_NUMBER" =~ -rc1$ ]]; then
    # Even if merge request fails, we continue
    execute_merge_request "$TARGET_BRANCH" "development" \
      "Merge $TARGET_BRANCH into development for release $RELEASE_NUMBER" "$WAIT_TIME"
  fi

  # If submodules exist, set all submodules to development
  if [ "$has_submodules" = "true" ]; then
    echo Setting submodules to development
    process_submodules "development"
  fi

  echo -e "Pulling latest updates for branch ${GREEN}${SOURCE_BRANCH}${NC}"
  git checkout --quiet "$SOURCE_BRANCH" && git pull --quiet
  echo

  if [ "$SOURCE_BRANCH" != "development" ]; then
    echo -e "Pulling latest updates for branch ${GREEN}development${NC}..."
    git checkout --quiet development && git pull --quiet
    echo
  fi

  echo -e "Pulling latest updates for branch ${GREEN}$TARGET_BRANCH${NC}..."
  git checkout --quiet "$TARGET_BRANCH" && git pull --quiet
  echo

  return "$return_code"
}

#-----------------------------------------
# Function: cleanup_repo
# Cleans up temporary branches and logs the processing status for the current repository.
#
# Behavior:
#   - Checks out the 'development' branch and pulls the latest changes.
#   - Retrieves the latest commit hash for the repository.
#   - Records the release number, processing status (SUCCESS or FAILED), elapsed time,
#     and commit hash in a global associative array.
#   - Iterates through the TEMP_BRANCHES array, deleting each temporary branch locally
#     and remotely (if it exists).
#   - Adds the repository to a global order list and prints a final message with the elapsed time.
#   - Sets a global return code variable (GLOBAL_RETURN_CODE) to reflect the overall status.
#-----------------------------------------
cleanup_repo() {
  local repo_project="$1"   # e.g., owner/repo
  local repo_short="$2"     # the "~..." path you passed in trap

  local exit_code=$return_code  # Preserve the return code
  local end_time
  end_time=$(date +"%Y-%m-%d %H:%M:%S")
  local elapsed_seconds=$(( SECONDS - start_seconds ))

  # Park on development to avoid detached state surprises
  git checkout --quiet development && git pull --quiet

  # Retrieve the latest commit hash for the release
  local latest_commit_hash
  latest_commit_hash=$(git rev-parse HEAD)

  # Store status, elapsed time, and commit hash in the global array
  local status="FAILED"
  if [ "$return_code" -eq 0 ]; then
    status="SUCCESS"
  fi

  # Key by the short path you passed in
  repo_status["$repo_short"]="$RELEASE_NUMBER | $status | ${elapsed_seconds}s | $latest_commit_hash"

  # Iterate through TEMP_BRANCHES and delete them
  for temp_branch in "${TEMP_BRANCHES[@]}"; do
    # Local: match either "* " (current) or "  " (not current) then the exact branch name
    if git branch --list | grep -qE "^[* ]\s*${temp_branch}$"; then
      echo "Deleting local branch: $temp_branch"
      git branch -D "$temp_branch" >/dev/null 2>&1 || true
    fi

    # Remote
    if git ls-remote --heads origin "$temp_branch" | grep -q "$temp_branch"; then
      echo "Deleting remote branch: $temp_branch"
      git_push origin --delete "$temp_branch" || true
    fi
  done

  repo_order+=("$repo_short")
  echo -e "$end_time ${GREEN}Finished processing: $repo_project ($repo_short)${NC} (Elapsed time: $elapsed_seconds seconds)"

  # Simply returning the return code doesn't see to work.  Need to use a global variable.  It might be Trap that is getting in the way
  GLOBAL_RETURN_CODE=$exit_code  # Set the global return code instead of returning
}

# Summary function to print repo statuses

# Global associative array to store repository status
declare -A repo_status
# Global array to store repository order
repo_order=()

print_summary() {
  local longest_repo_name=0
  local total_elapsed_seconds=$(( SECONDS - ${total_seconds:-$SECONDS} ))

  # Determine the longest repository name from the repo_order array
  for repo in "${repo_order[@]}"; do
    if (( ${#repo} > longest_repo_name )); then
      longest_repo_name=${#repo}
    fi
  done

  # Column widths
  local repo_column_width=$((longest_repo_name + 2)) # Add extra padding
  local release_column_width=15
  local status_column_width=10
  local time_column_width=6
  local commit_column_width=40 # Adjust based on hash length
  local total_width=$((repo_column_width + release_column_width + status_column_width + time_column_width + commit_column_width + 13))

  # Define summary file path
  local summary_file="${SCRIPT_DIR}/release_summary.txt"

  # Print header to console and file
  printf "\n%-${repo_column_width}s | %-${release_column_width}s | %-${status_column_width}s | %-${time_column_width}s | %-${commit_column_width}s\n" \
    "Repository" "Release" "Status" "Time" "Commit Hash" | tee "$summary_file"
  printf -- "%-${total_width}s\n" | tr ' ' '-' | tee -a "$summary_file"

  # Print repository details in the order they were processed
  for repo in "${repo_order[@]}"; do
    IFS='|' read -r release status time commit_hash <<< "${repo_status[$repo]}"
    printf "%-${repo_column_width}s | %-15s | %-10s | %-6s | %-40s\n" \
      "$repo" "$release" "$status" "$time" "$commit_hash" | tee -a "$summary_file"
  done

  # Print footer
  printf -- "%-${total_width}s\n" | tr ' ' '-' | tee -a "$summary_file"
  echo "All repositories processed (Total elapsed time: ${total_elapsed_seconds} seconds)." | tee -a "$summary_file"

  echo -e "${GREEN}Summary saved to: ${summary_file}${NC}"
}

#-----------------------------------------
# Function: main
# Prompts for the release type, displays a list of repositories that will be processed
# (marking those with the skip flag), and asks the user to confirm whether to continue.
# Then, it loops through the JSON file and processes each repository that is not skipped.
#-----------------------------------------
main() {
  total_seconds=$SECONDS  # start of the whole process
  # Remember where we were executed from
  SCRIPT_DIR="$(pwd)"

  # Check for help option
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "?" ]]; then
    usage
  fi

  # Parse other command line arguments
  if [ -n "$1" ]; then
    RELEASE_TYPE="$1"
    RELEASE_TYPE=$(echo "$RELEASE_TYPE" | tr '[:lower:]' '[:upper:]')
  else
    echo "Enter release type (OFFICIAL or RC):"
    read -r RELEASE_TYPE
    RELEASE_TYPE=$(echo "$RELEASE_TYPE" | tr '[:lower:]' '[:upper:]')
  fi

  if [[ "$RELEASE_TYPE" != "OFFICIAL" && "$RELEASE_TYPE" != "RC" && "$RELEASE_TYPE" != "PR" ]]; then
    echo -e "${RED}Invalid release type. Must be either OFFICIAL or RC.${NC}"
    echo
    usage
    exit 1
  fi

  # Second argument: JSON file name (default if not provided)
  json_file="${2:-createReleaseConfig.json}"
  if [ ! -f "$json_file" ]; then
    echo -e "${RED}JSON file $json_file not found.${NC}"
    echo
    usage
    exit 1
  fi

  # Validate JSON before doing anything else
  if ! jq empty "$json_file" >/dev/null 2>&1; then
    echo -e "${RED}Error: JSON file '$json_file' is invalid and could not be parsed.${NC}"
    echo -e "${YELLOW} jq reported a syntax error. Fix the JSON and try again.${NC}"
    exit 1
  fi


  # Third argument: wait time for mergeable check (default to 1 minute)
  WAIT_TIME="${3:-60}"
  echo "Wait time for merges is $WAIT_TIME seconds"

  echo -e "${GREEN}Reading from $json_file${NC}"
  echo

  # Ensure gh is installed/authed
  if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}The GitHub CLI (gh) is not installed. Please install and run 'gh auth login'.${NC}"
    exit 1
  fi
  # Status is informational; use wrapper for consistent "Executing:" line (may be redirected away).
  run_gh auth status || true

  # Read JSON data once and display the list of repos that will be processed
  json_data=$(cat "$json_file")
  repo_count=$(echo "$json_data" | jq length)

  echo -e "${GREEN}The following repositories will be processed:${NC}"
  for (( i=0; i<repo_count; i++ )); do
    repo_directory=$(echo "$json_data" | jq -r ".[$i].repo_directory")
    release=$(echo "$json_data" | jq -r ".[$i].release")
    # Read the skip flag (default to false)
    skip=$(echo "$json_data" | jq -r ".[$i].skip // false")

    display_dir="$repo_directory"
    resolved_dir="$repo_directory"
    if [[ $resolved_dir == ~* ]]; then
      resolved_dir="${resolved_dir/#\~/$HOME}"
    fi
    exists_note=""
    if [[ ! -d "$resolved_dir" ]]; then
      exists_note=" ${RED}(missing)${NC}"
    fi

    if [ "$skip" = "true" ]; then
      echo -e "${YELLOW}Repo: $display_dir (Release: $release) (skipping)${NC}${exists_note}"
    else
      echo -e "${GREEN}Repo: $display_dir (Release: $release)${NC}${exists_note}"
    fi
  done

  echo
  echo -n "Proceed with processing these repositories? (Y/N): "
  read -r confirm
  confirm=$(echo "$confirm" | tr '[:lower:]' '[:upper:]')
  if [ "$confirm" != "Y" ]; then
    echo "Aborting."
    exit 0
  fi

  # Loop through each repository and process it (skip if flag is true)
  for (( i=0; i<repo_count; i++ )); do
    repo_directory=$(echo "$json_data" | jq -r ".[$i].repo_directory")
    release=$(echo "$json_data" | jq -r ".[$i].release")

    release_notes=$(echo "$json_data" | jq -r ".[$i].release_notes")
    has_submodules=$(echo "$json_data" | jq -r ".[$i].has_submodules // false")  # Default to false
    skip=$(echo "$json_data" | jq -r ".[$i].skip // false")  # Default to false

    # Expand tilde if present.
    if [[ $repo_directory == ~* ]]; then
      repo_directory="${repo_directory/#\~/$HOME}"
    fi

    if [ "$skip" = "true" ]; then
      echo -e "${YELLOW}Skipping repository: $repo_directory (Release: $release)${NC}"
      continue
    fi

    process_repo "$repo_directory" "$release" "$release_notes" "$has_submodules"

    # If user selected Quit, exit the loop
    if [ "$GLOBAL_RETURN_CODE" -eq 2 ]; then
      echo "User chose to quit. Exiting script."
      break
    fi
  done

  print_summary
}

main "$@"

