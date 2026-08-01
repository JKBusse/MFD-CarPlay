#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Feature flags (1=enabled, 0=disabled)
FEATURE_DISABLE_VNC="${FEATURE_DISABLE_VNC:-1}"
FEATURE_DISABLE_SSH="${FEATURE_DISABLE_SSH:-1}"
FEATURE_BOOT_B4="${FEATURE_BOOT_B4:-1}"
FEATURE_KIOSK_MODE="${FEATURE_KIOSK_MODE:-1}"
FEATURE_LIVI_NATIVE_KIOSK="${FEATURE_LIVI_NATIVE_KIOSK:-1}"
FEATURE_CARLINKIT_UDEV="${FEATURE_CARLINKIT_UDEV:-1}"
FEATURE_LIVI_AUTOSTART="${FEATURE_LIVI_AUTOSTART:-1}"
FEATURE_APT_UPGRADE="${FEATURE_APT_UPGRADE:-1}"

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
$SUDO apt-get install -y libxi-dev libx11-dev libxrandr-dev txt2man curl xdg-user-dirs

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

setup_livi_native_kiosk() {
	echo "→ Setting up LIVI native kiosk (tty1 + cage)"

	run_privileged apt-get install -y cage seatd wlr-randr pipewire pipewire-pulse wireplumber

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
ExecStart=$CAGE_BIN -s -- $APPIMAGE_PATH
ExecStopPost=+$SYSTEMCTL_BIN --no-block start getty@tty1.service
Restart=no

[Install]
WantedBy=multi-user.target
EOF

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
		run_privileged systemctl daemon-reload
		run_privileged systemctl enable --now seatd
		run_privileged loginctl enable-linger pi || true
		run_privileged systemctl set-default multi-user.target
		run_privileged systemctl enable livi-kiosk.service
	fi
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

# Create udev rule for Carlinkit dongle (only if we have privileges)
if is_enabled "$FEATURE_CARLINKIT_UDEV"; then
	echo "→ Writing udev rule for Carlinkit"
	UDEV_FILE="/etc/udev/rules.d/52-carplay.rules"
	if have_privileges; then
		echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1314", ATTR{idProduct}=="152*", MODE="0660", GROUP="plugdev"' | run_privileged tee "$UDEV_FILE" >/dev/null
		echo "   Reloading udev rules"
		run_privileged udevadm control --reload-rules
		run_privileged udevadm trigger
	else
		echo "   ⚠ Skipping udev rule install (requires sudo/root)"
	fi
else
	echo "→ Skipping Carlinkit udev rule (feature disabled)"
fi

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

# Fetch latest ARM64 AppImage from GitHub
echo "→ Fetching latest LIVI release"
latest_url=$(curl -s https://api.github.com/repos/f-io/LIVI/releases/latest \
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

# Configure system settings (may be no-op in CI image)
if is_enabled "$FEATURE_DISABLE_VNC"; then
	$SUDO raspi-config nonint do_vnc 0 -y || true
fi
if is_enabled "$FEATURE_BOOT_B4"; then
	$SUDO raspi-config nonint do_boot_behaviour B4 || true
fi
if is_enabled "$FEATURE_DISABLE_SSH"; then
	$SUDO raspi-config nonint do_ssh 0 -y || true
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