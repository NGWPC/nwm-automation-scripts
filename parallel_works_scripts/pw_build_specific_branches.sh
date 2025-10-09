#!/bin/bash
set -euo pipefail

# ================================================
# Logging setup (all output to screen + file)
# ================================================
LOG_DIR="/ngencerf-app"
LOG_FILE="${LOG_DIR}/pw_build_specific_branches_$(date -u +'%Y-%m-%dT%H-%M-%SZ').log"

# Create directory if missing
mkdir -p "$LOG_DIR"

# Send stdout and stderr to both terminal and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Logging to $LOG_FILE"
echo


# ================================================
# TEMPORARY FLAG: set to true to skip Docker/Git builds
# ================================================
SKIP_DOCKER_BUILDS=false
# ================================================

# ----------------------------
# Sticky header using scroll region
# ----------------------------
_rows() { tput lines 2>/dev/null || echo 24; }

_draw_header() {
    # Draws the header message on the first line and re-establishes the scroll region.
    local msg="$1"
    local rows=$(_rows)
    printf '\033[r'                                   # reset scroll region
    printf '\033[1;1H\033[2K\033[1;97;40m%s\033[0m' "$msg"  # bold white on black
    printf '\033[2;1H\033[2K'                         # clear line 2
    printf '\033[3;%sr\033[3;1H' "$rows"              # set scroll region 3..bottom
}

header_init() {
    # Clear entire screen and draw initial header
    printf '\033[H\033[2J'                            # home + clear screen
    _draw_header "$1"
}

header_set() {
    # Update header text without clearing entire screen
    _draw_header "$1"
}

header_reset() {
    # Restore normal scrolling on exit
    printf '\033[r'
}
trap header_reset EXIT

# ----------------------------
# Builds
# ----------------------------
if [ "$SKIP_DOCKER_BUILDS" = false ]; then
    header_init "Building ngen-forcing at branch forecast_validation_root_dir"
    cd /ngencerf-app/ngen-forcing
    git fetch origin
    git stash save || true
    git checkout forecast_validation_root_dir
    git pull
    git stash pop || true

    # Build forcing images
    docker build --progress=plain --no-cache --tag "ghcr.io/ngwpc/ngen-bmi-forcing:forecast_validation" -f Dockerfile.bmi-forcings /ngencerf-app/ngen-forcing

    docker build --progress=plain --no-cache --tag "ghcr.io/ngwpc/ngen-lumped-forcing:forecast_validation" -f Dockerfile.lumped-forcings /ngencerf-app/ngen-forcing

    docker build --progress=plain --no-cache --tag "ghcr.io/ngwpc/ngen-coastal:forecast_validation" -f Dockerfile.ngencoastal /ngencerf-app/ngen-forcing

    header_set "Building ngen at branch forecast_validation"
    cd /ngencerf-app/ngen
    git fetch origin
    git stash save || true
    git checkout forecast_validation
    git pull
    git stash pop || true
    git submodule update --init --recursive

    # Build ngen image
    docker build --progress=plain --no-cache --build-arg "NGEN_FORCING_IMAGE_TAG=forecast_validation" --tag "ghcr.io/ngwpc/ngen:forecast_validation" /ngencerf-app/ngen

    header_set "Building nwm-cal-mgr at branch development"
    cd /ngencerf-app/nwm-cal-mgr
    git fetch origin
    git stash save || true
    git checkout development
    git pull
    git stash pop || true

    # Build nwm-cal-mgr
    docker build --progress=plain --no-cache --build-arg "NGEN_IMAGE_TAG=forecast_validation" --tag "ghcr.io/ngwpc/nwm-cal-mgr:latest" /ngencerf-app/nwm-cal-mgr

    header_set "Building nwm-fcst-mgr at branch forecast_validation_multiple_calls"
    cd /ngencerf-app/nwm-fcst-mgr
    git fetch origin
    git stash save || true
    git checkout forecast_validation_multiple_calls
    git pull
    git stash pop || true

    # Build nwm-fcst-mgr
    docker build --progress=plain --no-cache --build-arg "NGEN_IMAGE_TAG=forecast_validation" --tag "ghcr.io/ngwpc/nwm-fcst-mgr:latest" /ngencerf-app/nwm-fcst-mgr

    header_set "Update MSWM_TAG in ngencerf-server to forecast_validation_root_dir (.env)"
    cd /ngencerf-app/ngencerf-server
    gedit .env
else
    header_init "Skipping Docker/Git build section (SKIP_DOCKER_BUILDS=true)"
fi


# ----------------------------
# Singularity build section
# ----------------------------
header_set "=== Building Singularity images from Docker archives ==="
cd /ngencerf-app/singularity

# Define Docker images
images=(
  ghcr.io/ngwpc/ngen-bmi-forcing:forecast_validation
  ghcr.io/ngwpc/ngen-lumped-forcing:forecast_validation
  ghcr.io/ngwpc/ngen-coastal:forecast_validation
  ghcr.io/ngwpc/ngen:forecast_validation
  ghcr.io/ngwpc/nwm-cal-mgr:latest
  ghcr.io/ngwpc/nwm-fcst-mgr:latest
)

for image in "${images[@]}"; do
    name="$(basename "${image%%:*}")"
    tag="$(echo "$image" | cut -d: -f2)"
    datestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    header_set "Building Singularity image for $name:$tag"
    docker save "$image" -o "/ngencerf-app/singularity/${name}.tar"
    sudo singularity build "/ngencerf-app/singularity/${name}-${tag}-${datestamp}.sif" "docker-archive:///ngencerf-app/singularity/${name}.tar" || echo "Failed to build $image"
    ln -sf "/ngencerf-app/singularity/${name}-${tag}-${datestamp}.sif" "/ngencerf-app/singularity/${name}.sif"
    rm -f "/ngencerf-app/singularity/${name}.tar"
done

header_set "✅ All builds complete."
# Allow the header to remain visible; trap will reset scroll region on exit

