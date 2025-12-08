#!/bin/bash

set -e
set -o pipefail

# ==============================================================================
# NGEN/NGENCERF Build Script
# ==============================================================================
#
# This script builds and symlinks Singularity containers for selected NGEN repos.
# It supports both interactive use and non-interactive (automated) use via CLI.
#
# ------------------------------------------------------------------------------
# USAGE EXAMPLES
# ------------------------------------------------------------------------------
#
# Interactive mode (will prompt for build type, repos, and optional per-repo source):
#   ./build_cluster.sh
#
# Development build (non-interactive, builds ngen and nwm-cal-mgr):
#   ./build_cluster.sh --build-type=development ngen nwm-cal-mgr
#
# Build all supported repos (non-interactive):
#   ./build_cluster.sh --build-type=development all
#
# Build for release (will still prompt for tags):
#   ./build_cluster.sh --build-type=release ngen nwm-cal-mgr nwm-verf
#
# Feature build (mirrors development but uses the feature branch
# and tags images as :feature):
#   ./build_cluster.sh --build-type=feature ngen nwm-cal-mgr
#
# Per-repo image source (build|pull), applies to dev/rc/release:
#   ./build_cluster.sh --build-type=development \
#     --source=ngen:build --source=nwm-cal-mgr:build ngen nwm-cal-mgr
#   ./build_cluster.sh --build-type=release \
#     --source-default=build ngen nwm-cal-mgr ngen-forcing nwm-fcst-mgr nwm-verf
#
# ------------------------------------------------------------------------------
# ARGUMENTS
# ------------------------------------------------------------------------------
#
#   --build-type=TYPE        One of: development, release, feature
#   --source=REPO:MODE       For REPO in {ngen, nwm-cal-mgr, ngen-forcing, nwm-verf, nwm-fcst-mgr},
#                            MODE is build or pull. Can be repeated.
#   --source-default=MODE    Global default (build|pull) for the above repos (optional).
#   --branch=BRANCH         Specify a custom branch to build from (optional).
#   --tag=REPO:TAG          For feature builds: specify tag to pull for REPO (only used when pulling).
#                            Example: --tag=ngen-forcing:latest
#   repo names               List of repos to build (space-separated), or use "all"
#
# Supported repos:
#   ngencerf-server, ngencerf-ui, ngencerf-docker, ngen, nwm-cal-mgr, ngen-forcing,
#   nwm-fcst-mgr, nwm-verf
#
# Notes:
# - If no arguments are passed, the script runs interactively.
# - If "all" is passed as a repo, it expands to all supported repos.
# - For release, tag prompts will appear.
#
# ==============================================================================

# --- BASE DIRECTORY SETUP (paths only, actual creation happens after arg parsing) ---
BASE_PATH="/ngencerf-app"
SINGULARITY_DIR="${BASE_PATH}/singularity"

# Branch selection for building - now per-repo
declare -A REPO_BRANCHES   # map: repo -> branch
BRANCH_DEFAULT=""          # global default branch (optional)

REPOS=(
    "ngencerf-ui"
    "ngencerf-server"
    "ngencerf-docker"
    "ngen"
    "nwm-cal-mgr"
    "ngen-forcing"
    "nwm-fcst-mgr"
    "nwm-verf"
)
REGISTRY="ghcr.io/ngwpc"

BUILD_TYPE=""
SELECTED_REPOS=()

# repos with selectable image source (build vs pull)
TARGET_REPOS_FOR_SOURCE=("ngen" "nwm-cal-mgr" "ngen-forcing" "nwm-verf" "nwm-fcst-mgr")
declare -A IMAGE_SOURCE   # map: repo -> build|pull
IMAGE_SOURCE_DEFAULT=""

# Dependency image tags for build arguments
declare -A DEPENDENCY_TAGS  # map: dependent_repo -> dependency_tag
# e.g., DEPENDENCY_TAGS["ngen"]="feature"  # ngen will use ngen-forcing:feature
#       DEPENDENCY_TAGS["nwm-cal-mgr"]="v1.0"  # nwm-cal-mgr will use ngen:v1.0

# map repo -> "docker_image|sif_name" (space-separated for multiples)
images_for_repo() {
    local repo="$1"
    case "$repo" in
        ngen)            echo "ngen|ngen" ;;
        ngencerf-ui)     echo "" ;;
        ngencerf-server) echo "" ;;
        ngencerf-docker) echo "" ;;
        nwm-cal-mgr)     echo "nwm-cal-mgr|nwm-cal-mgr" ;;
        ngen-forcing)    echo "ngen-bmi-forcing|ngen-bmi-forcing ngen-lumped-forcing|ngen-lumped-forcing ngen-coastal|ngen-coastal" ;;
        nwm-fcst-mgr)    echo "nwm-fcst-mgr|nwm-fcst-mgr" ;;
        nwm-verf)        echo "nwm-verf|nwm-verf" ;;
        *)               echo "$repo|$repo" ;;
    esac
}

# function to determine if a repo has an associated SIF to build
repo_has_sif() {
    case "$1" in
        ngencerf-server|ngencerf-ui|ngencerf-docker) return 1 ;;
        *) return 0 ;;
    esac
}

# set workflow (build or pull) default for repos with SIF (overridden by --source-default/--source)
set_image_source_defaults() {
    # initialize all to empty
    for r in "${TARGET_REPOS_FOR_SOURCE[@]}"; do IMAGE_SOURCE["$r"]=''; done

    # set default for each repo
    IMAGE_SOURCE["ngen"]="pull"
    IMAGE_SOURCE["nwm-cal-mgr"]="build"
    IMAGE_SOURCE["nwm-fcst-mgr"]="build"
    IMAGE_SOURCE["nwm-verf"]="build"
    IMAGE_SOURCE["ngen-forcing"]="pull"

    if [[ -n "$IMAGE_SOURCE_DEFAULT" ]]; then
        for r in "${TARGET_REPOS_FOR_SOURCE[@]}"; do IMAGE_SOURCE["$r"]="$IMAGE_SOURCE_DEFAULT"; done
    fi
}

# --- Help function ---
show_help() {
    cat <<'EOF'
NGEN/NGENCERF Build Script

This script builds and symlinks Singularity containers for selected NGEN repos.
It supports both interactive use and non-interactive (automated) use via CLI.

USAGE:
  ./build_cluster.sh [OPTIONS] [REPOS...]

OPTIONS:
  --build-type=TYPE          One of: development, release, feature
  --branch=REPO:BRANCH       Specify a branch for a specific repo. Can be repeated.
                             Example: --branch=ngen:feature/my-feature
  --branch-default=BRANCH    Global default branch for all repos (optional)
  --source=REPO:MODE         For REPO in {ngen, nwm-cal-mgr, ngen-forcing, nwm-verf, nwm-fcst-mgr},
                             MODE is build or pull. Can be repeated.
  --source-default=MODE      Global default (build|pull) for the above repos (optional)
  --tag=REPO:TAG             For feature builds: specify tag to pull for REPO (only used when pulling).
                             Example: --tag=ngen-forcing:latest
  --ngen-forcing-tag=TAG     For feature builds: specify ngen-forcing tag for ngen to use as build arg
  --ngen-tag=TAG             For feature builds: specify ngen tag for nwm-cal-mgr/nwm-fcst-mgr to use
  --help, -h                 Show this help message and exit

REPOS:
  Supported repos: ngencerf-server, ngencerf-ui, ngencerf-docker, ngen, nwm-cal-mgr,
                   ngen-forcing, nwm-fcst-mgr, nwm-verf
  Use "all" to build all supported repos

EXAMPLES:
  Interactive mode (will prompt for build type, repos, branches, and sources):
    ./build_cluster.sh

  Development build with default branches:
    ./build_cluster.sh --build-type=development ngen nwm-cal-mgr

  Development build with custom branches per repo:
    ./build_cluster.sh --build-type=development \
      --branch=ngen:feature/new-hydro --branch=nwm-cal-mgr:bugfix/123 \
      ngen nwm-cal-mgr

  Development build with global default branch:
    ./build_cluster.sh --build-type=development --branch-default=my-feature \
      ngen nwm-cal-mgr ngen-forcing

  Build all repos with custom branch and source options:
    ./build_cluster.sh --build-type=development \
      --branch-default=feature/test \
      --branch=ngen:main \
      --source=ngen:pull --source-default=build \
      all

  Build for release (will still prompt for tags):
    ./build_cluster.sh --build-type=release ngen nwm-cal-mgr nwm-verf

  Feature build:
    ./build_cluster.sh --build-type=feature ngen nwm-cal-mgr

  Feature build with custom dependency tags:
    ./build_cluster.sh --build-type=feature \
      --ngen-forcing-tag=latest --ngen-tag=development \
      --source=ngen:build --source=nwm-cal-mgr:build \
      ngen-forcing ngen nwm-cal-mgr

NOTES:
  - If no arguments are passed, the script runs interactively
  - If "all" is passed as a repo, it expands to all supported repos
  - For release builds, tag prompts will appear
  - Branch priority: --branch=REPO:BRANCH > --branch-default > build-type default
  - Logs are written to: ${SINGULARITY_DIR}/build_cluster_<timestamp>.log
EOF
}

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
            ;;
            --build-type=*)
                BUILD_TYPE="${1#*=}"
            ;;
            --build-type)
                shift; BUILD_TYPE="$1"
            ;;
            --branch=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local branch="${kv##*:}"
                if [[ ! " ${REPOS[*]} " =~ " ${repo} " ]]; then
                    echo "Error: --branch targets unsupported repo '${repo}'. Allowed: ${REPOS[*]}"; exit 1
                fi
                if [[ -z "$branch" ]]; then
                    echo "Error: --branch '${kv}' must specify a branch (format: REPO:BRANCH)"; exit 1
                fi
                REPO_BRANCHES["$repo"]="$branch"
            ;;
            --branch-default=*)
                BRANCH_DEFAULT="${1#*=}"
                if [[ -z "$BRANCH_DEFAULT" ]]; then
                    echo "Error: --branch-default requires a value"; exit 1
                fi
            ;;
            --branch-default)
                shift
                if [[ -z "$1" || "$1" == -* ]]; then
                    echo "Error: --branch-default requires a value"; exit 1
                fi
                BRANCH_DEFAULT="$1"
            ;;
            --source-default=*)
                IMAGE_SOURCE_DEFAULT="${1#*=}" # build|pull
                if [[ "$IMAGE_SOURCE_DEFAULT" != "build" && "$IMAGE_SOURCE_DEFAULT" != "pull" ]]; then
                    echo "Error: --source-default must be 'build' or 'pull', got '${IMAGE_SOURCE_DEFAULT}'"; exit 1
                fi
            ;;
            --source=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local mode="${kv##*:}"
                if [[ ! " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
                    echo "Error: --source targets unsupported repo '${repo}'. Allowed: ${TARGET_REPOS_FOR_SOURCE[*]}"; exit 1
                fi
                if [[ "$mode" != "build" && "$mode" != "pull" ]]; then
                    echo "Error: --source '${kv}' must be build or pull."; exit 1
                fi
                IMAGE_SOURCE["$repo"]="$mode"
            ;;
            --tag=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local tag="${kv##*:}"
                if [[ ! " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
                    echo "Error: --tag targets unsupported repo '${repo}'. Allowed: ${TARGET_REPOS_FOR_SOURCE[*]}"; exit 1
                fi
                if [[ -z "$tag" ]]; then
                    echo "Error: --tag '${kv}' must specify a tag (format: REPO:TAG)"; exit 1
                fi
                TAGS["$repo"]="$tag"
            ;;
            --ngen-forcing-tag=*)
                local tag="${1#*=}"
                if [[ -z "$tag" ]]; then
                    echo "Error: --ngen-forcing-tag requires a value"; exit 1
                fi
                DEPENDENCY_TAGS["ngen"]="$tag"
            ;;
            --ngen-tag=*)
                local tag="${1#*=}"
                if [[ -z "$tag" ]]; then
                    echo "Error: --ngen-tag requires a value"; exit 1
                fi
                DEPENDENCY_TAGS["nwm-cal-mgr"]="$tag"
                DEPENDENCY_TAGS["nwm-fcst-mgr"]="$tag"
            ;;
            -*)
                echo "Unknown option: $1"; exit 1
            ;;
            *)
                SELECTED_REPOS+=("$1")
            ;;
        esac
        shift
    done
}

parse_args "$@"

# validate BUILD_TYPE if provided via CLI
if [[ -n "$BUILD_TYPE" ]] && [[ "$BUILD_TYPE" != "development" ]] && [[ "$BUILD_TYPE" != "release" ]] && [[ "$BUILD_TYPE" != "feature" ]]; then
    echo "Error: Invalid --build-type '${BUILD_TYPE}'. Must be one of: development, release, feature"
    exit 1
fi

# validate that branch arguments are not used with development build type
if [[ "$BUILD_TYPE" == "development" ]]; then
    if [[ -n "$BRANCH_DEFAULT" ]]; then
        echo "Error: --branch-default cannot be used with --build-type=development"
        echo "Development builds always use the 'development' branch for all repos."
        exit 1
    fi
    if [[ ${#REPO_BRANCHES[@]} -gt 0 ]]; then
        echo "Error: --branch cannot be used with --build-type=development"
        echo "Development builds always use the 'development' branch for all repos."
        exit 1
    fi
fi

# validate dependency tags are only used with feature build type
if [[ ${#DEPENDENCY_TAGS[@]} -gt 0 && "$BUILD_TYPE" != "feature" ]]; then
    echo "Error: --ngen-forcing-tag and --ngen-tag can only be used with --build-type=feature"
    exit 1
fi

# --- Create directories and setup logging (after arg parsing to allow --help to work) ---
mkdir -p "$SINGULARITY_DIR"
LOGFILE="${SINGULARITY_DIR}/build_cluster_$(date -u +"%Y-%m-%dT%H:%M:%SZ").log"
exec > >(tee -i "$LOGFILE") 2>&1

# --- Interactive prompts if needed ---
if [[ -z "$BUILD_TYPE" && -t 0 ]]; then
    echo "Select build type:"
    echo "1) development"
    echo "2) release"
    echo "3) feature"
    read -p "Enter number [1-3]: " build_choice
    case $build_choice in
        1) BUILD_TYPE="development" ;;
        2) BUILD_TYPE="release" ;;
        3) BUILD_TYPE="feature" ;;
        *) echo "Invalid choice, exiting."; exit 1 ;;
    esac

fi

if [[ ${#SELECTED_REPOS[@]} -eq 0 && -t 0 ]]; then
    echo "Available repos: ${REPOS[*]}"
    read -p "Enter repos to build (space-separated from the list above, or press Enter for all): " -a SELECTED_REPOS
    # if user pressed Enter without typing anything, select all repos
    if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
        SELECTED_REPOS=("${REPOS[@]}")
        echo "All repos selected: ${SELECTED_REPOS[*]}"
    fi
fi

if [[ -z "$BUILD_TYPE" || ${#SELECTED_REPOS[@]} -eq 0 ]]; then
    echo "Error: build type and at least one repo must be provided."; exit 1
fi

set_image_source_defaults

# expand 'all'
if [[ " ${SELECTED_REPOS[*]} " =~ " all " ]]; then
    echo "'all' specified — building all available repos."
    SELECTED_REPOS=("${REPOS[@]}")
    echo "Repos to build: ${SELECTED_REPOS[*]}"
fi

# validate repos
INVALID_REPOS=()
for repo in "${SELECTED_REPOS[@]}"; do
    if [[ ! " ${REPOS[*]} " =~ " $repo " ]]; then
        INVALID_REPOS+=("$repo")
    fi
done
if [[ ${#INVALID_REPOS[@]} -gt 0 ]]; then
    echo "Error: Invalid repo(s): ${INVALID_REPOS[*]}"
    echo "Allowed repos are: ${REPOS[*]}"
    exit 1
fi

# display summary and optional interactive per-repo source/branch selection
echo "Build type selected: $BUILD_TYPE"
echo "Selected repos: ${SELECTED_REPOS[*]}"

if [[ -t 0 ]]; then
    for repo in "${SELECTED_REPOS[@]}"; do
        if [[ " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
            default_mode="${IMAGE_SOURCE[$repo]}"
            read -p "Image source for '${repo}' [build/pull] (default: ${default_mode}): " ans
            if [[ -n "$ans" ]]; then
                if [[ "$ans" != "build" && "$ans" != "pull" ]]; then
                    echo "Invalid choice '${ans}' for ${repo}. Use build or pull."; exit 1
                fi
                IMAGE_SOURCE["$repo"]="$ans"
            fi
        fi
    done

    # branch prompting after image sources (only for feature builds in interactive mode)
    if [[ "$BUILD_TYPE" == "feature" ]]; then
        for repo in "${SELECTED_REPOS[@]}"; do
            if [[ -z "${REPO_BRANCHES[$repo]:-}" ]]; then
                # special handling for ngen-forcing
                if [[ "$repo" == "ngen-forcing" ]]; then
                    read -p "Enter ngen-forcing branch (shared for bmi/lumped/coastal): " ans
                else
                    read -p "Enter ${repo} branch: " ans
                fi
                if [[ -n "$ans" ]]; then
                    REPO_BRANCHES["$repo"]="$ans"
                fi
            fi
        done
    fi
fi

# get the branch to use for a specific repo
# priority: REPO_BRANCHES[repo] > BRANCH_DEFAULT > build_type_default
get_repo_branch() {
    local repo="$1"
    local build_type_default="$2"

    # check if repo has specific branch set
    if [[ -n "${REPO_BRANCHES[$repo]:-}" ]]; then
        echo "${REPO_BRANCHES[$repo]}"
    # check if global default is set
    elif [[ -n "$BRANCH_DEFAULT" ]]; then
        echo "$BRANCH_DEFAULT"
    # fall back to build type default
    else
        echo "$build_type_default"
    fi
}

# prompt for dependency tags in interactive mode
prompt_dependency_tags() {
    local build_type="$1"

    # only applicable to feature and release builds
    [[ "$build_type" != "feature" && "$build_type" != "release" ]] && return 0
    [[ ! -t 0 ]] && return 0  # not interactive

    # check if ngen is selected or needed
    local ngen_selected=false
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        ngen_selected=true
    fi

    # check if nwm-cal-mgr or nwm-fcst-mgr is selected
    local mgr_selected=false
    if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]] || [[ " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
        mgr_selected=true
    fi

    # prompt for ngen-forcing tag if ngen is being built
    if [[ "$ngen_selected" == "true" ]]; then
        local default_tag="feature"
        if [[ -z "${DEPENDENCY_TAGS[ngen]:-}" ]]; then
            read -p "Which ngen-forcing Docker image tag do you want ngen to use? (default: ${default_tag}): " ans
            DEPENDENCY_TAGS["ngen"]="${ans:-$default_tag}"
        fi
    fi

    # prompt for ngen tag if nwm-cal-mgr or nwm-fcst-mgr is selected
    if [[ "$mgr_selected" == "true" ]]; then
        local default_tag="feature"
        if [[ -z "${DEPENDENCY_TAGS[nwm-cal-mgr]:-}" ]]; then
            read -p "Which ngen Docker image tag do you want nwm-cal-mgr/nwm-fcst-mgr to use? (default: ${default_tag}): " ans
            local tag="${ans:-$default_tag}"
            DEPENDENCY_TAGS["nwm-cal-mgr"]="$tag"
            DEPENDENCY_TAGS["nwm-fcst-mgr"]="$tag"
        fi
    fi

    # prompt for nwm-eval-mgr branch/tag if nwm-verf is selected
    if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-verf " ]]; then
        if [[ "$build_type" == "feature" ]]; then
            local default_branch="feature"
            if [[ -z "${DEPENDENCY_TAGS[nwm-verf]:-}" ]]; then
                read -p "Which nwm-eval-mgr branch do you want nwm-verf to use? (default: ${default_branch}): " ans
                DEPENDENCY_TAGS["nwm-verf"]="${ans:-$default_branch}"
            fi
        elif [[ "$build_type" == "release" ]]; then
            if [[ -z "${DEPENDENCY_TAGS[nwm-verf]:-}" ]]; then
                read -p "Which nwm-eval-mgr release tag do you want nwm-verf to use?: " ans
                DEPENDENCY_TAGS["nwm-verf"]="${ans}"
            fi
        fi
    fi
}

# reorder SELECTED_REPOS to respect dependency chain
# ngen-forcing must come before ngen, ngen must come before nwm-cal-mgr/nwm-fcst-mgr
reorder_repos_by_dependency() {
    local ordered=()
    local remaining=("${SELECTED_REPOS[@]}")

    # dependency order: ngen-forcing -> ngen -> nwm-cal-mgr/nwm-fcst-mgr -> others
    local priority_order=("ngen-forcing" "ngen" "nwm-cal-mgr" "nwm-fcst-mgr")

    # first, add priority repos in order if they exist in SELECTED_REPOS
    for repo in "${priority_order[@]}"; do
        if [[ " ${remaining[*]} " =~ " ${repo} " ]]; then
            ordered+=("$repo")
            # remove from remaining
            remaining=("${remaining[@]/$repo}")
        fi
    done

    # then add any remaining repos
    for repo in "${remaining[@]}"; do
        [[ -n "$repo" ]] && ordered+=("$repo")
    done

    SELECTED_REPOS=("${ordered[@]}")
}

# validate that dependencies are satisfied
validate_dependencies() {
    local errors=()

    # for feature builds, check dependency chain
    if [[ "$BUILD_TYPE" == "feature" ]]; then
        # if ngen is being built, ensure ngen-forcing tag is available
        if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] && [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            local forcing_tag="${DEPENDENCY_TAGS[ngen]:-feature}"
            # check if ngen-forcing is being built or pulled
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " ngen-forcing " ]]; then
                # ngen-forcing not selected, but might be available from previous build
                echo "Warning: ngen will be built with NGEN_FORCING_TAG=${forcing_tag}, but ngen-forcing is not selected for build/pull."
                echo "         Ensure ngen-forcing:${forcing_tag} exists or select ngen-forcing for build/pull."
            fi
        fi

        # if nwm-cal-mgr/nwm-fcst-mgr is being built, ensure ngen tag is available
        for repo in "nwm-cal-mgr" "nwm-fcst-mgr"; do
            if [[ " ${SELECTED_REPOS[@]} " =~ " ${repo} " ]] && [[ "${IMAGE_SOURCE[$repo]}" == "build" ]]; then
                local ngen_tag="${DEPENDENCY_TAGS[$repo]:-feature}"
                # check if ngen is being built or pulled
                if [[ ! " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
                    echo "Warning: ${repo} will be built with NGEN_IMAGE_TAG=${ngen_tag}, but ngen is not selected for build/pull."
                    echo "         Ensure ngen:${ngen_tag} exists or select ngen for build/pull."
                fi
            fi
        done
    fi
}

# --- tag prompts for release and feature (when pulling) ---
declare -A TAGS
if [[ "$BUILD_TYPE" == "release" ]]; then
    for repo in "${SELECTED_REPOS[@]}"; do
        case $repo in
            ngencerf-ui)     read -p "Enter ngencerf-ui tag: " TAGS[ngencerf-ui] ;;
            ngencerf-server) read -p "Enter ngencerf-server tag: " TAGS[ngencerf-server] ;;
            ngencerf-docker) read -p "Enter ngencerf-docker tag: " TAGS[ngencerf-docker] ;;
            ngen)
                if [[ -z "${TAGS[ngen]:-}" ]]; then
                    read -p "Enter ngen tag: " TAGS[ngen]
                fi
                if [[ -z "${TAGS[ngen-forcing]:-}" ]]; then
                    read -p "Enter ngen-forcing tag (used by ngen): " TAGS[ngen-forcing]
                fi
            ;;
            nwm-cal-mgr)
                read -p "Enter nwm-cal-mgr tag: " TAGS[nwm-cal-mgr]
                if [[ -z "${TAGS[ngen]:-}" ]]; then
                    read -p "Enter ngen tag (required by nwm-cal-mgr): " TAGS[ngen]
                fi
            ;;
            ngen-forcing)    read -p "Enter ngen-forcing tag (shared for bmi/lumped/coastal): " TAGS[ngen-forcing] ;;
            nwm-fcst-mgr)
                read -p "Enter nwm-fcst-mgr tag: " TAGS[nwm-fcst-mgr]
                if [[ -z "${TAGS[ngen]:-}" ]]; then
                    read -p "Enter ngen tag (required by nwm-fcst-mgr): " TAGS[ngen]
                fi
            ;;
            nwm-verf)
                read -p "Enter nwm-verf tag: " TAGS[nwm-verf]
                read -p "Enter nwm-eval-mgr tag: " TAGS[nwm-eval-mgr]
            ;;
        esac
    done

    # validate that all required tags have been provided
    for repo in "${SELECTED_REPOS[@]}"; do
        if [[ -z "${TAGS[$repo]:-}" ]] && [[ "$repo" != "ngen" ]]; then
            echo "Error: Tag for '$repo' cannot be empty"; exit 1
        fi
    done

    # special validation for nwm-verf which requires nwm-eval-mgr tag
    if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-verf " ]] && [[ -z "${TAGS[nwm-eval-mgr]:-}" ]]; then
        echo "Error: nwm-eval-mgr tag is required when building nwm-verf"; exit 1
    fi
fi

# --- tag prompts for feature builds when pulling ---
if [[ "$BUILD_TYPE" == "feature" ]]; then
    for repo in "${SELECTED_REPOS[@]}"; do
        # only prompt for tags if the repo is set to pull (not build)
        if [[ " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]] && [[ "${IMAGE_SOURCE[$repo]}" == "pull" ]]; then
            case $repo in
                ngen)
                    if [[ -z "${TAGS[ngen]:-}" ]]; then
                        read -p "Enter Docker tag to pull for ngen (e.g., latest, development, v1.0): " TAGS[ngen]
                    fi
                ;;
                nwm-cal-mgr)
                    read -p "Enter Docker tag to pull for nwm-cal-mgr: " TAGS[nwm-cal-mgr]
                    if [[ -z "${TAGS[ngen]:-}" && "$NGEN_NEEDED" == "true" ]]; then
                        read -p "Enter Docker tag to pull for ngen (required by nwm-cal-mgr): " TAGS[ngen]
                    fi
                ;;
                ngen-forcing)
                    read -p "Enter Docker tag to pull for ngen-forcing (shared for bmi/lumped): " TAGS[ngen-forcing]
                ;;
                nwm-fcst-mgr)
                    read -p "Enter Docker tag to pull for nwm-fcst-mgr: " TAGS[nwm-fcst-mgr]
                    if [[ -z "${TAGS[ngen]:-}" && "$NGEN_NEEDED" == "true" ]]; then
                        read -p "Enter Docker tag to pull for ngen (required by nwm-fcst-mgr): " TAGS[ngen]
                    fi
                ;;
                nwm-verf)
                    read -p "Enter Docker tag to pull for nwm-verf: " TAGS[nwm-verf]
                ;;
            esac
        fi
    done
fi

# prompt for dependency tags
prompt_dependency_tags "$BUILD_TYPE"

# reorder repos to respect dependencies
reorder_repos_by_dependency

# validate dependencies
validate_dependencies


# build SIF and update symlink
# only rebuild when docker image digest/id changes; always delete temp tar
# keeps a tiny .meta file to remember the last image key and built sif filename
get_image_key() {
    local ref="$1"
    local dig
    dig="$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
    if [[ -n "$dig" && "$dig" != "<no value>" ]]; then
        echo "${dig##*@}"   # sha256:...
        return 0
    fi
    docker inspect --format='{{.Id}}' "$ref" 2>/dev/null || true
}

build_singularity_container_update_symlink() {
    local build_type="$1"
    local sif_base="$2"
    local image_ref="$3"
    local tag="$4"

    local sif_dir="${SINGULARITY_DIR}"
    local symlink_name="${sif_base}.sif"
    local ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local sif_file
    local meta_file="${sif_dir}/${sif_base}.meta"

    # naming: dev -> latest; rc -> feature; release -> explicit tag
    if [[ "$build_type" == "development" ]]; then
        sif_file="${sif_base}-latest-${ts}.sif"
    elif [[ "$build_type" == "feature" ]]; then
        sif_file="${sif_base}-feature-${ts}.sif"
    else
        sif_file="${sif_base}-${tag}-${ts}.sif"
    fi

    # compute current image key and read previous if available
    local current_key prev_key="" prev_sif=""
    current_key="$(get_image_key "$image_ref")"
    if [[ -z "$current_key" ]]; then
        echo "could not inspect '$image_ref' to compute image key"; exit 1
    fi
    if [[ -f "$meta_file" ]]; then
        # validate meta file contains only expected variable assignments
        if grep -Eq '^[A-Z_]+=' "$meta_file" && ! grep -Eq '[;&|$(){}<>`]' "$meta_file"; then
            # shellcheck disable=SC1090
            source "$meta_file"
            prev_key="${IMAGE_KEY:-}"
            prev_sif="${SIF_FILE:-}"
        else
            echo "Warning: meta file '$meta_file' appears corrupted or unsafe, ignoring it."
        fi
    fi

    # skip rebuild if image unchanged and previous sif exists; just refresh symlink
    if [[ -n "$prev_key" && "$prev_key" == "$current_key" && -n "$prev_sif" && -f "${sif_dir}/${prev_sif}" ]]; then
        ln -sfn "$prev_sif" "${sif_dir}/${symlink_name}"
        echo "no image change for ${image_ref} (${current_key}); kept existing SIF: ${symlink_name} -> ${prev_sif}"
        return 0
    fi

    (
        cd "$sif_dir"
        # create temp tar name and ensure cleanup on any exit
        local tar_name
        tar_name="$(mktemp -p "$sif_dir" "${sif_base}.XXXXXXXX.tar")"
        cleanup() { rm -f "$tar_name"; }
        trap cleanup EXIT INT TERM

        echo "[$(date '+%H:%M:%S')] Saving docker image to tar: ${image_ref}"
        docker save "${image_ref}" -o "${tar_name}"

        echo "[$(date '+%H:%M:%S')] Building SIF: ${sif_file} from docker-archive:${tar_name}"
        singularity build "${sif_file}" "docker-archive:${tar_name}"

        echo "[$(date '+%H:%M:%S')] Creating relative symlink: ${symlink_name} -> ${sif_file}"
        ln -sfn "${sif_file}" "${symlink_name}"

        # write/update meta so future runs can skip when unchanged
        {
            echo "IMAGE_REF=${image_ref}"
            echo "IMAGE_KEY=${current_key}"
            echo "TIMESTAMP=${ts}"
            echo "SIF_FILE=${sif_file}"
            echo "BUILD_TYPE=${build_type}"
            echo "TAG=${tag}"
        } > "${meta_file}"
    )
}

# update repo to latest from specified branch
update_repo_branch() {
    local repo="$1"
    local default_branch="$2"

    local branch_to_use
    branch_to_use="$(get_repo_branch "$repo" "$default_branch")"

    if [[ ! -d "$BASE_PATH/$repo" ]]; then
        echo "Error: Repository directory '$BASE_PATH/$repo' does not exist"; exit 1
    fi
    cd "$BASE_PATH/$repo"

    echo "[$(date '+%H:%M:%S')] Updating $repo to latest from $branch_to_use branch..."

    echo "[$(date '+%H:%M:%S')] Fetching from origin"
    git fetch origin

    local stash_result
    stash_result="$(git stash push 2>&1)"

    if ! git checkout "$branch_to_use"; then
        echo "Error: Branch '$branch_to_use' does not exist in $repo"; exit 1
    fi

    echo "[$(date '+%H:%M:%S')] Pulling latest changes from $branch_to_use"
    git pull origin "$branch_to_use" --rebase

    if [[ "$stash_result" != "No local changes to save" ]]; then
        if ! git stash pop; then
            echo "Warning: git stash pop failed, likely due to conflicts. Stashed changes remain in stash."
        fi
    fi

    if [[ "$repo" == "ngen" ]]; then
        echo "[$(date '+%H:%M:%S')] Updating submodules"
        git submodule update --init --recursive
    fi
}

# checkout repo at specified tag
checkout_repo_tag() {
    local repo="$1"
    local tag="$2"

    if [[ ! -d "$BASE_PATH/$repo" ]]; then
        echo "Error: Repository directory '$BASE_PATH/$repo' does not exist"; exit 1
    fi
    cd "$BASE_PATH/$repo"

    echo "[$(date '+%H:%M:%S')] Checking out $repo at tag $tag..."

    echo "[$(date '+%H:%M:%S')] Fetching from origin"
    git fetch origin

    local stash_result
    stash_result="$(git stash push 2>&1)"

    if ! git checkout "$tag"; then
        echo "Error: Tag '$tag' does not exist in $repo"; exit 1
    fi

    if [[ "$stash_result" != "No local changes to save" ]]; then
        if ! git stash pop; then
            echo "Warning: git stash pop failed, likely due to conflicts. Stashed changes remain in stash."
        fi
    fi

    if [[ "$repo" == "ngen" ]]; then
        echo "[$(date '+%H:%M:%S')] Updating submodules"
        git submodule update --init --recursive
    fi
}

# --- RELEASE WORKFLOW ---
if [[ "$BUILD_TYPE" == "release" ]]; then
    cd "$BASE_PATH"

    # handle ngen-forcing first if selected (dependency of ngen)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-forcing " ]]; then
        if [[ -z "${TAGS[ngen-forcing]:-}" ]]; then
            echo "Error: ngen-forcing is selected but no tag was provided."; exit 1
        fi

        if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                checkout_repo_tag "ngen-forcing" "${TAGS[ngen-forcing]}"
                echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                    --tag="${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-forcing]}" \
                    "${BASE_PATH}/ngen-forcing"

                echo "[$(date '+%H:%M:%S')] Building ngen-lumped-forcing Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                    --tag="${REGISTRY}/ngen-lumped-forcing:${TAGS[ngen-forcing]}" \
                    "${BASE_PATH}/ngen-forcing"

                echo "[$(date '+%H:%M:%S')] Building ngen-coastal Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                    --tag="${REGISTRY}/ngen-coastal:${TAGS[ngen-forcing]}" \
                    "${BASE_PATH}/ngen-forcing"
            else
                echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pulling ngen-forcing Docker images"
            docker pull "${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-forcing]}"
            docker pull "${REGISTRY}/ngen-lumped-forcing:${TAGS[ngen-forcing]}"
            docker pull "${REGISTRY}/ngen-coastal:${TAGS[ngen-forcing]}"
        fi
    fi

    # ngen first (build/pull even if not explicitly selected, if needed by other repos)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] || [[ -n "${TAGS[ngen]:-}" ]]; then
        if [[ -z "${TAGS[ngen]:-}" ]]; then
            echo "Error: ngen is selected but no tag was provided."; exit 1
        fi
        if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            checkout_repo_tag "ngen" "${TAGS[ngen]}"

            # use ngen-forcing tag (prompted when ngen is selected)
            local forcing_tag="${TAGS[ngen-forcing]}"

            echo "[$(date '+%H:%M:%S')] Building ngen Docker image with NGEN_FORCING_TAG=${forcing_tag}"
            docker build --progress=plain --no-cache \
                --build-arg NGEN_FORCING_TAG="${forcing_tag}" \
                --tag="${REGISTRY}/ngen:${TAGS[ngen]}" \
                "${BASE_PATH}/ngen"
        else
            echo "[$(date '+%H:%M:%S')] Pulling ngen Docker image"
            docker pull "${REGISTRY}/ngen:${TAGS[ngen]}"
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pulling nwm-cal-mgr Docker image"
                    docker pull "${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}"
                else
                    checkout_repo_tag "nwm-cal-mgr" "${TAGS[nwm-cal-mgr]}"
                    echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr Docker image"
                    docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                        --tag="${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}" \
                        "${BASE_PATH}/nwm-cal-mgr"
                fi
            ;;
            "ngen-forcing")
                : # handled above before ngen
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pulling nwm-fcst-mgr Docker image"
                    docker pull "${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}"
                else
                    checkout_repo_tag "nwm-fcst-mgr" "${TAGS[nwm-fcst-mgr]}"
                    echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr Docker image"
                    docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                        --tag="${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}" \
                        "${BASE_PATH}/nwm-fcst-mgr"
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pulling nwm-verf Docker image"
                    docker pull "${REGISTRY}/nwm-verf:${TAGS[nwm-verf]}"
                else
                    checkout_repo_tag "nwm-verf" "${TAGS[nwm-verf]}"
                    echo "[$(date '+%H:%M:%S')] Building nwm-verf Docker image"
                    docker build --progress=plain --no-cache \
                        --build-arg NWM_EVAL_MGR_TAG="${TAGS[nwm-eval-mgr]}" \
                        --tag="${REGISTRY}/nwm-verf:${TAGS[nwm-verf]}" \
                        "${BASE_PATH}/nwm-verf"
                fi
            ;;
            "ngen") : ;; # handled above
            ngencerf*)
                checkout_repo_tag "$repo" "${TAGS[$repo]}"
            ;;
        esac

        # build SIFs (explicit docker->sif pairs)
        if repo_has_sif "$repo"; then
            tag_val="${TAGS[$repo]}"
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "${REGISTRY}/${docker_img}:${tag_val}" "$tag_val"
            done
        fi
    done

    echo "Release build completed successfully!"
    exit 0
fi

# ---- DEVELOPMENT WORKFLOW ----
if [[ "$BUILD_TYPE" == "development" ]]; then
    cd "$BASE_PATH"

    # check if ngen is needed as a dependency for other repos
    NGEN_NEEDED=false
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        NGEN_NEEDED=true
    elif [[ " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]] || [[ " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
        NGEN_NEEDED=true
        echo "Note: ngen is required as a dependency for nwm-cal-mgr/nwm-fcst-mgr"
    fi

    # handle ngen-forcing first if it's selected and building
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-forcing " ]] && [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
        if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
            update_repo_branch "ngen-forcing" "development"
            echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing (development) Docker image"
            docker build --progress=plain --no-cache \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                --tag="${REGISTRY}/ngen-bmi-forcing:latest" \
                "${BASE_PATH}/ngen-forcing"

            echo "[$(date '+%H:%M:%S')] Building ngen-lumped-forcing (development) Docker image"
            docker build --progress=plain --no-cache \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                --tag="${REGISTRY}/ngen-lumped-forcing:latest" \
                "${BASE_PATH}/ngen-forcing"

            echo "[$(date '+%H:%M:%S')] Building ngen-coastal (development) Docker image"
            docker build --progress=plain --no-cache \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                --tag="${REGISTRY}/ngen-coastal:latest" \
                "${BASE_PATH}/ngen-forcing"
        else
            echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
        fi
    fi

    # build or pull ngen first so downstream builds may use ngen:latest
    if [[ "$NGEN_NEEDED" == "true" ]]; then
        if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen" ]]; then
                update_repo_branch "ngen" "development"
                echo "[$(date '+%H:%M:%S')] Building ngen (development) Docker image with NGEN_FORCING_TAG=latest"
                docker build --progress=plain --no-cache \
                    --build-arg NGEN_FORCING_TAG="latest" \
                    --tag="${REGISTRY}/ngen:latest" \
                    "${BASE_PATH}/ngen"
            else
                echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pulling ngen (development) Docker image"
            docker pull "${REGISTRY}/ngen:latest"
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        echo

        # update ngencerf* repo's development branch
        if [[ "$repo" == ngencerf* ]]; then
            update_repo_branch "$repo" "development"
        fi

        # per-repo local build paths
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-cal-mgr" ]]; then
                        update_repo_branch "nwm-cal-mgr" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr (development) Docker image"
                        docker build --progress=plain --no-cache \
                            --build-arg NGEN_IMAGE_TAG="latest" \
                            --tag="${REGISTRY}/nwm-cal-mgr:latest" \
                            "${BASE_PATH}/nwm-cal-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-cal-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-fcst-mgr" ]]; then
                        update_repo_branch "nwm-fcst-mgr" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr (development) Docker image"
                        docker build --progress=plain --no-cache \
                            --build-arg NGEN_IMAGE_TAG="latest" \
                            --tag="${REGISTRY}/nwm-fcst-mgr:latest" \
                            "${BASE_PATH}/nwm-fcst-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-fcst-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-verf" ]]; then
                        update_repo_branch "nwm-verf" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-verf (development) Docker image"
                        docker build --progress=plain --no-cache \
                            --build-arg NWM_EVAL_MGR_TAG="development" \
                            --tag="${REGISTRY}/nwm-verf:latest" \
                            "${BASE_PATH}/nwm-verf"
                    else
                        echo "Error: ${BASE_PATH}/nwm-verf not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen-forcing")
                # already handled before ngen if building
                if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
                    : # skip, already built above
                fi
            ;;
            "ngen")
                : # handled above if building
            ;;
        esac

        # DEBUG: Show which repo is being processed
        echo "[DEBUG] Processing repo: '$repo' from SELECTED_REPOS: ${SELECTED_REPOS[*]}"

        # for each repo that produces a SIF, use the locally built image if mode==build,
        # otherwise pull the image
        if repo_has_sif "$repo"; then
            echo "[DEBUG] Repo '$repo' produces SIF, images: $(images_for_repo "$repo")"
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                IMAGE="${REGISTRY}/${docker_img}:latest"
                echo "[DEBUG] Extracted docker_img='$docker_img', sif_name='$sif_name', IMAGE='$IMAGE'"

                if [[ "${IMAGE_SOURCE[$repo]}" != "build" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pulling docker image for SIF: $IMAGE"
                    docker pull "$IMAGE"
                else
                    echo "[$(date '+%H:%M:%S')] Using locally built image for SIF: $IMAGE"
                fi

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "latest"
            done
        fi
    done

    echo "Development build completed successfully!"
    exit 0
fi

# ---- FEATURE WORKFLOW ----
if [[ "$BUILD_TYPE" == "feature" ]]; then
    cd "$BASE_PATH"

    # check if ngen-forcing is needed as a dependency for ngen
    NGEN_FORCING_NEEDED=false
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-forcing " ]]; then
        NGEN_FORCING_NEEDED=true
    elif [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        NGEN_FORCING_NEEDED=true
        echo "Note: ngen-forcing is required as a dependency for ngen (if building ngen from source)"
    fi

    # check if ngen is needed as a dependency for other repos
    NGEN_NEEDED=false
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        NGEN_NEEDED=true
    elif [[ " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]] || [[ " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
        NGEN_NEEDED=true
        echo "Note: ngen is required as a dependency for nwm-cal-mgr/nwm-fcst-mgr"
    fi

    # handle ngen-forcing first (dependency of ngen)
    if [[ "$NGEN_FORCING_NEEDED" == "true" ]]; then
        if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                update_repo_branch "ngen-forcing" "feature"
                echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing (feature) Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                    --tag="${REGISTRY}/ngen-bmi-forcing:feature" \
                    "${BASE_PATH}/ngen-forcing"

                echo "[$(date '+%H:%M:%S')] Building ngen-lumped-forcing (feature) Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                    --tag="${REGISTRY}/ngen-lumped-forcing:feature" \
                    "${BASE_PATH}/ngen-forcing"

                echo "[$(date '+%H:%M:%S')] Building ngen-coastal (feature) Docker image"
                docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                    --tag="${REGISTRY}/ngen-coastal:feature" \
                    "${BASE_PATH}/ngen-forcing"
            else
                echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
            fi
        else
            # pulling ngen-forcing
            forcing_tag="${TAGS[ngen-forcing]:-feature}"
            echo "[$(date '+%H:%M:%S')] Pulling ngen-forcing Docker images with tag: ${forcing_tag}"
            docker pull "${REGISTRY}/ngen-bmi-forcing:${forcing_tag}"
            docker pull "${REGISTRY}/ngen-lumped-forcing:${forcing_tag}"
            docker pull "${REGISTRY}/ngen-coastal:${forcing_tag}"

            # retag as :feature for consistency
            if [[ "$forcing_tag" != "feature" ]]; then
                docker tag "${REGISTRY}/ngen-bmi-forcing:${forcing_tag}" "${REGISTRY}/ngen-bmi-forcing:feature"
                docker tag "${REGISTRY}/ngen-lumped-forcing:${forcing_tag}" "${REGISTRY}/ngen-lumped-forcing:feature"
                docker tag "${REGISTRY}/ngen-coastal:${forcing_tag}" "${REGISTRY}/ngen-coastal:feature"
            fi
        fi
    fi

    # build or pull ngen first so downstream builds may use ngen:feature
    if [[ "$NGEN_NEEDED" == "true" ]]; then
        if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen" ]]; then
                update_repo_branch "ngen" "feature"

                # determine ngen-forcing tag to use
                local ngen_forcing_tag="${DEPENDENCY_TAGS[ngen]:-feature}"

                echo "[$(date '+%H:%M:%S')] Building ngen (feature) Docker image with NGEN_FORCING_TAG=${ngen_forcing_tag}"
                docker build --progress=plain --no-cache \
                    --build-arg NGEN_FORCING_TAG="${ngen_forcing_tag}" \
                    --tag="${REGISTRY}/ngen:feature" \
                    "${BASE_PATH}/ngen"
            else
                echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
            fi
        else
            ngen_tag="${TAGS[ngen]:-feature}"
            echo "[$(date '+%H:%M:%S')] Pulling ngen Docker image with tag: ${ngen_tag}"
            docker pull "${REGISTRY}/ngen:${ngen_tag}"
            # retag as :feature for consistency with build workflow
            if [[ "$ngen_tag" != "feature" ]]; then
                docker tag "${REGISTRY}/ngen:${ngen_tag}" "${REGISTRY}/ngen:feature"
            fi
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        echo

        # update ngencerf* repo's feature branch
        if [[ "$repo" == ngencerf* ]]; then
            update_repo_branch "$repo" "feature"
        fi

        # per-repo local build paths (mirrors development but with rc tags/args)
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-cal-mgr" ]]; then
                        update_repo_branch "nwm-cal-mgr" "feature"

                        # determine ngen tag to use
                        local ngen_tag="${DEPENDENCY_TAGS[nwm-cal-mgr]:-feature}"

                        echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr (feature) Docker image with NGEN_IMAGE_TAG=${ngen_tag}"
                        docker build --progress=plain --no-cache \
                            --build-arg NGEN_IMAGE_TAG="${ngen_tag}" \
                            --tag="${REGISTRY}/nwm-cal-mgr:feature" \
                            "${BASE_PATH}/nwm-cal-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-cal-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-fcst-mgr" ]]; then
                        update_repo_branch "nwm-fcst-mgr" "feature"

                        # determine ngen tag to use
                        local ngen_tag="${DEPENDENCY_TAGS[nwm-fcst-mgr]:-feature}"

                        echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr (feature) Docker image with NGEN_IMAGE_TAG=${ngen_tag}"
                        docker build --progress=plain --no-cache \
                            --build-arg NGEN_IMAGE_TAG="${ngen_tag}" \
                            --tag="${REGISTRY}/nwm-fcst-mgr:feature" \
                            "${BASE_PATH}/nwm-fcst-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-fcst-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-verf" ]]; then
                        update_repo_branch "nwm-verf" "feature"

                        # determine nwm-eval-mgr tag to use
                        local nwm_eval_mgr_tag="${DEPENDENCY_TAGS[nwm-verf]:-feature}"

                        echo "[$(date '+%H:%M:%S')] Building nwm-verf (feature) Docker image with NWM_EVAL_MGR_TAG=${nwm_eval_mgr_tag}"
                        docker build --progress=plain --no-cache \
                            --build-arg NWM_EVAL_MGR_TAG="${nwm_eval_mgr_tag}" \
                            --tag="${REGISTRY}/nwm-verf:feature" \
                            "${BASE_PATH}/nwm-verf"
                    else
                        echo "Error: ${BASE_PATH}/nwm-verf not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen-forcing")
                : # handled above before ngen
            ;;
            "ngen")
                : # handled above if building
            ;;
        esac

        # DEBUG: Show which repo is being processed
        echo "[DEBUG] Processing repo: '$repo' from SELECTED_REPOS: ${SELECTED_REPOS[*]}"

        # for each repo that produces a SIF, use the locally built image if mode==build,
        # otherwise pull the specified tag and retag as :feature
        if repo_has_sif "$repo"; then
            echo "[DEBUG] Repo '$repo' produces SIF, images: $(images_for_repo "$repo")"
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                echo "[DEBUG] Extracted docker_img='$docker_img', sif_name='$sif_name'"

                if [[ "${IMAGE_SOURCE[$repo]}" != "build" ]]; then
                    # use tag from TAGS array if pulling, otherwise default to :feature
                    pull_tag="${TAGS[$repo]:-feature}"
                    pull_image="${REGISTRY}/${docker_img}:${pull_tag}"
                    echo "[DEBUG] pull_image='$pull_image'"
                    echo "[$(date '+%H:%M:%S')] Pulling docker image for SIF: $pull_image"
                    docker pull "$pull_image"

                    # retag as :feature for consistency
                    if [[ "$pull_tag" != "feature" ]]; then
                        docker tag "$pull_image" "${REGISTRY}/${docker_img}:feature"
                    fi
                    IMAGE="${REGISTRY}/${docker_img}:feature"
                else
                    IMAGE="${REGISTRY}/${docker_img}:feature"
                    echo "[$(date '+%H:%M:%S')] Using locally built image for SIF: $IMAGE"
                fi

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "feature"
            done
        fi
    done

    echo "feature build completed successfully!"
    exit 0
fi

# --- INVALID BUILD_TYPE ---
echo "Error: Invalid BUILD_TYPE '${BUILD_TYPE}'. Must be one of: development, release, feature"
exit 1
