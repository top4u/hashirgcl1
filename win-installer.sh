#!/usr/bin/env bash
# my-tinyinstaller.sh — Robust auto-installer for Windows on Linux (Docker + KVM)
#
# v15:
#   - Pinned Docker image with mandatory digest
#   - Stronger installation identity/state validation
#   - Safer destructive-operation checks
#   - TTY-aware confirmations
#   - Credential-file symlink protection
#   - More portable Docker Compose status checking
#   - FreeRDP failures treated as retryable during bootstrap
#   - Atomic state/credential/marker writes
#   - Explicit effective-vs-requested disk handling
#   - No unnecessary `docker compose down -v`
#   - Container identity labels tied to installer UUID
#   - Password remains in Docker environment because Dockur's documented
#     interface uses PASSWORD; do NOT assume PASSWORD_FILE support
#
# IMPORTANT:
#   Replace REPLACE_WITH_VERIFIED_DIGEST with a digest you have independently
#   verified for the exact Dockur image/tag/platform you intend to run.
#
# Example:
#   docker buildx imagetools inspect dockurr/windows:6.04
#
# Security model:
#   - RDP and web console bind to localhost only.
#   - Use SSH tunneling for remote access.
#   - credentials.txt is mode 600.
#   - The Docker environment necessarily contains PASSWORD.
#
# Tested conceptually for Bash 4+/Docker Compose v2/Linux.
# ================================================================

set -Eeuo pipefail

# ==================== USER OPTIONS ==============================
WIN_VERSION="${WIN_VERSION:-2022}"        # 2025 | 2022 | 2019 | 2016 | 11 | 10
RDP_USER="${RDP_USER:-admin}"
DISK_SIZE="${DISK_SIZE:-64G}"
RAM_SIZE="${RAM_SIZE:-8G}"
CPU_CORES="${CPU_CORES:-4}"
DATA_DIR="${DATA_DIR:-$HOME/windows-vm}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
RDP_WAIT_SECONDS="${RDP_WAIT_SECONDS:-2700}"

# Set AUTO_YES=1 only if you deliberately want confirmations bypassed.
# Destructive version changes still require an explicit safety variable.
AUTO_YES="${AUTO_YES:-0}"
ALLOW_DESTRUCTIVE="${ALLOW_DESTRUCTIVE:-0}"
# ================================================================

# Pinned image with immutable digest.
# Replace the placeholder before running.
WINDOWS_IMAGE="${WINDOWS_IMAGE:-dockurr/windows:6.04@sha256:REPLACE_WITH_VERIFIED_DIGEST}"

SUPPORTED_VERSIONS=(2025 2022 2019 2016 11 10)

CRED_FILE=""
STATE_FILE=""
MARKER_FILE=""
COMPOSE_FILE=""

RDP_PASSWORD=""
EFFECTIVE_USER=""
EFFECTIVE_DISK_SIZE=""

COMPOSE_STARTED=0
VERIFIED_AUTH=0

RESOLVED_IMAGE_ID=""
EXPECTED_DIGEST=""
EXPECTED_REPO_DIGEST=""
INSTALL_UUID=""

STATE_VERSION=""
STATE_USER=""
STATE_RAM=""
STATE_CPU=""
STATE_DISK=""
STATE_IMAGE=""
STATE_IMAGE_ID=""
STATE_UUID=""

PREV_UUID=""
VM_EXISTS=0
MARKER_FOUND=0

# ==================== LOGGING ===================================

log()  {
    printf '\033[1;34m>>\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m!!\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?

    warn "Script failed with exit code $exit_code."

    if [[ "$COMPOSE_STARTED" -eq 1 && -f "$COMPOSE_FILE" ]]; then
        warn "Container diagnostics:"
        warn "  cd '$DATA_DIR' && docker compose ps"
        warn "  cd '$DATA_DIR' && docker compose logs --tail=100"
    fi

    exit "$exit_code"
}

trap on_error ERR

# ==================== HELP ======================================

show_help() {
    cat <<'EOF'
Usage:
  ./my-tinyinstaller.sh

Environment variables:

  WIN_VERSION
      2025 | 2022 | 2019 | 2016 | 11 | 10
      Default: 2022

  RDP_USER
      Windows username.
      Default: admin

  DISK_SIZE
      Initial/effective requested disk size.
      Example: 64G
      Default: 64G

  RAM_SIZE
      Example: 8G or 4096M
      Default: 8G

  CPU_CORES
      Positive integer.
      Default: 4

  DATA_DIR
      Persistent VM directory.
      Default: $HOME/windows-vm

  BIND_ADDR
      Must remain 127.0.0.1.
      Remote access should use an SSH tunnel.

  RDP_WAIT_SECONDS
      Maximum bootstrap wait time.
      Default: 2700

  AUTO_YES=1
      Automatically answer ordinary yes/no prompts.

  ALLOW_DESTRUCTIVE=1
      Required together with AUTO_YES=1 for destructive
      Windows-version replacement.

Examples:

  WIN_VERSION=2022 ./my-tinyinstaller.sh

  RAM_SIZE=16G CPU_CORES=8 ./my-tinyinstaller.sh

  DATA_DIR=/srv/windows-vm ./my-tinyinstaller.sh

Security:
  The Dockur PASSWORD environment variable is used because that is
  the documented configuration interface. Therefore the Windows
  password can be visible through Docker metadata such as inspect.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# ==================== DEPENDENCIES ==============================

require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' not found."
}

require_cmd awk
require_cmd cat
require_cmd chmod
require_cmd date
require_cmd docker
require_cmd find
require_cmd grep
require_cmd id
require_cmd mkdir
require_cmd mktemp
require_cmd mv
require_cmd od
require_cmd rm
require_cmd stat
require_cmd tr

require_cmd xfreerdp

[[ -e /dev/kvm ]] ||
    die "/dev/kvm is missing. Enable Intel VT-x/AMD-V or nested virtualization."

[[ -r /dev/kvm && -w /dev/kvm ]] ||
    die "/dev/kvm is not readable/writable by the current user. Check KVM group membership."

[[ -e /dev/net/tun ]] ||
    die "/dev/net/tun is missing. Load the tun module if appropriate: sudo modprobe tun"

docker info >/dev/null 2>&1 ||
    die "Cannot communicate with the Docker daemon."

docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 plugin not found."

# ==================== INPUT VALIDATION ==========================

[[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]] ||
    die "CPU_CORES must be a positive integer."

[[ "$RAM_SIZE" =~ ^[1-9][0-9]*[GM]$ ]] ||
    die "RAM_SIZE must be like '8G' or '4096M'."

[[ "$DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]] ||
    die "DISK_SIZE must be like '64G' or '128G'."

[[ "$BIND_ADDR" == "127.0.0.1" ]] ||
    die "BIND_ADDR must be 127.0.0.1. Use SSH tunneling for remote access."

[[ "$RDP_USER" =~ ^[a-zA-Z0-9_-]+$ ]] ||
    die "RDP_USER contains invalid characters."

[[ "$RDP_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    die "RDP_WAIT_SECONDS must be a positive integer."

case " ${SUPPORTED_VERSIONS[*]} " in
    *" $WIN_VERSION "*) ;;
    *)
        die "Unsupported WIN_VERSION='$WIN_VERSION'. Supported: ${SUPPORTED_VERSIONS[*]}"
        ;;
esac

# ==================== IMAGE VALIDATION ==========================

if [[ "$WINDOWS_IMAGE" == *"REPLACE_WITH_VERIFIED_DIGEST"* ]]; then
    die "WINDOWS_IMAGE contains a placeholder digest.

Run:

  docker buildx imagetools inspect dockurr/windows:6.04

Then set WINDOWS_IMAGE to the exact verified repository/tag@sha256:digest."
fi

[[ "$WINDOWS_IMAGE" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]] ||
    die "WINDOWS_IMAGE must have the form repository:tag@sha256:<64 hex characters>."

EXPECTED_DIGEST="${WINDOWS_IMAGE##*@}"
IMAGE_REPOSITORY="${WINDOWS_IMAGE%@*}"
EXPECTED_REPO_DIGEST="${IMAGE_REPOSITORY}@${EXPECTED_DIGEST}"

# ==================== DATA DIR SAFETY ===========================

[[ -n "$DATA_DIR" ]] ||
    die "DATA_DIR cannot be empty."

[[ "$DATA_DIR" != "/" ]] ||
    die "DATA_DIR cannot be /."

[[ "$DATA_DIR" != "$HOME" ]] ||
    die "DATA_DIR cannot be HOME."

if [[ -e "$DATA_DIR" ]]; then
    [[ ! -L "$DATA_DIR" ]] ||
        die "DATA_DIR must not be a symlink."

    [[ -O "$DATA_DIR" ]] ||
        die "DATA_DIR must be owned by the current user (uid=$(id -u))."
fi

mkdir -p "$DATA_DIR"

[[ ! -L "$DATA_DIR" ]] ||
    die "DATA_DIR became a symlink."

[[ -O "$DATA_DIR" ]] ||
    die "DATA_DIR is not owned by the current user."

cd "$DATA_DIR"

data_dir_mode="$(stat -c '%a' "$DATA_DIR" 2>/dev/null || true)"

if [[ -n "$data_dir_mode" ]]; then
    # Last and second-last octal permission digits must not contain
    # group/world write bits.
    if [[ "${data_dir_mode: -1}" =~ [2367] ]] ||
       [[ "${data_dir_mode: -2:1}" =~ [2367] ]]; then
        die "DATA_DIR ($DATA_DIR) is group/world-writable (mode $data_dir_mode)."
    fi
fi

CRED_FILE="$DATA_DIR/credentials.txt"
STATE_FILE="$DATA_DIR/.state"
MARKER_FILE="$DATA_DIR/.vm-marker"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"

# ==================== FILE SAFETY ==============================

assert_regular_owned_file() {
    local file=$1

    [[ -e "$file" ]] || return 1
    [[ ! -L "$file" ]] ||
        die "Refusing to use symlinked file: $file"

    [[ -f "$file" ]] ||
        die "Expected regular file: $file"

    [[ -O "$file" ]] ||
        die "File is not owned by current user: $file"
}

atomic_write() {
    local target=$1
    local content=$2
    local dir
    local tmp

    dir="$(dirname "$target")"

    mkdir -p "$dir"

    [[ ! -L "$target" ]] ||
        die "Refusing to replace symlink: $target"

    tmp="$(mktemp -p "$dir" '.tmp.XXXXXXXX')" ||
        die "Cannot create temporary file in $dir"

    chmod 600 "$tmp"

    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f -- "$tmp"
        die "Failed writing temporary file."
    fi

    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        die "Failed replacing $target."
    fi

    chmod 600 "$target"
}

# ==================== PASSWORD GENERATION ======================

urandom_index() {
    local range=$1

    (( range > 0 && range <= 65536 )) ||
        return 1

    local max=$((65536 - (65536 % range)))
    local r

    while :; do
        r="$(od -An -N2 -tu2 < /dev/urandom | tr -d '[:space:]')" ||
            return 1

        [[ "$r" =~ ^[0-9]+$ ]] ||
            continue

        if (( r < max )); then
            printf '%s' "$((r % range))"
            return 0
        fi
    done
}

generate_password() {
    local lower='abcdefghijkmnopqrstuvwxyz'
    local upper='ABCDEFGHJKLMNPQRSTUVWXYZ'
    local digit='23456789'
    local special='!@#%^&*()-_=+'
    local all="${lower}${upper}${digit}${special}"

    local -a chars=()
    local i
    local j
    local n
    local tmp
    local pw=""

    chars+=( "${lower:$(urandom_index "${#lower}"):1}" )
    chars+=( "${upper:$(urandom_index "${#upper}"):1}" )
    chars+=( "${digit:$(urandom_index "${#digit}"):1}" )
    chars+=( "${special:$(urandom_index "${#special}"):1}" )

    for ((i=4; i<24; i++)); do
        chars+=( "${all:$(urandom_index "${#all}"):1}" )
    done

    n=${#chars[@]}

    # Fisher-Yates shuffle.
    for ((i=n-1; i>0; i--)); do
        j="$(urandom_index "$((i+1))")"

        tmp="${chars[$i]}"
        chars[$i]="${chars[$j]}"
        chars[$j]="$tmp"
    done

    for ((i=0; i<n; i++)); do
        pw+="${chars[$i]}"
    done

    printf '%s' "$pw"
}

validate_password() {
    local pw=$1

    [[ ${#pw} -ge 16 ]] ||
        return 1

    [[ "$pw" =~ [a-z] ]] ||
        return 1

    [[ "$pw" =~ [A-Z] ]] ||
        return 1

    [[ "$pw" =~ [0-9] ]] ||
        return 1

    [[ "$pw" =~ [\!\@\#\%\^\&\*\(\)\-\_\=\+] ]] ||
        return 1

    return 0
}

# ==================== INTERACTIVE CONFIRMATION ==================

require_tty_for_prompt() {
    [[ -t 0 && -t 1 ]] ||
        die "This operation requires an interactive terminal."
}

confirm_yes_no() {
    local prompt=$1
    local answer

    if [[ "$AUTO_YES" == "1" ]]; then
        return 0
    fi

    require_tty_for_prompt

    read -r -p "$prompt" answer || {
        die "Could not read confirmation from terminal."
    }

    [[ "${answer,,}" == "y" ]]
}

confirm_destructive_delete() {
    local answer

    if [[ "$AUTO_YES" == "1" && "$ALLOW_DESTRUCTIVE" == "1" ]]; then
        warn "AUTO_YES + ALLOW_DESTRUCTIVE enabled."
        return 0
    fi

    require_tty_for_prompt

    warn ""
    warn "THIS WILL PERMANENTLY DELETE THE EXISTING WINDOWS VM."
    warn ""
    warn "Data directory:"
    warn "  $DATA_DIR/data"
    warn ""
    warn "Type the phrase exactly as shown:"
    read -r -p "  DELETE WINDOWS VM: " answer || {
        die "Could not read destructive confirmation."
    }

    [[ "$answer" == "DELETE WINDOWS VM" ]] ||
        die "Aborted."
}

# ==================== MARKER / VM DETECTION =====================

VM_EXISTS=0
PREV_UUID=""
MARKER_FOUND=0

if [[ -e "$MARKER_FILE" ]]; then
    assert_regular_owned_file "$MARKER_FILE"
    MARKER_FOUND=1

    marker_content="$(cat "$MARKER_FILE" 2>/dev/null || true)"

    if grep -q '^my-tinyinstaller-vm$' <<< "$marker_content"; then

        PREV_UUID="$(awk -F= '/^uuid=/ {print $2; exit}' <<< "$marker_content")"

        [[ "$PREV_UUID" =~ ^[a-f0-9]{32}$ ]] ||
            die "VM marker contains an invalid UUID."

    else
        warn "Marker file exists but has unexpected content."
        warn "It will not be trusted automatically."
        PREV_UUID=""
    fi
fi

if [[ -d "$DATA_DIR/data" ]]; then
    if find "$DATA_DIR/data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null |
        grep -q .; then
        VM_EXISTS=1
    fi
fi

# Existing VM data must have identity.
if [[ "$VM_EXISTS" -eq 1 ]]; then
    [[ "$MARKER_FOUND" -eq 1 ]] ||
        die "Existing VM data found but installer marker is missing."

    [[ -n "$PREV_UUID" ]] ||
        die "Existing VM data found but marker UUID is invalid/missing."

    [[ -f "$STATE_FILE" ]] ||
        die "Existing VM data found but state file is missing."

    assert_regular_owned_file "$STATE_FILE"
fi

# ==================== STATE LOADING =============================

if [[ -f "$STATE_FILE" ]]; then
    assert_regular_owned_file "$STATE_FILE"

    STATE_VERSION="$(awk -F'"' '/^STATE_VERSION=/ {print $2; exit}' "$STATE_FILE")"
    STATE_USER="$(awk -F'"' '/^STATE_USER=/ {print $2; exit}' "$STATE_FILE")"
    STATE_RAM="$(awk -F'"' '/^STATE_RAM=/ {print $2; exit}' "$STATE_FILE")"
    STATE_CPU="$(awk -F'"' '/^STATE_CPU=/ {print $2; exit}' "$STATE_FILE")"
    STATE_DISK="$(awk -F'"' '/^STATE_DISK=/ {print $2; exit}' "$STATE_FILE")"
    STATE_IMAGE="$(awk -F'"' '/^STATE_IMAGE=/ {print $2; exit}' "$STATE_FILE")"
    STATE_IMAGE_ID="$(awk -F'"' '/^STATE_IMAGE_ID=/ {print $2; exit}' "$STATE_FILE")"
    STATE_UUID="$(awk -F'"' '/^STATE_UUID=/ {print $2; exit}' "$STATE_FILE")"

    if [[ "$VM_EXISTS" -eq 1 ]]; then

        case " ${SUPPORTED_VERSIONS[*]} " in
            *" $STATE_VERSION "*) ;;
            *)
                die "Existing VM has invalid STATE_VERSION='$STATE_VERSION'."
                ;;
        esac

        [[ "$STATE_USER" =~ ^[a-zA-Z0-9_-]+$ ]] ||
            die "Existing VM has invalid STATE_USER='$STATE_USER'."

        [[ "$STATE_RAM" =~ ^[1-9][0-9]*[GM]$ ]] ||
            die "Existing VM has invalid STATE_RAM='$STATE_RAM'."

        [[ "$STATE_CPU" =~ ^[1-9][0-9]*$ ]] ||
            die "Existing VM has invalid STATE_CPU='$STATE_CPU'."

        [[ "$STATE_DISK" =~ ^[1-9][0-9]*[GM]$ ]] ||
            die "Existing VM has invalid STATE_DISK='$STATE_DISK'."

        [[ "$STATE_IMAGE" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]] ||
            die "Existing VM has invalid STATE_IMAGE."

        [[ -n "$STATE_IMAGE_ID" ]] ||
            die "Existing VM has empty STATE_IMAGE_ID."

        [[ "$STATE_UUID" =~ ^[a-f0-9]{32}$ ]] ||
            die "Existing VM has invalid STATE_UUID."

        [[ -n "$PREV_UUID" ]] ||
            die "Existing VM has no valid marker UUID."

        [[ "$STATE_UUID" == "$PREV_UUID" ]] ||
            die "State UUID does not match marker UUID. Refusing to continue."
    else
        # Stale/incomplete state. Do not trust its contents as VM identity.
        case " ${SUPPORTED_VERSIONS[*]} " in
            *" $STATE_VERSION "*) ;;
            *) STATE_VERSION="" ;;
        esac

        [[ "$STATE_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || STATE_USER=""
        [[ "$STATE_RAM" =~ ^[1-9][0-9]*[GM]$ ]] || STATE_RAM=""
        [[ "$STATE_CPU" =~ ^[1-9][0-9]*$ ]] || STATE_CPU=""
        [[ "$STATE_DISK" =~ ^[1-9][0-9]*[GM]$ ]] || STATE_DISK=""

        [[ "$STATE_IMAGE" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]] ||
            STATE_IMAGE=""

        [[ -n "$STATE_IMAGE_ID" ]] || STATE_IMAGE_ID=""

        [[ "$STATE_UUID" =~ ^[a-f0-9]{32}$ ]] || STATE_UUID=""
    fi
fi

# ==================== VERSION CHANGE ============================

if [[ "$VM_EXISTS" -eq 1 &&
      -n "$STATE_VERSION" &&
      "$STATE_VERSION" != "$WIN_VERSION" ]]; then

    warn "Existing VM version : $STATE_VERSION"
    warn "Requested version   : $WIN_VERSION"

    confirm_destructive_delete

    [[ -f "$COMPOSE_FILE" ]] ||
        die "Compose file missing; refusing destructive operation."

    assert_regular_owned_file "$COMPOSE_FILE"

    # Validate compose before destructive operation.
    docker compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null ||
        die "Cannot validate compose file before destruction."

    # Verify the currently declared image matches the stored state.
    CURRENT_COMPOSE_IMAGE="$(
        awk '
            /^[[:space:]]*image:/ {
                sub(/^[[:space:]]*image:[[:space:]]*/, "", $0)
                gsub(/"/, "", $0)
                print $0
                exit
            }
        ' "$COMPOSE_FILE"
    )"

    [[ "$CURRENT_COMPOSE_IMAGE" == "$STATE_IMAGE" ]] ||
        die "Compose image does not match stored VM image. Refusing destructive operation."

    log "Stopping existing Windows container..."

    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

    log "Destroying existing Windows VM data..."

    rm -rf -- "$DATA_DIR/data"

    rm -f -- "$STATE_FILE" "$CRED_FILE" "$MARKER_FILE"

    VM_EXISTS=0
    PREV_UUID=""
    MARKER_FOUND=0

    STATE_VERSION=""
    STATE_USER=""
    STATE_RAM=""
    STATE_CPU=""
    STATE_DISK=""
    STATE_IMAGE=""
    STATE_IMAGE_ID=""
    STATE_UUID=""
fi

# ==================== IMAGE CHANGE ==============================

if [[ "$VM_EXISTS" -eq 1 &&
      -n "$STATE_IMAGE" &&
      "$STATE_IMAGE" != "$WINDOWS_IMAGE" ]]; then

    warn "Pinned image changed."
    warn "Old image:"
    warn "  $STATE_IMAGE"
    warn "New image:"
    warn "  $WINDOWS_IMAGE"
    warn ""
    warn "The existing Windows disk will be preserved."
    warn "The container will be recreated."

    if ! confirm_yes_no "Continue with the new image? [y/N] "; then
        die "Aborted."
    fi
fi

# ==================== EFFECTIVE CONFIG ==========================

EFFECTIVE_DISK_SIZE="$DISK_SIZE"

if [[ "$VM_EXISTS" -eq 1 ]]; then
    EFFECTIVE_DISK_SIZE="$STATE_DISK"

    if [[ "$STATE_RAM" != "$RAM_SIZE" ]]; then
        warn "RAM_SIZE changed:"
        warn "  old: $STATE_RAM"
        warn "  new: $RAM_SIZE"
        warn "The new value will be applied when the container is recreated."
    fi

    if [[ "$STATE_CPU" != "$CPU_CORES" ]]; then
        warn "CPU_CORES changed:"
        warn "  old: $STATE_CPU"
        warn "  new: $CPU_CORES"
        warn "The new value will be applied when the container is recreated."
    fi

    if [[ "$STATE_DISK" != "$DISK_SIZE" ]]; then
        warn "DISK_SIZE changed:"
        warn "  existing: $STATE_DISK"
        warn "  requested: $DISK_SIZE"

        warn "Dockur supports increasing DISK_SIZE for an existing disk."
        warn "The Windows partition may still need to be extended manually."
        warn "This installer will preserve the existing effective disk size"
        warn "instead of silently changing storage semantics."

        EFFECTIVE_DISK_SIZE="$STATE_DISK"
    fi
fi

# ==================== CREDENTIALS ===============================

if [[ "$VM_EXISTS" -eq 1 && ! -e "$CRED_FILE" ]]; then
    die "Existing VM found but credentials.txt is missing.

The password inside Windows cannot be safely reconstructed by generating
a new credential file.

Restore credentials.txt from backup or reinstall the VM."
fi

if [[ -e "$CRED_FILE" ]]; then

    assert_regular_owned_file "$CRED_FILE"

    cred_mode="$(stat -c '%a' "$CRED_FILE" 2>/dev/null || true)"

    if [[ "$cred_mode" != "600" ]]; then
        warn "credentials.txt permissions are $cred_mode."
        warn "Normalizing to 600."
        chmod 600 "$CRED_FILE"
    fi

    CRED_USER="$(
        awk -F': *' '/^Username:/ {print $2; exit}' "$CRED_FILE" || true
    )"

    RDP_PASSWORD="$(
        awk -F': *' '/^Password:/ {print $2; exit}' "$CRED_FILE" || true
    )"

    [[ "$CRED_USER" =~ ^[a-zA-Z0-9_-]+$ ]] ||
        die "credentials.txt contains an invalid username."

    [[ -n "$RDP_PASSWORD" ]] ||
        die "credentials.txt contains no password."

    validate_password "$RDP_PASSWORD" ||
        die "Password stored in credentials.txt failed validation."

    if [[ "$VM_EXISTS" -eq 1 ]]; then

        if [[ -n "$STATE_USER" &&
              "$STATE_USER" != "$CRED_USER" ]]; then
            die "State user '$STATE_USER' does not match credentials user '$CRED_USER'."
        fi

        EFFECTIVE_USER="$CRED_USER"

        log "Reusing credentials for existing VM."
        log "Windows username: $EFFECTIVE_USER"

    else

        warn "credentials.txt exists but no existing VM data was found."
        warn "The credentials are treated as stale."

        if ! confirm_yes_no "Regenerate credentials for a fresh installation? [y/N] "; then
            die "Aborted."
        fi

        EFFECTIVE_USER="$RDP_USER"
        RDP_PASSWORD="$(generate_password)"

        validate_password "$RDP_PASSWORD" ||
            die "Generated password failed validation."

        atomic_write "$CRED_FILE" "Username: $EFFECTIVE_USER
Password: $RDP_PASSWORD"
    fi

else

    log "Generating secure random RDP password..."

    EFFECTIVE_USER="$RDP_USER"
    RDP_PASSWORD="$(generate_password)"

    validate_password "$RDP_PASSWORD" ||
        die "Generated password failed validation."

    atomic_write "$CRED_FILE" "Username: $EFFECTIVE_USER
Password: $RDP_PASSWORD"
fi

# ==================== INSTALL UUID ==============================

if [[ "$VM_EXISTS" -eq 1 && -n "$PREV_UUID" ]]; then
    INSTALL_UUID="$PREV_UUID"
else
    INSTALL_UUID="$(
        od -An -N16 -tx1 < /dev/urandom |
        tr -d '[:space:]'
    )"

    [[ "$INSTALL_UUID" =~ ^[a-f0-9]{32}$ ]] ||
        die "Failed to generate a valid installation UUID."
fi

# ==================== COMPOSE CONTENT ===========================

# NOTE:
# Dockur's documented environment-variable interface uses PASSWORD.
# Do not replace this with PASSWORD_FILE unless the exact pinned image
# is verified to support that variable.
#
# The password therefore exists in Docker configuration/environment metadata.
# This is acceptable only under the intended single-user/local-host security model.

COMPOSE_CONTENT=$(cat <<YAML
services:
  windows:
    image: ${WINDOWS_IMAGE}

    labels:
      com.mytinyinstaller.managed: "true"
      com.mytinyinstaller.uuid: "${INSTALL_UUID}"
      com.mytinyinstaller.version: "1"

    environment:
      VERSION: "${WIN_VERSION}"
      USERNAME: "${EFFECTIVE_USER}"
      PASSWORD: "${RDP_PASSWORD}"
      RAM_SIZE: "${RAM_SIZE}"
      CPU_CORES: "${CPU_CORES}"
      DISK_SIZE: "${EFFECTIVE_DISK_SIZE}"
      LANGUAGE: "English"
      REGION: "en-US"
      KEYBOARD: "en-US"

    devices:
      - /dev/kvm
      - /dev/net/tun

    cap_add:
      - NET_ADMIN

    ports:
      - "${BIND_ADDR}:3389:3389/tcp"
      - "${BIND_ADDR}:3389:3389/udp"
      - "${BIND_ADDR}:8006:8006/tcp"

    volumes:
      - ./data:/storage

    restart: unless-stopped
    stop_grace_period: 2m
YAML
)

atomic_write "$COMPOSE_FILE" "$COMPOSE_CONTENT"

# ==================== COMPOSE VALIDATION ========================

log "Validating Docker Compose configuration..."

docker compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null ||
    die "Docker Compose configuration is invalid."

# ==================== IMAGE PULL ================================

log "Pulling pinned Windows image..."

docker pull "$WINDOWS_IMAGE" ||
    die "Failed to pull $WINDOWS_IMAGE"

PULLED_DIGESTS="$(
    docker image inspect "$WINDOWS_IMAGE" \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' \
        2>/dev/null || true
)"

[[ -n "$PULLED_DIGESTS" ]] ||
    die "Could not inspect repository digest for $WINDOWS_IMAGE."

if ! grep -Fxq "$EXPECTED_REPO_DIGEST" <<< "$PULLED_DIGESTS"; then

    warn "Expected repository digest:"
    warn "  $EXPECTED_REPO_DIGEST"

    warn "Actual repository digests:"

    while IFS= read -r digest; do
        [[ -n "$digest" ]] && warn "  $digest"
    done <<< "$PULLED_DIGESTS"

    die "Image repository digest mismatch."
fi

log "Repository digest verified:"
log "  $EXPECTED_REPO_DIGEST"

RESOLVED_IMAGE_ID="$(
    docker image inspect "$WINDOWS_IMAGE" \
        --format '{{.Id}}' \
        2>/dev/null || true
)"

[[ -n "$RESOLVED_IMAGE_ID" ]] ||
    die "Could not resolve local image ID."

log "Resolved image ID:"
log "  $RESOLVED_IMAGE_ID"

# ==================== EXISTING CONTAINER IDENTITY ===============

verify_existing_container_identity() {

    local container_id
    local managed
    local uuid

    container_id="$(
        docker compose -f "$COMPOSE_FILE" ps -aq windows 2>/dev/null || true
    )"

    [[ -n "$container_id" ]] || return 0

    managed="$(
        docker inspect \
            --format '{{index .Config.Labels "com.mytinyinstaller.managed"}}' \
            "$container_id" 2>/dev/null || true
    )"

    uuid="$(
        docker inspect \
            --format '{{index .Config.Labels "com.mytinyinstaller.uuid"}}' \
            "$container_id" 2>/dev/null || true
    )"

    if [[ "$managed" != "true" ]]; then
        die "A Docker container already exists for this Compose project but is not identified as managed by this installer."
    fi

    if [[ -z "$INSTALL_UUID" || "$uuid" != "$INSTALL_UUID" ]]; then
        die "Existing Docker container UUID does not match installer UUID."
    fi
}

if [[ "$VM_EXISTS" -eq 1 ]]; then
    verify_existing_container_identity
fi

# ==================== MARKER ====================================

# Marker is created immediately before container creation, but only
# after validation, credentials, state, image, and compose are ready.

if [[ "$VM_EXISTS" -eq 0 ]]; then
    atomic_write "$MARKER_FILE" "my-tinyinstaller-vm
format=1
uuid=${INSTALL_UUID}"
fi

# ==================== START VM ==================================

if [[ "$VM_EXISTS" -eq 1 ]]; then

    log "Recreating existing Windows container..."

    docker compose -f "$COMPOSE_FILE" up -d --force-recreate ||
        die "Failed to recreate Windows container."

else

    log "Starting Windows $WIN_VERSION installation..."

    docker compose -f "$COMPOSE_FILE" up -d ||
        die "Failed to start Windows container."
fi

COMPOSE_STARTED=1

# ==================== VERIFY CONTAINER IDENTITY =================

CONTAINER_ID="$(
    docker compose -f "$COMPOSE_FILE" ps -q windows 2>/dev/null || true
)"

[[ -n "$CONTAINER_ID" ]] ||
    die "Windows container was not created."

MANAGED_LABEL="$(
    docker inspect \
        --format '{{index .Config.Labels "com.mytinyinstaller.managed"}}' \
        "$CONTAINER_ID" 2>/dev/null || true
)"

CONTAINER_UUID="$(
    docker inspect \
        --format '{{index .Config.Labels "com.mytinyinstaller.uuid"}}' \
        "$CONTAINER_ID" 2>/dev/null || true
)"

[[ "$MANAGED_LABEL" == "true" ]] ||
    die "Container is missing the installer management label."

[[ "$CONTAINER_UUID" == "$INSTALL_UUID" ]] ||
    die "Container UUID does not match installer UUID."

# ==================== RDP CHECK =================================

rdp_auth_check() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4

    local tmp_log
    local rc

    tmp_log="$(
        mktemp "${TMPDIR:-/tmp}/freerdp-log-XXXXXX"
    )" || return 125

    chmod 600 "$tmp_log"

    rc=0

    if xfreerdp \
        "/v:${host}:${port}" \
        /cert:ignore \
        /auth-only \
        "/u:${user}" \
        "/p:${pass}" \
        >"$tmp_log" 2>&1
    then
        rc=0
    else
        rc=$?
    fi

    # Preserve a compact diagnostic if useful.
    if [[ "$rc" -ne 0 ]]; then
        tail -n 10 "$tmp_log" >&2 || true
    fi

    rm -f -- "$tmp_log"

    return "$rc"
}

log "Waiting for successful RDP authentication."
log "Timeout: ${RDP_WAIT_SECONDS}s"

deadline=$(( $(date +%s) + RDP_WAIT_SECONDS ))
ready=0

while (( $(date +%s) < deadline )); do

    # Compose v2 compatibility:
    # `docker compose ps -q` is intentionally used rather than relying
    # on `--status running`, which varies across Compose versions.

    running_container="$(
        docker compose -f "$COMPOSE_FILE" ps -q windows 2>/dev/null || true
    )"

    if [[ -z "$running_container" ]]; then
        warn "Windows container is not currently running."
        warn "Checking again in 15 seconds..."
        sleep 15
        continue
    fi

    container_state="$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$CONTAINER_ID" 2>/dev/null || true
    )"

    if [[ "$container_state" != "running" ]]; then
        warn "Container state is '$container_state'."
        warn "Checking again in 15 seconds..."
        sleep 15
        continue
    fi

    # Do NOT classify FreeRDP numeric exit codes as permanently fatal.
    # FreeRDP versions/platforms can report authentication/protocol/
    # connection failures differently during Windows bootstrap.
    if rdp_auth_check \
        127.0.0.1 \
        3389 \
        "$EFFECTIVE_USER" \
        "$RDP_PASSWORD"; then

        ready=1
        VERIFIED_AUTH=1
        break
    fi

    sleep 15
done

if [[ "$ready" -ne 1 ]]; then

    warn "RDP authentication did not succeed within ${RDP_WAIT_SECONDS}s."
    warn ""
    warn "Inspect:"
    warn "  cd '$DATA_DIR' && docker compose ps"
    warn "  cd '$DATA_DIR' && docker compose logs --tail=200"
    warn ""
    warn "Web console:"
    warn "  http://127.0.0.1:8006"

    exit 1
fi

# ==================== FINAL IMAGE CHECK ==========================

FINAL_IMAGE_ID="$(
    docker inspect \
        --format '{{.Image}}' \
        "$CONTAINER_ID" 2>/dev/null || true
)"

[[ -n "$FINAL_IMAGE_ID" ]] ||
    die "Could not determine final container image ID."

if [[ "$FINAL_IMAGE_ID" != "$RESOLVED_IMAGE_ID" ]]; then
    die "Container image ID does not match the pulled verified image.

Expected:
  $RESOLVED_IMAGE_ID

Actual:
  $FINAL_IMAGE_ID"
fi

# ==================== STATE WRITE ===============================

STATE_CONTENT=$(cat <<STATE
STATE_VERSION="$WIN_VERSION"
STATE_USER="$EFFECTIVE_USER"
STATE_RAM="$RAM_SIZE"
STATE_CPU="$CPU_CORES"
STATE_DISK="$EFFECTIVE_DISK_SIZE"
STATE_IMAGE="$WINDOWS_IMAGE"
STATE_IMAGE_ID="$RESOLVED_IMAGE_ID"
STATE_UUID="$INSTALL_UUID"
STATE_INSTALLED_AT="$(date -Iseconds)"
STATE_LAST_RDP_CHECK="$(date -Iseconds)"
STATE_RDP_VERIFIED="1"
STATE
)

atomic_write "$STATE_FILE" "$STATE_CONTENT"

# ==================== FINAL MARKER VALIDATION ====================

assert_regular_owned_file "$MARKER_FILE"

FINAL_MARKER_UUID="$(
    awk -F= '/^uuid=/ {print $2; exit}' "$MARKER_FILE"
)"

[[ "$FINAL_MARKER_UUID" == "$INSTALL_UUID" ]] ||
    die "Final marker UUID does not match installation UUID."

# ==================== FINAL REPORT ==============================

cat <<EOF

==================================================
  Windows $WIN_VERSION is ready
  RDP authentication verified
==================================================

  RDP Address : localhost:3389
  Username    : ${EFFECTIVE_USER}

  Web Console : http://localhost:8006

  Credentials:
    ${CRED_FILE}

  View credentials:
    less '${CRED_FILE}'

  Connect via RDP:
    xfreerdp /v:localhost /u:${EFFECTIVE_USER} /cert:ignore /f

  SSH tunnel from your local machine:
    ssh -L 3389:localhost:3389 -L 8006:localhost:8006 user@YOUR_SERVER

  Replace YOUR_SERVER with your server's SSH hostname/IP.

--------------------------------------------------

  Requested disk size : ${DISK_SIZE}
  Effective disk size : ${EFFECTIVE_DISK_SIZE}

  RAM                  : ${RAM_SIZE}
  CPU cores            : ${CPU_CORES}

  Image:
    ${WINDOWS_IMAGE}

  Image ID:
    ${RESOLVED_IMAGE_ID}

  Installation UUID:
    ${INSTALL_UUID}

  State:
    ${STATE_FILE}

  VM data:
    ${DATA_DIR}/data

--------------------------------------------------

  Stop VM:
    (cd '${DATA_DIR}' && docker compose down)

  Start VM:
    (cd '${DATA_DIR}' && docker compose up -d)

  Logs:
    (cd '${DATA_DIR}' && docker compose logs -f)

==================================================

IMPORTANT SECURITY NOTE:

  The Dockur PASSWORD setting is supplied through Docker environment
  configuration. Therefore the password may be visible to users/processes
  with sufficient Docker access.

  Keep Docker access restricted on shared systems.

==================================================
EOF
