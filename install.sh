#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Feature flags (1=enabled, 0=disabled)
FEATURE_DISABLE_VNC="${FEATURE_DISABLE_VNC:-1}"
FEATURE_DISABLE_SSH="${FEATURE_DISABLE_SSH:-0}"
FEATURE_BOOT_B4="${FEATURE_BOOT_B4:-1}"
FEATURE_KIOSK_MODE="${FEATURE_KIOSK_MODE:-1}"
FEATURE_LIVI_NATIVE_KIOSK="${FEATURE_LIVI_NATIVE_KIOSK:-1}"
FEATURE_CARLINKIT_UDEV="${FEATURE_CARLINKIT_UDEV:-1}"
FEATURE_LIVI_AUTOSTART="${FEATURE_LIVI_AUTOSTART:-1}"
FEATURE_APT_UPGRADE="${FEATURE_APT_UPGRADE:-1}"
FEATURE_QUIET_BOOT="${FEATURE_QUIET_BOOT:-1}"
FEATURE_BOOT_SPLASH="${FEATURE_BOOT_SPLASH:-1}"
FEATURE_OPTIMIZE_BOOT="${FEATURE_OPTIMIZE_BOOT:-1}"
# Apple MFi coprocessor wired to GPIO 19/26 (native CarPlay without dongle)
FEATURE_LIVI_MFI="${FEATURE_LIVI_MFI:-0}"
# Output volume on first start (0.0-1.0, as wpctl/LIVI show it)
MFD_DEFAULT_VOLUME="${MFD_DEFAULT_VOLUME:-0.89}"

# LIVI release tag to install (e.g. v8.3.0), or "latest"
LIVI_VERSION="${LIVI_VERSION:-v8.3.0}"

is_enabled() {
	case "${1:-0}" in
		1|true|TRUE|yes|YES|on|ON) return 0 ;;
		*) return 1 ;;
	esac
}

# If running as root inside chroot, avoid calling sudo repeatedly.
if [ "$(id -u)" -ne 0 ]; then
	# Prefer sudo, but fall back to no-sudo if sudo cannot escalate (e.g. nosuid or chroot CI)
	if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
		SUDO=sudo
	else
		SUDO=""
	fi
else
	SUDO=""
fi

# Helper to check if we have privilege escalation
have_privileges() {
	[ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]
}

# Helper to run a command with sudo if available, or fail gracefully
run_privileged() {
	if [ -n "$SUDO" ]; then
		$SUDO "$@"
	elif [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		echo "⚠ Skipping privileged command (no sudo/root): $*" >&2
		return 0  # Non-fatal; continue installation
	fi
}

# Ensure hostname resolves to avoid "sudo: unable to resolve host" warnings
HOSTNAME=$(hostname 2>/dev/null || true)
if [ -n "$HOSTNAME" ]; then
	if ! getent hosts "$HOSTNAME" >/dev/null 2>&1; then
		if [ -w /etc/hosts ] || [ -n "$SUDO" ]; then
			# Append a safe mapping; ignore failures
			echo "127.0.1.1 $HOSTNAME" | $SUDO tee -a /etc/hosts >/dev/null || true
		fi
	fi
fi

# Update and install required packages
$SUDO apt-get update -y
if is_enabled "$FEATURE_APT_UPGRADE"; then
	$SUDO apt-get upgrade -y
fi

# LIVI core runtime deps + build/runtime utilities used by this installer.
$SUDO apt-get install -y \
	libxi-dev libx11-dev libxrandr-dev txt2man curl xdg-user-dirs \
	bluez libspa-0.2-bluetooth hostapd dnsmasq-base iw rfkill \
	python3-pip pulseaudio-utils python3-dbus python3-gi python3-smbus2 \
	avahi-daemon libva2 libva-drm2 libva-x11-2 libssh-4

# Move config if present (guard against missing file when run from CI)
if [ -f "$CONFIG_DIR/config.txt" ]; then
	# Ensure target directory exists (some images mount boot at /boot, but not /boot/firmware)
	$SUDO mkdir -p /boot/firmware
	$SUDO cp "$CONFIG_DIR/config.txt" /boot/firmware/config.txt
else
	echo "Warning: ${CONFIG_DIR}/config.txt not found, skipping move"
fi

# Helper: Prüfe, ob wir im chroot ohne systemd laufen
is_chroot_no_systemd() {
    # systemd läuft nur, wenn PID 1 systemd ist
    [ "$(ps -p 1 -o comm=)" != "systemd" ]
}

# Wrapper für systemctl/loginctl: nur ausführen, wenn systemd läuft
safe_systemctl() {
    if is_chroot_no_systemd; then
        echo "⚠ Running in chroot, skipping: systemctl $*"
        return 0
    else
        run_privileged systemctl "$@"
    fi
}
safe_loginctl() {
    if is_chroot_no_systemd; then
        echo "⚠ Running in chroot, skipping: loginctl $*"
        return 0
    else
        run_privileged loginctl "$@"
    fi
}

enable_unit_offline() {
	unit_name="$1"
	target_name="$2"
	target_dir="/etc/systemd/system/${target_name}.wants"
	unit_src="/etc/systemd/system/${unit_name}"

	if [ ! -f "$unit_src" ]; then
		echo "Warning: offline enable skipped, unit not found: $unit_src"
		return 0
	fi

	run_privileged mkdir -p "$target_dir"
	if [ ! -e "$target_dir/$unit_name" ]; then
		run_privileged ln -s "$unit_src" "$target_dir/$unit_name"
	fi
}

setup_firstboot_cloudinit_reboot() {
	echo "→ Setting up one-time reboot after initial cloud-init"

	FIRSTBOOT_UNIT="/etc/systemd/system/mfd-firstboot-reboot.service"
	MARKER_FILE="/var/lib/mfd-firstboot-reboot.done"

	run_privileged tee "$FIRSTBOOT_UNIT" >/dev/null <<EOF
[Unit]
Description=One-time reboot after first cloud-init boot
After=cloud-final.service
Wants=cloud-final.service
ConditionPathExists=/var/lib/cloud/instance/boot-finished
ConditionPathExists=!${MARKER_FILE}

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'touch ${MARKER_FILE}; touch /etc/cloud/cloud-init.disabled; systemctl disable cloud-init.service cloud-config.service cloud-final.service cloud-init-local.service cloud-init-main.service >/dev/null 2>&1 || true; systemctl --no-block reboot'

[Install]
WantedBy=cloud-init.target
EOF

	# cloud-final.service is ordered after multi-user.target, so hanging this unit
	# off multi-user.target formed an ordering cycle and systemd dropped it.
	run_privileged rm -f /etc/systemd/system/multi-user.target.wants/mfd-firstboot-reboot.service

	if is_chroot_no_systemd; then
		enable_unit_offline "mfd-firstboot-reboot.service" "cloud-init.target"
	else
		run_privileged systemctl daemon-reload
		run_privileged systemctl enable mfd-firstboot-reboot.service
	fi
}

optimize_boot_services() {
	echo "→ Applying boot-time service optimizations"

	# This unit commonly adds several seconds while waiting for full network online.
	run_privileged systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true
	run_privileged systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true

	# Printing stack is not needed for a kiosk image.
	run_privileged systemctl disable cups.service cups.path cups.socket >/dev/null 2>&1 || true
	run_privileged systemctl mask cups.service cups.path cups.socket >/dev/null 2>&1 || true

	# Periodic ext4 scrub is not useful on this appliance-style SD image.
	run_privileged systemctl disable e2scrub_reap.service e2scrub_all.timer >/dev/null 2>&1 || true
	run_privileged systemctl mask e2scrub_reap.service >/dev/null 2>&1 || true
}

setup_quiet_boot_cmdline() {
	echo "→ Applying quiet boot kernel cmdline"

	CMDLINE_FILE="/boot/firmware/cmdline.txt"
	if [ ! -f "$CMDLINE_FILE" ] && [ -f "/boot/cmdline.txt" ]; then
		CMDLINE_FILE="/boot/cmdline.txt"
	fi

	if [ ! -f "$CMDLINE_FILE" ]; then
		echo "⚠ cmdline.txt not found, skipping quiet boot setup"
		return 0
	fi

	CURRENT_CMDLINE="$(cat "$CMDLINE_FILE")"
	for token in quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 logo.nologo plymouth.ignore-serial-consoles systemd.show_status=false; do
		case " $CURRENT_CMDLINE " in
			*" $token "*) ;;
			*) CURRENT_CMDLINE="$CURRENT_CMDLINE $token" ;;
		esac
	done

	# Remove serial console to suppress most early boot text.
	CURRENT_CMDLINE="$(printf '%s\n' "$CURRENT_CMDLINE" | sed -E 's/console=serial0,[0-9]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"

	run_privileged tee "$CMDLINE_FILE" >/dev/null <<EOF
$CURRENT_CMDLINE
EOF
}

setup_plymouth_splash() {
	echo "→ Installing Plymouth splash theme"

	if ! have_privileges; then
		echo "⚠ Skipping splash setup (requires sudo/root)"
		return 0
	fi

	run_privileged apt-get install -y plymouth plymouth-themes

	THEME_NAME="mfd-carplay"
	THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"
	SOURCE_IMAGE="$SCRIPT_DIR/assets/images/install10.png"

	if [ ! -f "$SOURCE_IMAGE" ]; then
		SOURCE_IMAGE="$SCRIPT_DIR/assets/images/install3.png"
	fi

	if [ ! -f "$SOURCE_IMAGE" ]; then
		echo "⚠ No splash image found in assets/images, skipping Plymouth theme"
		return 0
	fi

	run_privileged mkdir -p "$THEME_DIR"
	run_privileged cp "$SOURCE_IMAGE" "$THEME_DIR/splash.png"

	run_privileged tee "$THEME_DIR/${THEME_NAME}.plymouth" >/dev/null <<EOF
[Plymouth Theme]
Name=MFD CarPlay
Description=MFD CarPlay boot splash
ModuleName=script

[script]
ImageDir=$THEME_DIR
ScriptFile=$THEME_DIR/${THEME_NAME}.script
EOF

	run_privileged tee "$THEME_DIR/${THEME_NAME}.script" >/dev/null <<'EOF'
Window.SetBackgroundTopColor(0.0, 0.0, 0.0);
Window.SetBackgroundBottomColor(0.0, 0.0, 0.0);

logo = Image("splash.png");
sprite = Sprite(logo);
sprite.SetX((Window.GetWidth() - logo.GetWidth()) / 2);
sprite.SetY((Window.GetHeight() - logo.GetHeight()) / 2);
EOF

	if command -v plymouth-set-default-theme >/dev/null 2>&1; then
		run_privileged plymouth-set-default-theme "$THEME_NAME" -R || true
	else
		echo "⚠ plymouth-set-default-theme not found, trying update-initramfs directly"
		run_privileged update-initramfs -u || true
	fi
}

setup_livi_native_kiosk() {
	echo "→ Setting up LIVI native kiosk (tty1 + cage)"

	run_privileged apt-get install -y cage seatd wlr-randr pipewire pipewire-pulse wireplumber

	# LIVI 8.x is an Electron app: the binary links GTK3/NSS/CUPS/X11 directly,
	# none of which ship with Pi OS Lite. Without them LIVI exits immediately and
	# the kiosk falls back to the tty1 shell.
	# Trixie renamed several libs with a t64 suffix, so pick whichever exists.
	ELECTRON_DEPS=""
	for pkg in libgtk-3-0 libnss3 libcups2 libgbm1 libasound2 libatspi2.0-0 \
		libxss1 libxtst6 libnotify4 libsecret-1-0 libdrm2 libxkbcommon0; do
		if apt-cache show "${pkg}t64" >/dev/null 2>&1; then
			ELECTRON_DEPS="$ELECTRON_DEPS ${pkg}t64"
		else
			ELECTRON_DEPS="$ELECTRON_DEPS $pkg"
		fi
	done
	echo "→ Installing LIVI Electron runtime libraries:$ELECTRON_DEPS"
	# shellcheck disable=SC2086
	run_privileged apt-get install -y --no-install-recommends $ELECTRON_DEPS

	if id -u pi >/dev/null 2>&1; then
		run_privileged usermod -aG video,render,input,plugdev pi || true
	fi

	GETTY_DROPIN="/etc/systemd/system/getty@tty1.service.d/livi-autologin.conf"
	KIOSK_UNIT="/etc/systemd/system/livi-kiosk.service"
	KIOSK_PAM="/etc/pam.d/livi-kiosk"
	AGETTY_BIN="$(command -v agetty || echo /sbin/agetty)"
	CAGE_BIN="$(command -v cage || echo /usr/bin/cage)"
	SYSTEMCTL_BIN="$(command -v systemctl || echo /usr/bin/systemctl)"

	run_privileged mkdir -p "$(dirname "$GETTY_DROPIN")"
	run_privileged tee "$GETTY_DROPIN" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-$AGETTY_BIN --autologin pi --noclear %I \$TERM
EOF

	run_privileged tee "$KIOSK_PAM" >/dev/null <<'EOF'
auth      required  pam_permit.so
@include  common-account
@include  common-session
EOF

	run_privileged tee "$KIOSK_UNIT" >/dev/null <<EOF
[Unit]
Description=LIVI kiosk
After=systemd-user-sessions.service seatd.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=pi
PAMName=livi-kiosk
WorkingDirectory=$USER_HOME
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty-fail
StandardOutput=append:$APPIMAGE_DIR/LIVI.log
StandardError=inherit
Environment=ELECTRON_OZONE_PLATFORM_HINT=wayland
Environment=LIVI_KIOSK=1
ExecStart=$CAGE_BIN -s -- $APPIMAGE_PATH --disable-features=Vulkan
ExecStopPost=+$SYSTEMCTL_BIN --no-block start getty@tty1.service
Restart=no

[Install]
WantedBy=multi-user.target
EOF

	# The kiosk conflicts with getty@tty1. With both queued at boot, systemd
	# silently drops one of them, so the kiosk started only on some boots. Keep
	# getty out of the boot transaction; the kiosk starts it itself on exit
	# (ExecStopPost). The preset stops a first-boot preset run re-enabling it.
	echo "→ Removing getty@tty1 from boot (the kiosk owns tty1)"
	run_privileged rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service
	run_privileged mkdir -p /etc/systemd/system-preset
	echo "disable getty@.service" | run_privileged tee /etc/systemd/system-preset/10-livi-kiosk.preset >/dev/null

	if is_chroot_no_systemd; then
		echo "→ No running systemd detected; enabling kiosk units offline"
		enable_unit_offline "livi-kiosk.service" "multi-user.target"
		if [ -f /lib/systemd/system/seatd.service ]; then
			run_privileged mkdir -p /etc/systemd/system/multi-user.target.wants
			if [ ! -e /etc/systemd/system/multi-user.target.wants/seatd.service ]; then
				run_privileged ln -s /lib/systemd/system/seatd.service /etc/systemd/system/multi-user.target.wants/seatd.service
			fi
		fi
		run_privileged ln -snf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
	else
		# In some chrooted/image-build environments PID1 appears as systemd, but
		# starting units is still impossible. Enable units without --now to avoid failures.
		run_privileged systemctl daemon-reload
		run_privileged systemctl enable seatd
		if [ -d /run/systemd/system ]; then
			run_privileged loginctl enable-linger pi || true
		fi
		run_privileged systemctl set-default multi-user.target
		run_privileged systemctl enable livi-kiosk.service
	fi
}

# ====================================
# LIVI host integration
# Mirrors what LIVI's own scripts/install/headless/install.sh sets up, so the
# kiosk needs no pkexec dialog (there is no polkit agent under cage).
# ====================================

LIVI_USER="pi"
LIVI_REPO_RAW="https://raw.githubusercontent.com/f-io/LIVI"

# Git ref for LIVI's installer assets, matching the AppImage we download.
livi_asset_ref() {
	if [ -n "${LIVI_VERSION:-}" ] && [ "$LIVI_VERSION" != "latest" ]; then
		echo "$LIVI_VERSION"
	else
		curl -s https://api.github.com/repos/f-io/LIVI/releases/latest \
			| grep '"tag_name"' | head -1 | cut -d '"' -f 4
	fi
}

# livi_fetch_asset <name> -> prints the path to the template. Taken from the
# AppImage so it matches the installed app, the repository is the fallback.
livi_fetch_asset() {
	asset_name="$1"
	asset_dir="$LIVI_EXTRACT_DIR/$asset_name.d"
	mkdir -p "$asset_dir"
	if [ -x "$APPIMAGE_PATH" ]; then
		( cd "$asset_dir" && "$APPIMAGE_PATH" --appimage-extract "resources/$asset_name" >/dev/null 2>&1 ) || true
	fi
	asset_path="$asset_dir/squashfs-root/resources/$asset_name"
	if [ ! -f "$asset_path" ]; then
		[ -n "$LIVI_ASSET_REF" ] || return 1
		asset_path="$asset_dir/$asset_name"
		curl -fsL "$LIVI_REPO_RAW/$LIVI_ASSET_REF/assets/linux/$asset_name" -o "$asset_path" || return 1
	fi
	echo "$asset_path"
}

# livi_install_sudoers <file>; content on stdin. Validated with visudo first,
# the .livi-tmp name keeps sudo from reading it before that.
livi_install_sudoers() {
	rule="$1"
	echo "→ Writing $rule"
	run_privileged tee "$rule.livi-tmp" >/dev/null
	run_privileged chown root:root "$rule.livi-tmp"
	run_privileged chmod 0440 "$rule.livi-tmp"
	if run_privileged visudo -c -f "$rule.livi-tmp" >/dev/null; then
		run_privileged mv "$rule.livi-tmp" "$rule"
	else
		run_privileged rm -f "$rule.livi-tmp"
		echo "⚠ $rule failed validation and was not installed"
	fi
}

# livi_install_root_helper <helper> <sudoers-file> <description>; script body on stdin.
livi_install_root_helper() {
	helper="$1"
	helper_rule="$2"
	helper_desc="$3"
	echo "→ Installing $helper"
	run_privileged mkdir -p "$(dirname "$helper")"
	run_privileged tee "$helper" >/dev/null
	run_privileged chown root:root "$helper"
	run_privileged chmod 0755 "$helper"
	livi_install_sudoers "$helper_rule" <<EOF
# Installed by LIVI — $helper_desc
# Remove this file to revoke.
$LIVI_USER ALL=(root) NOPASSWD: $helper *
EOF
}

livi_install_udev_rules() {
	# The LIVI rule covers the Carlinkit dongle, hides the mouse interface of touch
	# panels that also expose a multitouch digitizer (via livi-touch-filter), and
	# sets up Apple/Android USB access for wired CarPlay and Android Auto.
	if udev_template="$(livi_fetch_asset 99-LIVI.rules.template)" \
		&& touch_filter="$(livi_fetch_asset livi-touch-filter)"; then
		echo "→ Installing /usr/local/lib/livi/livi-touch-filter"
		run_privileged install -D -m 0755 -o root -g root "$touch_filter" /usr/local/lib/livi/livi-touch-filter
		echo "→ Writing /etc/udev/rules.d/99-LIVI.rules"
		sed "s/__USERNAME__/$LIVI_USER/g" "$udev_template" | run_privileged tee /etc/udev/rules.d/99-LIVI.rules >/dev/null
		run_privileged rm -f /etc/udev/rules.d/52-carplay.rules
	else
		echo "⚠ LIVI udev template unavailable, falling back to the Carlinkit-only rule"
		echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1314", ATTR{idProduct}=="152*", MODE="0660", GROUP="plugdev"' | run_privileged tee /etc/udev/rules.d/52-carplay.rules >/dev/null
	fi
	# Both are no-ops in a chroot; the rules apply on first boot.
	run_privileged udevadm control --reload-rules || true
	run_privileged udevadm trigger || true
}

livi_install_helpers() {
	# Bluetooth and Wi-Fi helper (wireless CarPlay / Android Auto) runs as root.
	if sudoers_template="$(livi_fetch_asset 99-LIVI-bt.sudoers.template)"; then
		python_bin="$(command -v python3 || echo /usr/bin/python3)"
		sed -e "s/__USERNAME__/$LIVI_USER/g" -e "s#__PYTHON__#$python_bin#g" "$sudoers_template" \
			| livi_install_sudoers /etc/sudoers.d/99-LIVI-bt
	else
		echo "⚠ LIVI sudoers template unavailable, Bluetooth/Wi-Fi helper will ask for pkexec"
	fi

	livi_install_root_helper /usr/local/lib/livi/livi-video-mode.sh /etc/sudoers.d/99-LIVI-video \
		"lets $LIVI_USER pin the display mode in the kernel cmdline." <<'EOF'
#!/bin/bash
# Managed by LIVI. Pins video=<CONNECTOR:WxH@Hz> in the kernel cmdline; "clear" removes it.
set -euo pipefail
CMDLINE="/boot/firmware/cmdline.txt"
arg="${1:-}"
case "$arg" in
  clear) new="" ;;
  *)
    [[ "$arg" =~ ^[A-Za-z0-9-]+:[0-9]+x[0-9]+@[0-9]+D?$ ]] || {
      echo "usage: livi-video-mode.sh <CONNECTOR:WxH@Hz>|clear" >&2
      exit 2
    }
    new="video=$arg"
    ;;
esac
line="$(tr -d '\n' < "$CMDLINE")"
stripped="$(sed -E 's/[[:space:]]*video=[^[:space:]]+//g' <<< "$line")"
out="$stripped${new:+ $new}"
[ "$out" = "$line" ] || echo "$out" > "$CMDLINE"
EOF

	livi_install_root_helper /usr/local/lib/livi/livi-set-time.sh /etc/sudoers.d/99-LIVI-time \
		"lets $LIVI_USER set the system clock and timezone." <<'EOF'
#!/bin/bash
# Managed by LIVI. Sets the system clock from a unix timestamp, or the timezone.
set -euo pipefail
case "${1:-}" in
  tz)
    zone="${2:-}"
    [[ "$zone" =~ ^[A-Za-z0-9_+/-]{1,64}$ ]] || { echo "usage: livi-set-time.sh tz <zone>" >&2; exit 2; }
    [ -f "/usr/share/zoneinfo/$zone" ] || { echo "unknown timezone: $zone" >&2; exit 3; }
    timedatectl set-timezone "$zone"
    ;;
  *)
    arg="${1:-}"
    [[ "$arg" =~ ^[0-9]{10,11}$ ]] || { echo "usage: livi-set-time.sh <unix-seconds>|tz <zone>" >&2; exit 2; }
    date -u -s "@$arg" >/dev/null
    command -v fake-hwclock >/dev/null 2>&1 && fake-hwclock save || true
    ;;
esac
EOF

	livi_install_root_helper /usr/local/lib/livi/livi-power.sh /etc/sudoers.d/99-LIVI-power \
		"lets $LIVI_USER power the host down or reboot it." <<'EOF'
#!/bin/bash
# Managed by LIVI. Powers the host off or reboots it. Nothing else.
set -euo pipefail
case "${1:-}" in
  poweroff) systemctl poweroff ;;
  reboot)   systemctl reboot ;;
  *) echo "usage: livi-power.sh poweroff|reboot" >&2 ; exit 2 ;;
esac
EOF
}

livi_install_pymobiledevice3() {
	# Wired CarPlay drives the phone over usbmux, which needs pymobiledevice3.
	echo "→ Installing pymobiledevice3 for wired CarPlay"
	if ! command -v pip3 >/dev/null 2>&1; then
		echo "⚠ pip3 missing, wired CarPlay stays disabled"
		return 0
	fi
	if pip_out="$(run_privileged pip3 install --break-system-packages --ignore-installed -q pymobiledevice3 2>&1)"; then
		echo "   installed"
	else
		echo "⚠ pymobiledevice3 install failed, wired CarPlay stays disabled"
		printf '%s\n' "$pip_out" | tail -5
	fi
}

livi_apply_mfi() {
	# I2C bus 2 on GPIO 19/26 plus power pin 21, matching LIVI's defaults.
	echo "→ Enabling I2C for the Apple MFi coprocessor"
	mfi_overlay="dtoverlay=i2c-gpio,bus=2,i2c_gpio_sda=19,i2c_gpio_scl=26,i2c_gpio_delay_us=5"
	if [ -f /boot/firmware/config.txt ]; then
		if ! grep -qF "$mfi_overlay" /boot/firmware/config.txt; then
			echo "$mfi_overlay" | run_privileged tee -a /boot/firmware/config.txt >/dev/null
		fi
	else
		echo "⚠ /boot/firmware/config.txt not found, skipping MFi overlay"
	fi
	echo i2c-dev | run_privileged tee /etc/modules-load.d/livi-i2c.conf >/dev/null

	# Keeps values already set in the app config; only a missing or disabled power pin is filled in.
	run_privileged mkdir -p "$LIVI_USERDATA_DIR"
	run_privileged python3 - "$LIVI_CONFIG_PATH" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
cfg.setdefault("carPlayMfiI2cBus", 2)
if cfg.get("carPlayMfiPowerGpio", -1) in (None, "", -1):
    cfg["carPlayMfiPowerGpio"] = 21
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
	if id -u "$LIVI_USER" >/dev/null 2>&1; then
		run_privileged chown -R "$LIVI_USER:$LIVI_USER" "$LIVI_USERDATA_DIR" || true
	fi
}

setup_livi_host_integration() {
	echo "→ Applying LIVI host integration"
	if ! have_privileges; then
		echo "⚠ Skipping LIVI host integration (requires sudo/root)"
		return 0
	fi

	LIVI_ASSET_REF="$(livi_asset_ref || true)"
	LIVI_EXTRACT_DIR="$(mktemp -d)"

	if is_enabled "$FEATURE_CARLINKIT_UDEV"; then
		livi_install_udev_rules
	else
		echo "→ Skipping LIVI udev rules (feature disabled)"
	fi

	livi_install_helpers
	livi_install_pymobiledevice3

	# Radio power saving drops an idle link after a few minutes; PMF=optional
	# keeps phones that do not support 802.11w connecting.
	echo "→ Writing NetworkManager Wi-Fi powersave/PMF overrides"
	run_privileged mkdir -p /etc/NetworkManager/conf.d
	printf '[connection]\nwifi.powersave = 2\n' | run_privileged tee /etc/NetworkManager/conf.d/99-LIVI-wifi-powersave.conf >/dev/null
	printf '[connection]\nwifi-sec.pmf=2\n' | run_privileged tee /etc/NetworkManager/conf.d/99-LIVI-wifi-pmf.conf >/dev/null

	echo "→ Preloading iPhone USB net drivers (so cdc_ncm binds the AV interface at cold boot)"
	run_privileged tee /etc/modules-load.d/livi.conf >/dev/null <<'EOF'
cdc_ncm
cdc_ether
ipheth
EOF

	# Lingering keeps PipeWire user services running without a login. The marker
	# file is what loginctl enable-linger writes, so this also works offline.
	echo "→ Enabling lingering for $LIVI_USER"
	run_privileged mkdir -p /var/lib/systemd/linger
	run_privileged touch "/var/lib/systemd/linger/$LIVI_USER"

	if is_enabled "$FEATURE_LIVI_MFI"; then
		livi_apply_mfi
	fi

	# WirePlumber uses this until it has saved a volume of its own. It takes
	# linear volume, which is the cube of what wpctl and LIVI show.
	echo "→ Setting default output volume to $MFD_DEFAULT_VOLUME"
	sink_volume="$(awk -v v="$MFD_DEFAULT_VOLUME" 'BEGIN { printf "%.6f", v ^ 3 }')"
	run_privileged mkdir -p /etc/wireplumber/wireplumber.conf.d
	run_privileged tee /etc/wireplumber/wireplumber.conf.d/50-mfd-default-volume.conf >/dev/null <<EOF
wireplumber.settings = {
  device.routes.default-sink-volume = $sink_volume
}
EOF

	# The installer runs as root and creates ~/.config and ~/.local on the way.
	# Left root-owned, WirePlumber cannot save its state (so the volume reset on
	# every boot) and LIVI cannot write its HFP config.
	if id -u "$LIVI_USER" >/dev/null 2>&1; then
		run_privileged mkdir -p "$USER_HOME/.config" "$USER_HOME/.local"
		run_privileged chown -R "$LIVI_USER:$LIVI_USER" "$USER_HOME/.config" "$USER_HOME/.local"
	fi

	rm -rf "$LIVI_EXTRACT_DIR"
}

# ====================================
# LIVI CarPlay Installer (hardened)
# ====================================

# Prefer installing for the 'pi' user when available; fallback to $HOME or /home/pi
if id -u pi >/dev/null 2>&1; then
	USER_HOME="/home/pi"
else
	USER_HOME="${HOME:-/home/pi}"
fi
APPIMAGE_PATH="$USER_HOME/LIVI/LIVI.AppImage"
APPIMAGE_DIR="$(dirname "$APPIMAGE_PATH")"
LIVI_USERDATA_DIR="$USER_HOME/.config/LIVI"
LIVI_CONFIG_PATH="$LIVI_USERDATA_DIR/config.json"
CUSTOM_LIVI_CONFIG="$CONFIG_DIR/livi-config.json"

echo "→ Creating LIVI target directory: $APPIMAGE_DIR"
run_privileged mkdir -p "$APPIMAGE_DIR"
if id -u pi >/dev/null 2>&1; then
	run_privileged chown -R pi:pi "$APPIMAGE_DIR" || true
fi

# Ensure required tools are installed
echo "→ Checking for required tools: curl, xdg-user-dir"
for tool in curl xdg-user-dir; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "   $tool not found"
		if have_privileges; then
			echo "   Installing…"
			if [ "$tool" = "xdg-user-dir" ]; then
				run_privileged apt-get update
				run_privileged apt-get --yes install xdg-user-dirs
			else
				run_privileged apt-get update
				run_privileged apt-get --yes install "$tool"
			fi
		else
			echo "   ⚠ Cannot install $tool without sudo/root; skipping"
		fi
	else
		echo "   $tool found"
	fi
done

# ICON INSTALLATION
ICON_URL="https://raw.githubusercontent.com/f-io/LIVI/main/assets/icons/linux/livi.png"
ICON_DEST="$USER_HOME/.local/share/icons/livi.png"

echo "→ Installing LIVI icon to $ICON_DEST"
run_privileged mkdir -p "$(dirname "$ICON_DEST")"
if id -u pi >/dev/null 2>&1; then
	run_privileged chown -R pi:pi "$(dirname "$ICON_DEST")" || true
fi

echo "   Downloading icon from $ICON_URL..."
if curl -fL "$ICON_URL" -o "$ICON_DEST"; then
	echo "   LIVI icon downloaded and installed successfully."
else
	echo "   Failed to download icon from $ICON_URL. Skipping icon install."
	ICON_DEST=""
fi

# Fetch ARM64 AppImage from GitHub
if [ "$LIVI_VERSION" = "latest" ]; then
	LIVI_RELEASE_API="https://api.github.com/repos/f-io/LIVI/releases/latest"
else
	LIVI_RELEASE_API="https://api.github.com/repos/f-io/LIVI/releases/tags/$LIVI_VERSION"
fi
echo "→ Fetching LIVI release ($LIVI_VERSION)"
latest_url=$(curl -s "$LIVI_RELEASE_API" \
	| grep "browser_download_url" \
	| grep "arm64.AppImage" \
	| cut -d '"' -f 4)

if [ -z "$latest_url" ]; then
	echo "⚠ Warning: Could not find ARM64 AppImage URL, skipping LIVI AppImage download"
else
	echo "   Download URL: $latest_url"
	if curl -L "$latest_url" --output "$APPIMAGE_PATH"; then
		echo "   Download complete: $APPIMAGE_PATH"
		# Mark AppImage as executable
		echo "→ Setting executable flag"
		run_privileged chmod +x "$APPIMAGE_PATH"
		if id -u pi >/dev/null 2>&1; then
			run_privileged chown pi:pi "$APPIMAGE_PATH" || true
		fi
	else
		echo "⚠ Warning: Download failed, skipping LIVI AppImage"
	fi
fi

# Optional: preinstall custom LIVI config into Electron userData
if [ -f "$CUSTOM_LIVI_CONFIG" ]; then
	echo "→ Installing custom LIVI config from $CUSTOM_LIVI_CONFIG"
	run_privileged mkdir -p "$LIVI_USERDATA_DIR"
	run_privileged cp "$CUSTOM_LIVI_CONFIG" "$LIVI_CONFIG_PATH"
	run_privileged chmod 0644 "$LIVI_CONFIG_PATH"
	if id -u pi >/dev/null 2>&1; then
		run_privileged chown -R pi:pi "$LIVI_USERDATA_DIR" || true
	fi
	echo "   Installed custom config at $LIVI_CONFIG_PATH"
else
	echo "→ No custom LIVI config found at $CUSTOM_LIVI_CONFIG (using LIVI defaults)"
fi

# udev rules, root helpers, Wi-Fi and USB net setup (after the config copy, MFi seeds it)
setup_livi_host_integration

# Create per-user autostart entry (desktop fallback)
if [ -f "$APPIMAGE_PATH" ] && is_enabled "$FEATURE_LIVI_AUTOSTART" && ! is_enabled "$FEATURE_LIVI_NATIVE_KIOSK"; then
	echo "→ Creating autostart entry"
	AUTOSTART_DIR="$USER_HOME/.config/autostart"
	run_privileged mkdir -p "$AUTOSTART_DIR"
	if id -u pi >/dev/null 2>&1; then
		run_privileged chown -R pi:pi "$USER_HOME/.config" || true
	fi

	cat > "$AUTOSTART_DIR/LIVI.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LIVI
Exec=$APPIMAGE_PATH
Icon=${ICON_DEST:-livi}
Terminal=false
X-GNOME-Autostart-enabled=true
Categories=AudioVideo;
EOF
	echo "   Autostart entry at $AUTOSTART_DIR/LIVI.desktop"

	# Create Desktop shortcut
	echo "→ Creating desktop shortcut"
	# Prefer the desktop directory for the chosen USER_HOME
	if command -v xdg-user-dir >/dev/null 2>&1; then
		DESKTOP_DIR="$(HOME="$USER_HOME" xdg-user-dir DESKTOP 2>/dev/null || true)"
	else
		DESKTOP_DIR="$USER_HOME/Desktop"
	fi

	run_privileged mkdir -p "$DESKTOP_DIR"
	if id -u pi >/dev/null 2>&1; then
		run_privileged chown -R pi:pi "$DESKTOP_DIR" || true
	fi
	cat > "$DESKTOP_DIR/LIVI.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LIVI
Comment=Launch LIVI AppImage
Exec=$APPIMAGE_PATH
Icon=${ICON_DEST:-livi}
Terminal=false
Categories=AudioVideo;
StartupNotify=false
EOF

	run_privileged chmod +x "$DESKTOP_DIR/LIVI.desktop"
	if id -u pi >/dev/null 2>&1; then
		run_privileged chown pi:pi "$DESKTOP_DIR/LIVI.desktop" || true
	fi
	echo "   Desktop shortcut at $DESKTOP_DIR/LIVI.desktop"
	if id -u pi >/dev/null 2>&1; then
		run_privileged chown pi:pi "$AUTOSTART_DIR/LIVI.desktop" || true
	fi
	echo "✅ LIVI installation complete!"
elif [ -f "$APPIMAGE_PATH" ] && is_enabled "$FEATURE_LIVI_NATIVE_KIOSK"; then
	echo "→ Skipping desktop autostart because native LIVI kiosk is enabled"
elif [ -f "$APPIMAGE_PATH" ]; then
	echo "→ LIVI AppImage present, but autostart/desktop setup is disabled"
else
	echo "⚠ LIVI AppImage not available, skipping autostart and desktop entries"
fi

if [ -f "$APPIMAGE_PATH" ] && is_enabled "$FEATURE_LIVI_NATIVE_KIOSK"; then
	setup_livi_native_kiosk
fi

setup_firstboot_cloudinit_reboot

if is_enabled "$FEATURE_QUIET_BOOT"; then
	setup_quiet_boot_cmdline
fi

if is_enabled "$FEATURE_BOOT_SPLASH"; then
	setup_plymouth_splash
fi

if is_enabled "$FEATURE_OPTIMIZE_BOOT"; then
	optimize_boot_services
fi

# Configure system settings (may be no-op in CI image)
# raspi-config nonint: 0 = enable, 1 = disable. Enabling VNC on Lite installs
# realvnc-vnc-server, which pulls in the whole CUPS printing stack.
if is_enabled "$FEATURE_DISABLE_VNC"; then
	$SUDO raspi-config nonint do_vnc 1 || true
fi
if is_enabled "$FEATURE_BOOT_B4"; then
	$SUDO raspi-config nonint do_boot_behaviour B4 || true
fi
if is_enabled "$FEATURE_DISABLE_SSH"; then
	$SUDO raspi-config nonint do_ssh 1 || true
fi

# Optional tweaks left commented out
# $SUDO sh -c "echo -n uvcvideo.quirks=2 >> /boot/firmware/cmdline.txt"
# sleep 5
# $SUDO reboot

# =============================
# KIOSK-MODUS EINRICHTEN
# =============================

if is_enabled "$FEATURE_KIOSK_MODE"; then
	echo "→ Legacy FEATURE_KIOSK_MODE is deprecated."
	echo "→ Use FEATURE_LIVI_NATIVE_KIOSK=1 (default) for LIVI's built-in kiosk service."
else
	echo "→ Kiosk mode is disabled by feature flag"
fi

# Am Ende: Im chroot ohne systemd immer mit Exit-Code 0 beenden
if is_chroot_no_systemd; then
    echo "⚠ Running in chroot, forcing exit code 0 (systemd not available)"
    exit 0
fi