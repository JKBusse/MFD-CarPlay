#!/bin/bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-/boot/firmware/config.txt}"
MODE="${1:-rgb666}"

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Config file not found: $CONFIG_PATH" >&2
  exit 1
fi

case "$MODE" in
  rgb666)
    ;;
  rgb565)
    ;;
  *)
    echo "Usage: $0 [rgb666|rgb565]" >&2
    exit 1
    ;;
esac

BACKUP_PATH="${BACKUP_PATH:-${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)}"
cp "$CONFIG_PATH" "$BACKUP_PATH"
echo "Backed up current config to $BACKUP_PATH"

python3 - <<'PY' "$CONFIG_PATH" "$MODE"
from pathlib import Path
import sys
config_path = Path(sys.argv[1])
mode = sys.argv[2]
text = config_path.read_text()

for marker in ['dtparam=rgb666=1', 'dtparam=rgb565=1']:
    text = text.replace(marker, f'# {marker}')

if mode == 'rgb666':
    text = text.replace('# dtparam=rgb666=1', 'dtparam=rgb666=1')
else:
    text = text.replace('# dtparam=rgb565=1', 'dtparam=rgb565=1')

config_path.write_text(text)
PY

echo "Switched DPI color mode to $MODE"
echo "Reboot the system now to test the new display mode."
