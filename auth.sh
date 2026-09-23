#!/bin/bash
# One-shot SRun authentication wrapper. Password data only travels from the
# Keychain command's stdout to the Python helper's stdin.
set -u
set -o pipefail
umask 077

SERVICE='GDOU-AutoConnect'
APP_DIR="$HOME/Library/Application Support/GDOU-AutoConnect"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$APP_DIR/config"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PYTHON_PATH_FILE="$APP_DIR/python.path"

safe_fail() { printf '%s\n' "$1" >&2; exit 1; }

read_username() {
    local line value=''
    [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == username=* ]] || continue
        value="${line#username=}"
        break
    done < "$CONFIG_FILE"
    # Bash strings cannot contain NUL; reject the line delimiters that can
    # otherwise turn an account field into more than one shell argument.
    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] || return 1
    printf '%s' "$value"
}

find_python() {
    local candidate resolved
    if [[ -f "$PYTHON_PATH_FILE" && ! -L "$PYTHON_PATH_FILE" ]]; then
        IFS= read -r candidate < "$PYTHON_PATH_FILE" || candidate=''
        if [[ "$candidate" == /* && -x "$candidate" ]]; then
            if resolved="$("$candidate" -B -c 'import os,sys; assert sys.version_info >= (3,9); print(os.path.realpath(sys.executable))' 2>/dev/null)"; then
                printf '%s' "$resolved"
                return 0
            fi
        fi
    fi
    for candidate in /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [[ -x "$candidate" ]] || continue
        if [[ "$candidate" == /usr/bin/python3 ]] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
            continue
        fi
        if resolved="$("$candidate" -B -c 'import os,sys; assert sys.version_info >= (3,9); print(os.path.realpath(sys.executable))' 2>/dev/null)"; then
            printf '%s' "$resolved"
            return 0
        fi
    done
    return 1
}

wifi_ip() {
    local device
    device="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '
      /^Hardware Port: (Wi-Fi|AirPort)[[:space:]]*$/ {wifi=1; next}
      /^Hardware Port:/ {wifi=0}
      wifi && /^Device: [A-Za-z][A-Za-z0-9]*[[:space:]]*$/ {print $2; exit}
    ')"
    [[ -n "$device" ]] || return 1
    /usr/sbin/ipconfig getifaddr "$device" 2>/dev/null
}

main() {
    local mode="${1:---attempt}" username python local_ip security_rc helper_rc
    local -a pipe_status helper_args
    case "$mode" in --attempt|--test|--check|--diagnose|--self-logout) ;; *)
        printf 'Usage: auth.sh [--attempt|--test|--check|--diagnose|--self-logout]\n' >&2
        return 2;; esac
    [[ -f "$SCRIPT_DIR/srun_auth.py" && ! -L "$SCRIPT_DIR/srun_auth.py" ]] || safe_fail 'Authentication failed: helper unavailable.'
    username="$(read_username)" || safe_fail 'Authentication failed: campus account unavailable.'
    python="$(find_python)" || safe_fail 'Authentication failed: Python 3.9+ unavailable.'
    if [[ "$mode" == --check ]]; then
        "$python" -B "$SCRIPT_DIR/srun_auth.py" --probe || return 1
        if /usr/bin/security find-generic-password -a "$username" -s "$SERVICE" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
            printf 'Campus account and Keychain password are available\n'
            return 0
        fi
        printf 'SRun portal reachable, but Keychain password is unavailable\n' >&2
        return 1
    fi
    local_ip="$(wifi_ip || true)"
    if [[ "$mode" == --self-logout ]]; then
        # No Keychain access is necessary. The helper first confirms that
        # rad_user_info describes this exact local IP and configured account.
        "$python" -B "$SCRIPT_DIR/srun_auth.py" --self-logout \
            --username "$username" --ip "$local_ip"
        return $?
    fi
    # An empty IP is allowed exactly once: get_challenge then asks SRun to
    # infer client_ip. Password is never stored in a shell variable.
    helper_args=(--username "$username" --ip "$local_ip")
    [[ "$mode" != --diagnose ]] || helper_args+=(--diagnose)
    /usr/bin/security find-generic-password -a "$username" -s "$SERVICE" -w "$LOGIN_KEYCHAIN" 2>/dev/null \
        | "$python" -B "$SCRIPT_DIR/srun_auth.py" "${helper_args[@]}"
    pipe_status=("${PIPESTATUS[@]}")
    security_rc="${pipe_status[0]}"
    helper_rc="${pipe_status[1]}"
    if (( security_rc != 0 )); then
        printf 'Authentication failed: Keychain password unavailable.\n' >&2
        return 1
    fi
    return "$helper_rc"
}

main "$@"
