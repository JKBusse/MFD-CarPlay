#!/bin/bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-/boot/firmware/config.txt}"
BACKUP_PATH="${BACKUP_PATH:-${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)}"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Config file not found: $CONFIG_PATH" >&2
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

cp "$CONFIG_PATH" "$BACKUP_PATH"

echo "Backed up current config to $BACKUP_PATH"

python3 - <<'PY'
from pathlib import Path
config_path = Path('/boot/firmware/config.txt')
text = config_path.read_text()

if 'dtoverlay=vc4-kms-v3d' in text:
    text = text.replace('dtoverlay=vc4-kms-v3d', 'dtoverlay=vc4-fkms-v3d')
elif 'dtoverlay=vc4-fkms-v3d' not in text:
    if '[all]' in text:
        text = text.replace('[all]\n', '[all]\ndtoverlay=vc4-fkms-v3d\n', 1)
    else:
        text += '\n[all]\ndtoverlay=vc4-fkms-v3d\n'

if 'max_framebuffers=2' not in text:
    text = text.replace('dtoverlay=vc4-fkms-v3d\n', 'dtoverlay=vc4-fkms-v3d\nmax_framebuffers=2\n', 1)

config_path.write_text(text)
PY

echo "Updated $CONFIG_PATH to use vc4-fkms-v3d"
echo "Reboot the system now to test the new Wayland/framebuffer mode."
