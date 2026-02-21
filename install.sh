#!/bin/bash
set -e

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
$SUDO apt-get upgrade -y
$SUDO apt-get install -y libxi-dev libx11-dev libxrandr-dev txt2man

# Move config if present (guard against missing file when run from CI)
if [ -f config/config.txt ]; then
	# Ensure target directory exists (some images mount boot at /boot, but not /boot/firmware)
	$SUDO mkdir -p /boot/firmware
	$SUDO cp config/config.txt /boot/firmware/config.txt
else
	echo "Warning: config/config.txt not found, skipping move"
fi

# Build touch calibration tool (best-effort; don't fail whole script if missing)
mkdir -p /home/pi/Desktop
cd /home/pi/Desktop || exit 0
if [ ! -d xlibinput_calibrator ]; then
	git clone https://github.com/kreijack/xlibinput_calibrator.git || true
fi
if [ -d xlibinput_calibrator/src ]; then
	cd xlibinput_calibrator/src/ || true
	make || true
fi

# Download and run CarPlay setup script if available (best-effort)
mkdir -p /home/pi/Downloads
cd /home/pi/Downloads || true
# try a canonical raw.githubusercontent URL for the setup script; tolerate failure
$SUDO curl -fLO https://raw.githubusercontent.com/f-io/LIVI/refs/heads/main/scripts/install/pi/install.sh || true
if [ -f install.sh ]; then
	chmod +x install.sh || true
	# Try to run the downloaded installer as user 'pi' when possible.
	# Prefer working sudo; if sudo is unavailable, try su (if root) or run directly.
	if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
		sudo -u pi ./install.sh || echo "install.sh exited with non-zero status"
	elif [ "$(id -u)" -eq 0 ]; then
		# We're root in chroot/CI: try su to pi if that user exists, else run as root
		if id -u pi >/dev/null 2>&1; then
			su - pi -c "$(pwd)/install.sh" || echo "install.sh exited with non-zero status"
		else
			./install.sh || echo "install.sh exited with non-zero status"
		fi
	else
		# Non-root and no working sudo: try to run the script directly (best-effort)
		./install.sh || echo "install.sh exited with non-zero status (no sudo)"
	fi
else
	echo "Notice: install.sh not found, skipping CarPlay setup"
fi

# Configure system settings (may be no-op in CI image)
$SUDO raspi-config nonint do_vnc 0 -y || true
$SUDO raspi-config nonint do_boot_behaviour B4 || true
$SUDO raspi-config nonint do_ssh 0 -y || true

# Optional tweaks left commented out
# $SUDO sh -c "echo -n uvcvideo.quirks=2 >> /boot/firmware/cmdline.txt"
# sleep 5
# $SUDO reboot