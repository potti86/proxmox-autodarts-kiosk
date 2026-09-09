# Proxmox Autodarts Kiosk

Community installer for displaying [Autodarts Play](https://play.autodarts.io) on a monitor connected directly to a Proxmox VE host. It sets up a minimal Openbox/Chromium session with HDMI video, HDMI audio and optional installation of the community **Tools for Autodarts** browser extension.

> [!WARNING]
> This project installs a graphical desktop stack and automatic login on the Proxmox VE host itself. That increases the host's package count and attack surface. Use it only when the physical display is an intentional part of your homelab design. Back up the host and keep physical or IPMI access available.

## What it configures

- Detects a connected HDMI DRM connector, preferring an AMD GPU
- Adds a conservative forced mode for the boot console
- Detects the active HDMI ALSA endpoint through ELD
- Sets HDMI audio as the ALSA default and unmutes it
- Installs X.Org, Openbox, Chromium, LightDM and ALSA utilities
- Creates an unprivileged `autodarts` user
- Starts Chromium automatically in fullscreen mode
- Keeps `F11` and `Ctrl+L` available for other websites and local IP addresses
- Optionally installs Tools for Autodarts through Chromium policy
- Backs up every replaced configuration file

The installer does **not** store Autodarts credentials. Sign in once after the first boot.

## Tested setup

The first development system used:

- Proxmox VE on Debian 13
- AMD Ryzen APU with `amdgpu`
- LG UltraWide 3440×1440 display over HDMI
- HDMI audio exposed through `snd_hda_intel`

Other combinations may work through automatic detection, but should be treated as untested.

## Monitor preparation

Before installation, configure the monitor itself:

- **HDMI Compatibility Mode:** On
- **Aspect Ratio:** Full Wide / Vollbild

Keep the HDMI monitor connected and powered on while running detection and installation.

## Quick start

Download the script on the Proxmox host and inspect it before running:

```bash
chmod +x install.sh
./install.sh --check
./install.sh
reboot
```

The installer displays all system-wide changes and asks for confirmation. Use `--yes` only for unattended provisioning.

## Options

```text
--check                 Detect HDMI video/audio without changing the system
--yes                   Skip the interactive confirmation
--user NAME             Kiosk user (default: autodarts)
--url URL               Browser start URL
--connector NAME        Fallback kernel DRM connector
--console-mode MODE     Forced boot-console mode
--no-extension          Do not install Tools for Autodarts
--enable-amd-iommu      Also add amd_iommu=on and iommu=pt
```

IOMMU is disabled by default because it is unrelated to the display setup and may not be appropriate for every host.

## Daily use

- `Ctrl+Alt+F2`: switch to the Proxmox text console
- `Ctrl+Alt+F7`: return to Autodarts
- `F11`: leave or enter browser fullscreen
- `Ctrl+L`: open another website or a local IP address
- `autodarts` as root: restart the graphical session

## Files created

```text
/etc/autodarts-kiosk.conf
/etc/asound.conf
/etc/default/grub.d/99-autodarts-hdmi.cfg
/etc/lightdm/lightdm.conf.d/50-autodarts.conf
/etc/chromium/policies/managed/autodarts-tools.json
/home/autodarts/.config/openbox/autostart
/home/autodarts/.config/chromium-autodarts/
/usr/local/bin/autodarts
```

Backups are written below `/root/autodarts-installer-backups/` before existing files are replaced.

## Troubleshooting

### Display stays black

Confirm HDMI Compatibility Mode is enabled on the monitor. From SSH:

```bash
DISPLAY=:0 xrandr --current
journalctl -u lightdm -b --no-pager
```

### No HDMI sound

Inspect detected ELD endpoints and test ALSA:

```bash
grep -H -E 'monitor_present|eld_valid|monitor_name|sad_count' /proc/asound/card*/eld*
speaker-test -c 2 -r 48000 -t sine
```

### Return to the text console

Use `Ctrl+Alt+F2`, or stop the graphical login remotely:

```bash
systemctl stop lightdm
```

## Third-party notice

[Tools for Autodarts](https://github.com/creazy231/tools-for-autodarts) is a community project and is not part of the official Autodarts platform. This installer does not bundle its code; it only configures Chromium to retrieve the published extension from the Chrome Web Store when explicitly enabled.

## Status

Version `0.1.0` is an experimental community release. Review the script and test backups before using it on a production host.

## License

MIT
