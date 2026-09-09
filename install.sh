#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.0"
KIOSK_USER="autodarts"
AUTODARTS_URL="https://play.autodarts.io"
FALLBACK_DRM_CONNECTOR="HDMI-A-2"
CONSOLE_MODE="1920x1080@60e"
INSTALL_EXTENSION=1
ENABLE_AMD_IOMMU=0
ASSUME_YES=0
CHECK_ONLY=0

TOOLS_EXTENSION_ID="oolfddhehmbpdnlmoljmllcdggmkgihh"
CHROME_UPDATE_URL="https://clients2.google.com/service/update2/crx"
BACKUP_ROOT="/root/autodarts-installer-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"

usage() {
    cat <<EOF
Autodarts Kiosk Installer ${VERSION}

Usage: sudo ./install.sh [options]

Options:
  --check                 Detect HDMI video/audio without changing the system
  --yes                   Run without the interactive confirmation
  --user NAME             Kiosk user (default: autodarts)
  --url URL               Start URL (default: https://play.autodarts.io)
  --connector NAME        Fallback DRM connector (default: HDMI-A-2)
  --console-mode MODE     Kernel console mode (default: 1920x1080@60e)
  --no-extension          Do not install Tools for Autodarts by policy
  --enable-amd-iommu      Add amd_iommu=on and iommu=pt to the kernel command line
  -h, --help              Show this help
EOF
}

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

parse_args() {
    while (($#)); do
        case "$1" in
            --check) CHECK_ONLY=1 ;;
            --yes) ASSUME_YES=1 ;;
            --user) shift; (($#)) || die "--user needs a value"; KIOSK_USER="$1" ;;
            --url) shift; (($#)) || die "--url needs a value"; AUTODARTS_URL="$1" ;;
            --connector) shift; (($#)) || die "--connector needs a value"; FALLBACK_DRM_CONNECTOR="$1" ;;
            --console-mode) shift; (($#)) || die "--console-mode needs a value"; CONSOLE_MODE="$1" ;;
            --no-extension) INSTALL_EXTENSION=0 ;;
            --enable-amd-iommu) ENABLE_AMD_IOMMU=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

validate_inputs() {
    [[ "$KIOSK_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $KIOSK_USER"
    [[ "$AUTODARTS_URL" =~ ^https?:// ]] || die "The URL must start with http:// or https://"
    [[ "$FALLBACK_DRM_CONNECTOR" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid DRM connector"
    [[ "$CONSOLE_MODE" =~ ^[0-9]+x[0-9]+@[0-9]+e?$ ]] || die "Invalid console mode"
}

backup_path() {
    local source="$1"
    [[ -e "$source" || -L "$source" ]] || return 0
    mkdir -p "${BACKUP_DIR}$(dirname "$source")"
    cp -a "$source" "${BACKUP_DIR}${source}"
}

detect_drm_connector() {
    local status connector_dir driver candidate=""
    for status in /sys/class/drm/card*-HDMI-A-*/status; do
        [[ -r "$status" ]] || continue
        [[ $(<"$status") == connected ]] || continue
        connector_dir="${status%/status}"
        candidate="$(basename "$connector_dir")"
        candidate="${candidate#card*-}"
        driver="$(basename "$(readlink -f "${connector_dir}/device/driver" 2>/dev/null || true)")"
        if [[ "$driver" == amdgpu ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '%s\n' "${candidate:-$FALLBACK_DRM_CONNECTOR}"
}

detect_hdmi_audio() {
    local eld card_dir monitor
    for eld in /proc/asound/card*/eld#*; do
        [[ -r "$eld" ]] || continue
        grep -Eq '^monitor_present[[:space:]]+1$' "$eld" || continue
        grep -Eq '^eld_valid[[:space:]]+1$' "$eld" || continue
        card_dir="$(basename "$(dirname "$eld")")"
        HDMI_CARD_NUM="${card_dir#card}"
        HDMI_CARD_ID="$(<"/proc/asound/${card_dir}/id")"
        HDMI_PLUGIN_DEV="${eld##*.}"
        monitor="$(awk -F '[[:space:]]{2,}' '/^monitor_name/{print $2; exit}' "$eld")"
        HDMI_MONITOR_NAME="${monitor:-HDMI monitor}"
        return 0
    done
    return 1
}

show_detection() {
    local connector
    connector="$(detect_drm_connector)"
    printf 'DRM connector: %s\n' "$connector"
    if detect_hdmi_audio; then
        printf 'HDMI audio: card %s (%s), plugin device %s, monitor %s\n' \
            "$HDMI_CARD_NUM" "$HDMI_CARD_ID" "$HDMI_PLUGIN_DEV" "$HDMI_MONITOR_NAME"
    else
        printf 'HDMI audio: no connected valid endpoint found\n'
        return 1
    fi
}

confirm_install() {
    ((ASSUME_YES)) && return
    cat <<EOF

This installer makes system-wide changes to the Proxmox host:
  - installs X.Org, Openbox, Chromium, LightDM and ALSA utilities
  - creates the user '${KIOSK_USER}' with automatic graphical login
  - changes the default systemd target to graphical.target
  - adds an HDMI console parameter to GRUB
  - configures the detected HDMI device as the default audio output
  - optionally force-installs a third-party community extension

Use a dedicated Proxmox host with physical or IPMI access. Back up the host first.
EOF
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Installation cancelled"
}

write_grub_snippet() {
    local connector="$1" iommu_args=""
    ((ENABLE_AMD_IOMMU)) && iommu_args="amd_iommu=on iommu=pt"
    cat > /etc/default/grub.d/99-autodarts-hdmi.cfg <<EOF
# Managed by proxmox-autodarts-kiosk ${VERSION}
for autodarts_arg in video=${connector}:${CONSOLE_MODE} ${iommu_args}; do
    case " \${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
        *" \${autodarts_arg} "*) ;;
        *) GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT:-} \${autodarts_arg}" ;;
    esac
done
unset autodarts_arg
EOF
}

main() {
    parse_args "$@"
    require_root
    validate_inputs

    [[ -r /etc/os-release ]] || die "Cannot identify the operating system"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian || ${ID_LIKE:-} == *debian* ]] || die "Debian/Proxmox VE is required"

    log "Hardware detection"
    show_detection || {
        warn "Turn the connected HDMI monitor on and retry."
        ((CHECK_ONLY)) && exit 1
    }
    ((CHECK_ONLY)) && exit 0

    confirm_install
    printf '%s\n' \
        "Set these options on the monitor before rebooting:" \
        "  HDMI Compatibility Mode: ON" \
        "  Aspect Ratio: Full Wide / Vollbild"

    mkdir -p "$BACKUP_DIR"
    backup_path /etc/default/grub
    backup_path /etc/default/grub.d/99-autodarts-hdmi.cfg
    backup_path /etc/asound.conf
    backup_path /etc/lightdm/lightdm.conf.d/50-autodarts.conf
    backup_path /etc/chromium/policies/managed/autodarts-tools.json
    backup_path /var/lib/alsa/asound.state
    backup_path "/home/${KIOSK_USER}/.config/openbox/autostart"
    backup_path /usr/local/bin/autodarts

    log "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y xserver-xorg xinit x11-xserver-utils openbox chromium lightdm alsa-utils
    systemctl stop lightdm.service 2>/dev/null || true

    local connector
    connector="$(detect_drm_connector)"
    log "Configuring GRUB for ${connector}:${CONSOLE_MODE}"
    mkdir -p /etc/default/grub.d
    write_grub_snippet "$connector"
    update-grub

    log "Configuring HDMI audio"
    detect_hdmi_audio || die "HDMI audio disappeared during installation; check the monitor and rerun"
    cat > /etc/asound.conf <<EOF
# Managed by proxmox-autodarts-kiosk ${VERSION}
pcm.!default {
    type plug
    slave.pcm "hdmi:CARD=${HDMI_CARD_ID},DEV=${HDMI_PLUGIN_DEV}"
}
ctl.!default {
    type hw
    card "${HDMI_CARD_ID}"
}
EOF
    amixer -c "$HDMI_CARD_NUM" sset IEC958,"$HDMI_PLUGIN_DEV" unmute
    alsactl store

    log "Creating user ${KIOSK_USER}"
    id "$KIOSK_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$KIOSK_USER"
    groupadd -f autologin
    usermod -aG audio,video,input,render,autologin "$KIOSK_USER"
    install -d -o "$KIOSK_USER" -g "$KIOSK_USER" \
        "/home/${KIOSK_USER}/.config/openbox" \
        "/home/${KIOSK_USER}/.config/chromium-autodarts"

    cat > "/home/${KIOSK_USER}/.config/openbox/autostart" <<EOF
#!/bin/sh
xset s off
xset -dpms
xset s noblank

X_OUTPUT="\$(xrandr --query | awk '/ connected/{print \$1; exit}')"
if [ -n "\$X_OUTPUT" ]; then
    xrandr --output "\$X_OUTPUT" --auto --primary
fi

amixer -c ${HDMI_CARD_NUM} sset IEC958,${HDMI_PLUGIN_DEV} unmute
chromium \\
  --user-data-dir=/home/${KIOSK_USER}/.config/chromium-autodarts \\
  --start-fullscreen \\
  --no-first-run \\
  --disable-session-crashed-bubble \\
  --autoplay-policy=no-user-gesture-required \\
  --alsa-output-device=hdmi:CARD=${HDMI_CARD_ID},DEV=${HDMI_PLUGIN_DEV} \\
  ${AUTODARTS_URL} &
EOF
    chown "$KIOSK_USER:$KIOSK_USER" "/home/${KIOSK_USER}/.config/openbox/autostart"
    chmod 0755 "/home/${KIOSK_USER}/.config/openbox/autostart"

    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-autodarts.conf <<EOF
[Seat:*]
autologin-user=${KIOSK_USER}
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
EOF

    if ((INSTALL_EXTENSION)); then
        log "Configuring Tools for Autodarts extension policy"
        mkdir -p /etc/chromium/policies/managed
        cat > /etc/chromium/policies/managed/autodarts-tools.json <<EOF
{
  "ExtensionInstallForcelist": [
    "${TOOLS_EXTENSION_ID};${CHROME_UPDATE_URL}"
  ]
}
EOF
    fi

    cat > /usr/local/bin/autodarts <<'EOF'
#!/bin/sh
exec systemctl restart lightdm.service
EOF
    chmod 0755 /usr/local/bin/autodarts

    cat > /etc/autodarts-kiosk.conf <<EOF
VERSION=${VERSION}
KIOSK_USER=${KIOSK_USER}
AUTODARTS_URL=${AUTODARTS_URL}
DRM_CONNECTOR=${connector}
CONSOLE_MODE=${CONSOLE_MODE}
HDMI_CARD_NUM=${HDMI_CARD_NUM}
HDMI_CARD_ID=${HDMI_CARD_ID}
HDMI_PLUGIN_DEV=${HDMI_PLUGIN_DEV}
BACKUP_DIR=${BACKUP_DIR}
EOF

    systemctl enable lightdm.service
    systemctl set-default graphical.target

    log "Installation complete"
    printf '%s\n' \
        "Backup: ${BACKUP_DIR}" \
        "Reboot to start Autodarts: reboot" \
        "Console: Ctrl+Alt+F2 | Browser: Ctrl+Alt+F7" \
        "Browser controls: F11 and Ctrl+L" \
        "Restart the graphical session as root: autodarts" \
        "Sign in to Autodarts once after the first boot."
}

main "$@"
