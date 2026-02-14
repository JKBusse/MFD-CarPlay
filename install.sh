#!/bin/bash
set -e

# If running as root inside chroot, avoid calling sudo repeatedly.
if [ "$(id -u)" -ne 0 ]; then
	SUDO=sudo
else
	SUDO=""
fi

# Update and install required packages
$SUDO apt-get update -y
$SUDO apt-get upgrade -y
$SUDO apt-get install -y libxi-dev libx11-dev libxrandr-dev txt2man

# Move config if present (guard against missing file when run from CI)
if [ -f config/config.txt ]; then
	$SUDO mv config/config.txt /boot/firmware/config.txt
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
curl -fLO https://raw.githubusercontent.com/f-io/LIVI/main/scripts/install/pi/setup-pi.sh || true
if [ -f setup-pi.sh ]; then
	chmod +x setup-pi.sh || true
	./setup-pi.sh || echo "setup-pi.sh exited with non-zero status"
else
	echo "Notice: setup-pi.sh not found, skipping CarPlay setup"
fi

# Configure system settings (may be no-op in CI image)
$SUDO raspi-config nonint do_vnc 0 -y || true
$SUDO raspi-config nonint do_boot_behaviour B4 || true

# Optional tweaks left commented out
# $SUDO sh -c "echo -n uvcvideo.quirks=2 >> /boot/firmware/cmdline.txt"
# sleep 5
# $SUDO reboot