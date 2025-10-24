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
# Release-candidate build (mirrors development but uses the release-candidate branch
# and tags images as :release-candidate):
#   ./build_cluster.sh --build-type=release-candidate ngen nwm-cal-mgr
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
#   --build-type=TYPE        One of: development, release, release-candidate
#   --source=REPO:MODE       For REPO in {ngen, nwm-cal-mgr, ngen-forcing, nwm-verf, nwm-fcst-mgr},
#                            MODE is build or pull. Can be repeated.
#   --source-default=MODE    Global default (build|pull) for the above repos (optional).
#   --branch=BRANCH         Specify a custom branch to build from (optional).
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

# --- BASE DIRECTORY SETUP ---
BASE_PATH="/ngencerf-app"
SINGULARITY_DIR="${BASE_PATH}/singularity"
mkdir -p "$SINGULARITY_DIR"

# redirect stdout and stderr to a log file in the singularity directory
LOGFILE="${SINGULARITY_DIR}/build_cluster_$(date -u +"%Y-%m-%dT%H:%M:%SZ").log"
exec > >(tee -i "$LOGFILE") 2>&1

# Branch selection for building
CUSTOM_BRANCH=""

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

# map repo -> "docker_image|sif_name" (space-separated for multiples)
images_for_repo() {
    local repo="$1"
    case "$repo" in
        ngen)            echo "ngen|ngen" ;;
        ngencerf-ui)     echo "" ;;
        ngencerf-server) echo "" ;;
        ngencerf-docker) echo "" ;;
        nwm-cal-mgr)     echo "nwm-cal-mgr|nwm-cal-mgr" ;;
        ngen-forcing)    echo "ngen-bmi-forcing|ngen-bmi-forcing ngen-lumped-forcing|ngen-lumped-forcing" ;;
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

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-type=*)
                BUILD_TYPE="${1#*=}"
            ;;
            --build-type)
                shift; BUILD_TYPE="$1"
            ;;
            --branch=*)
                CUSTOM_BRANCH="${1#*=}"
            ;;
            --branch)
                shift; CUSTOM_BRANCH="$1"
            ;;
            --source-default=*)
                IMAGE_SOURCE_DEFAULT="${1#*=}" # build|pull
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

# --- Interactive prompts if needed ---
if [[ -z "$BUILD_TYPE" && -t 0 ]]; then
    echo "Select build type:"
    echo "1) development"
    echo "2) release"
    echo "3) release-candidate"
    read -p "Enter number [1-3]: " build_choice
    case $build_choice in
        1) BUILD_TYPE="development" ;;
        2) BUILD_TYPE="release" ;;
        3) BUILD_TYPE="release-candidate" ;;
        *) echo "Invalid choice, exiting."; exit 1 ;;
    esac

    if [[ "$BUILD_TYPE" != "release" ]]; then
        read -p "Enter custom branch to build from (press Enter to use ${BUILD_TYPE}): " CUSTOM_BRANCH
    fi
fi

if [[ ${#SELECTED_REPOS[@]} -eq 0 && -t 0 ]]; then
    echo "Available repos: ${REPOS[*]}"
    read -p "Enter repos to build (space-separated from the list above): " -a SELECTED_REPOS
fi

if [[ -z "$BUILD_TYPE" || ${#SELECTED_REPOS[@]} -eq 0 ]]; then
    echo "Error: build type and at least one repo must be provided."; exit 1
fi

set_image_source_defaults

echo "Build type selected: $BUILD_TYPE"
echo "Selected repos: ${SELECTED_REPOS[*]}"

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

# optional interactive per-repo source selection
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
fi

# --- tag prompts for release ---
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
fi

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

    # naming: dev -> latest; rc -> release-candidate; release -> explicit tag
    if [[ "$build_type" == "development" ]]; then
        sif_file="${sif_base}-latest-${ts}.sif"
    elif [[ "$build_type" == "release-candidate" ]]; then
        sif_file="${sif_base}-release-candidate-${ts}.sif"
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
        # shellcheck disable=SC1090
        source "$meta_file"
        prev_key="${IMAGE_KEY:-}"
        prev_sif="${SIF_FILE:-}"
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

        echo "Saving docker image to tar: ${image_ref}"
        docker save "${image_ref}" -o "${tar_name}"

        echo "Building SIF: ${sif_file} from docker-archive:${tar_name}"
        singularity build "${sif_dir}/${sif_file}" "docker-archive:${tar_name}"

        echo "Creating relative symlink: ${symlink_name} -> ${sif_file}"
        ln -sf "${sif_file}" "${symlink_name}"

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

    local branch_to_use="${CUSTOM_BRANCH:-$default_branch}"
    echo "Updating $repo to latest from $branch_to_use branch..."
    cd "$BASE_PATH/$repo"
    git fetch origin
    git stash save
    git checkout "$branch_to_use"
    git pull origin "$branch_to_use" --rebase
    git stash pop || true # prevent exit if no stash
    if [[ "$repo" == "ngen" ]]; then
        git submodule update --init --recursive
    fi
}

# checkout repo at specified tag
checkout_repo_tag() {
    local repo="$1"
    local tag="$2"

    echo "Checking out $repo at tag $tag..."
    cd "$BASE_PATH/$repo"
    git fetch origin
    git stash save
    git checkout "$tag"
    git stash pop || true # prevent exit if no stash

    if [[ "$repo" == "ngen" ]]; then
        # initialize and update submodules to correct commit
        git submodule update --init --recursive
    fi
}

# --- RELEASE WORKFLOW ---
if [[ "$BUILD_TYPE" == "release" ]]; then
    cd "$BASE_PATH"

    # ngen first
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            checkout_repo_tag "ngen" "${TAGS[ngen]}"
            echo "Building ngen Docker image..."
            docker build --progress=plain --no-cache \
            --tag="${REGISTRY}/ngen:${TAGS[ngen]}" \
            "${BASE_PATH}/ngen"
        else
            echo "Pulling ngen Docker image..."
            docker pull "${REGISTRY}/ngen:${TAGS[ngen]}"
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "pull" ]]; then
                    echo "Pulling nwm-cal-mgr Docker image..."
                    docker pull "${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}"
                else
                    checkout_repo_tag "nwm-cal-mgr" "${TAGS[nwm-cal-mgr]}"
                    echo "Building nwm-cal-mgr Docker image..."
                    docker build --progress=plain --no-cache \
                    --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                    --tag="${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}" \
                    "${BASE_PATH}/nwm-cal-mgr"
                fi
            ;;
            "ngen-forcing")
                if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                        checkout_repo_tag "ngen-forcing" "${TAGS[ngen-forcing]}" || true
                        echo "Building ngen-bmi-forcing Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                        --tag="${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-forcing]}" \
                        "${BASE_PATH}/ngen-forcing"

                        checkout_repo_tag "ngen-forcing" "${TAGS[ngen-forcing]}" || true
                        echo "Building ngen-lumped-forcing Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                        --tag="${REGISTRY}/ngen-lumped-forcing:${TAGS[ngen-forcing]}" \
                        "${BASE_PATH}/ngen-forcing"
                    else
                        echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                    fi
                else
                    echo "Pulling ngen-bmi-forcing Docker image..."
                    docker pull "${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-forcing]}"
                    echo "Pulling ngen-lumped-forcing Docker image..."
                    docker pull "${REGISTRY}/ngen-lumped-forcing:${TAGS[ngen-forcing]}"
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "pull" ]]; then
                    echo "Pulling nwm-fcst-mgr Docker image..."
                    docker pull "${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}"
                else
                    checkout_repo_tag "nwm-fcst-mgr" "${TAGS[nwm-fcst-mgr]}"
                    echo "Building nwm-fcst-mgr Docker image..."
                    docker build --progress=plain --no-cache \
                    --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                    --tag="${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}" \
                    "${BASE_PATH}/nwm-fcst-mgr"
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "pull" ]]; then
                    echo "Pulling nwm-verf Docker image..."
                    docker pull "${REGISTRY}/nwm-verf:${TAGS[nwm-verf]}"
                else
                    checkout_repo_tag "nwm-verf" "${TAGS[nwm-verf]}"
                    echo "Building nwm-verf Docker image..."
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

    # build ngen locally first so downstream builds may use ngen:latest
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " && "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
        if [[ -d "${BASE_PATH}/ngen" ]]; then
            update_repo_branch "ngen" "development"
            echo "Building ngen (development) Docker image..."
            docker build --progress=plain --no-cache \
            --tag="${REGISTRY}/ngen:latest" \
            "${BASE_PATH}/ngen"
        else
            echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
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
                        echo "Building nwm-cal-mgr (development) Docker image..."
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
                        echo "Building nwm-fcst-mgr (development) Docker image..."
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
                        echo "Building nwm-verf (development) Docker image..."
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
                if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                        update_repo_branch "ngen-forcing" "development"
                        echo "Building ngen-bmi-forcing (development) Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                        --tag="${REGISTRY}/ngen-bmi-forcing:latest" \
                        "${BASE_PATH}/ngen-forcing"

                        update_repo_branch "ngen-forcing" "development"
                        echo "Building ngen-lumped-forcing (development) Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                        --tag="${REGISTRY}/ngen-lumped-forcing:latest" \
                        "${BASE_PATH}/ngen-forcing"
                    else
                        echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen")
                : # handled above if building
            ;;
        esac

        # for each repo that produces a SIF, use the locally built image if mode==build,
        # otherwise pull the image
        if repo_has_sif "$repo"; then
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                IMAGE="${REGISTRY}/${docker_img}:latest"

                if [[ "${IMAGE_SOURCE[$repo]}" != "build" ]]; then
                    echo "Pulling docker image for SIF: $IMAGE"
                    docker pull "$IMAGE"
                else
                    echo "Using locally built image for SIF: $IMAGE"
                fi

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "latest"
            done
        fi
    done

    echo "Development build completed successfully!"
    exit 0
fi

# ---- RELEASE-CANDIDATE WORKFLOW ----
if [[ "$BUILD_TYPE" == "release-candidate" ]]; then
    cd "$BASE_PATH"

    # build ngen locally first so downstream builds may use ngen:release-candidate
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " && "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
        if [[ -d "${BASE_PATH}/ngen" ]]; then
            update_repo_branch "ngen" "release-candidate"
            echo "Building ngen (release-candidate) Docker image..."
            docker build --progress=plain --no-cache \
            --tag="${REGISTRY}/ngen:release-candidate" \
            "${BASE_PATH}/ngen"
        else
            echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        echo

        # update ngencerf* repo's release-candidate branch
        if [[ "$repo" == ngencerf* ]]; then
            update_repo_branch "$repo" "release-candidate"
        fi

        # per-repo local build paths (mirrors development but with rc tags/args)
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-cal-mgr" ]]; then
                        update_repo_branch "nwm-cal-mgr" "release-candidate"
                        echo "Building nwm-cal-mgr (release-candidate) Docker image..."
                        docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="release-candidate" \
                        --tag="${REGISTRY}/nwm-cal-mgr:release-candidate" \
                        "${BASE_PATH}/nwm-cal-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-cal-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-fcst-mgr" ]]; then
                        update_repo_branch "nwm-fcst-mgr" "release-candidate"
                        echo "Building nwm-fcst-mgr (release-candidate) Docker image..."
                        docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="release-candidate" \
                        --tag="${REGISTRY}/nwm-fcst-mgr:release-candidate" \
                        "${BASE_PATH}/nwm-fcst-mgr"
                    else
                        echo "Error: ${BASE_PATH}/nwm-fcst-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-verf" ]]; then
                        update_repo_branch "nwm-verf" "release-candidate"
                        echo "Building nwm-verf (release-candidate) Docker image..."
                        docker build --progress=plain --no-cache \
                        --build-arg NWM_EVAL_MGR_TAG="release-candidate" \
                        --tag="${REGISTRY}/nwm-verf:release-candidate" \
                        "${BASE_PATH}/nwm-verf"
                    else
                        echo "Error: ${BASE_PATH}/nwm-verf not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen-forcing")
                if [[ "${IMAGE_SOURCE[ngen-forcing]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                        update_repo_branch "ngen-forcing" "release-candidate"
                        echo "Building ngen-bmi-forcing (release-candidate) Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                        --tag="${REGISTRY}/ngen-bmi-forcing:release-candidate" \
                        "${BASE_PATH}/ngen-forcing"

                        update_repo_branch "ngen-forcing" "release-candidate"
                        echo "Building ngen-lumped-forcing (release-candidate) Docker image..."
                        docker build --progress=plain --no-cache \
                        --file "${BASE_PATH}/ngen-forcing/Dockerfile.lumped-forcings" \
                        --tag="${REGISTRY}/ngen-lumped-forcing:release-candidate" \
                        "${BASE_PATH}/ngen-forcing"
                    else
                        echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen")
                : # handled above if building
            ;;
        esac

        # for each repo that produces a SIF, use the locally built image if mode==build,
        # otherwise pull the :release-candidate image
        if repo_has_sif "$repo"; then
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                IMAGE="${REGISTRY}/${docker_img}:release-candidate"

                if [[ "${IMAGE_SOURCE[$repo]}" != "build" ]]; then
                    echo "Pulling docker image for SIF: $IMAGE"
                    docker pull "$IMAGE"
                else
                    echo "Using locally built image for SIF: $IMAGE"
                fi

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "release-candidate"
            done
        fi
    done

    echo "release-candidate build completed successfully!"
    exit 0
fi
