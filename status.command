#!/bin/bash
set -euo pipefail

APP_DIR="$HOME/Library/Application Support/GDOU-AutoConnect"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"

if [[ -f "$APP_DIR/gdou-connect.sh" ]]; then
    exec /bin/bash "$APP_DIR/gdou-connect.sh" --status
fi
if [[ -f "$SCRIPT_DIR/gdou-connect.sh" ]]; then
    exec /bin/bash "$SCRIPT_DIR/gdou-connect.sh" --status
fi
printf '找不到 GDOU-AutoConnect 主程序。\n' >&2
exit 1
