#!/bin/bash
# GDOU-AutoConnect: user-session Wi-Fi monitor. No credentials or request bodies are logged.
set -u
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$HOME/Library/Application Support/GDOU-AutoConnect"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/gdou-autoconnect.log"
CONFIG_FILE="$APP_DIR/config"
STATE_FILE="$APP_DIR/retry.state"
LOCK_FILE="$APP_DIR/monitor.lock"
PAUSE_FILE="$APP_DIR/paused"
TARGET_SSID="GDOU.NET"
USERNAME=""
CHECK_INTERVAL=30
AUTH_MIN_INTERVAL=60
SESSION_RESET_COOLDOWN=300
FAILURES=0
NEXT_ATTEMPT=0
LAST_AUTH=0
LAST_SESSION_RESET=0
LAST_STATUS=""
NEXT_SLEEP=30
INTERNET_CAPTIVE=0
CURRENT_SSID="UNKNOWN"
WIFI_REPORT=""
PROFILER_INDEX=""
REPORT_READY=0
WIFI_DEVICE=""

valid_ssid() {
    local value="$1" lower
    lower="$(printf '%s' "$value" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ -n "$value" && "$lower" != "unknown" && "$lower" != "<redacted>" &&
       "$lower" != "redacted" && "$lower" != "<hidden>" &&
       "$lower" != '<data>'* && "$lower" != 0x* &&
       ! ( "$lower" == '<'*'>' ) &&
       "$lower" != "(null)" && "$lower" != "null" &&
       "$lower" != "n/a" && "$lower" != "not associated" &&
       "$lower" != *"not associated"* && "$lower" != *"you are not associated"* ]]
}

read_config() {
    local line key value
    [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            username) USERNAME="$value" ;;
            ssid) TARGET_SSID="$value" ;;
            check_interval) CHECK_INTERVAL="$value" ;;
            auth_min_interval) AUTH_MIN_INTERVAL="$value" ;;
        esac
    done < "$CONFIG_FILE"
    [[ -n "$TARGET_SSID" && ${#TARGET_SSID} -le 32 && "$TARGET_SSID" != *$'\r'* ]] || return 1
    [[ "$CHECK_INTERVAL" =~ ^[0-9]{1,4}$ && "$AUTH_MIN_INTERVAL" =~ ^[0-9]{1,4}$ ]] || return 1
    CHECK_INTERVAL=$((10#$CHECK_INTERVAL)); AUTH_MIN_INTERVAL=$((10#$AUTH_MIN_INTERVAL))
    (( CHECK_INTERVAL >= 10 && CHECK_INTERVAL <= 300 && AUTH_MIN_INTERVAL >= 60 && AUTH_MIN_INTERVAL <= 3600 )) || return 1
}

prepare_runtime() {
    [[ ! -L "$APP_DIR" && ! -L "$LOG_DIR" && ! -L "$LOG_FILE" && ! -L "$STATE_FILE" && ! -L "$LOCK_FILE" ]] || return 1
    /bin/mkdir -p "$APP_DIR" "$LOG_DIR" || return 1
    /bin/chmod 700 "$APP_DIR" || return 1
    [[ -e "$LOG_FILE" ]] && /bin/chmod 600 "$LOG_FILE" 2>/dev/null
    return 0
}

is_paused() {
    # Treat any existing marker as paused. A malformed marker therefore fails
    # closed and can never cause Wi-Fi or portal activity.
    [[ -e "$PAUSE_FILE" || -L "$PAUSE_FILE" ]]
}

pause_automation() {
    local temp
    prepare_runtime || { printf 'Unable to change pause state safely.\n' >&2; return 2; }
    if is_paused; then
        [[ ! -L "$PAUSE_FILE" && -f "$PAUSE_FILE" ]] || { printf 'Unable to change pause state safely.\n' >&2; return 2; }
        printf 'GDOU-AutoConnect paused.\nAutomatic Wi-Fi connection and authentication are disabled.\n'
        return 0
    fi
    temp="$(/usr/bin/mktemp "$APP_DIR/.paused.XXXXXX")" || return 2
    /bin/chmod 600 "$temp" && printf 'paused\n' > "$temp" && /bin/mv -f "$temp" "$PAUSE_FILE" || {
        /bin/rm -f "$temp"; return 2
    }
    log_message 'state=PAUSED reason=user_request' || true
    printf 'GDOU-AutoConnect paused.\nAutomatic Wi-Fi connection and authentication are disabled.\n'
}

resume_automation() {
    prepare_runtime || { printf 'Unable to change pause state safely.\n' >&2; return 2; }
    if ! is_paused; then
        printf 'GDOU-AutoConnect resumed.\nAutomatic connection is enabled.\n'
        return 0
    fi
    [[ ! -L "$PAUSE_FILE" && -f "$PAUSE_FILE" ]] || { printf 'Unable to change pause state safely.\n' >&2; return 2; }
    /bin/rm -f "$PAUSE_FILE" || return 2
    log_message 'state=RESUMED reason=user_request' || true
    printf 'GDOU-AutoConnect resumed.\nAutomatic connection is enabled.\n'
}

rotate_log() {
    [[ -L "$LOG_FILE" ]] && return 1
    local size=0 index
    if [[ -f "$LOG_FILE" ]]; then
        size="$(/usr/bin/stat -f '%z' "$LOG_FILE" 2>/dev/null || printf 0)"
    fi
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if (( size >= 1048576 )); then
        /bin/rm -f "$LOG_FILE.4"
        for index in 3 2 1; do
            [[ ! -f "$LOG_FILE.$index" ]] || /bin/mv -f "$LOG_FILE.$index" "$LOG_FILE.$((index+1))"
        done
        [[ ! -f "$LOG_FILE" ]] || /bin/mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
}

log_message() {
    local line="$1"
    rotate_log || return 1
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$LOG_FILE"
    /bin/chmod 600 "$LOG_FILE" 2>/dev/null || true
}

set_status() {
    local status="$1" reason="$2" ssid_scope
    [[ "$status" == "$LAST_STATUS" ]] && return 0
    case "$CURRENT_SSID" in
        UNKNOWN) ssid_scope=UNKNOWN ;;
        "$TARGET_SSID") ssid_scope=TARGET ;;
        *) ssid_scope=OTHER ;;
    esac
    log_message "state=$status ssid_scope=$ssid_scope reason=$reason" || true
    LAST_STATUS="$status"
}

now_epoch() { /bin/date +%s; }
pause_seconds() { /bin/sleep "$1"; }

load_state() {
    local key value line now
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        [[ "$value" =~ ^[0-9]{1,12}$ ]] || continue
        value=$((10#$value))
        case "$key" in
            failures) FAILURES="$value" ;;
            next_attempt) NEXT_ATTEMPT="$value" ;;
            last_auth) LAST_AUTH="$value" ;;
            last_session_reset) LAST_SESSION_RESET="$value" ;;
        esac
    done < "$STATE_FILE"
    (( FAILURES <= 5 )) || FAILURES=5
    now="$(now_epoch)"
    # A clock correction must not leave the monitor dormant for hours.
    (( NEXT_ATTEMPT <= now + 60 )) || NEXT_ATTEMPT=$((now + 60))
    (( LAST_AUTH <= now + 3600 )) || LAST_AUTH=$((now + 3600))
    (( LAST_SESSION_RESET <= now + 3600 )) || LAST_SESSION_RESET=$((now + 3600))
}

save_state() {
    local temp
    temp="$(/usr/bin/mktemp "$APP_DIR/.retry.XXXXXX")" || return 1
    /bin/chmod 600 "$temp" || return 1
    printf 'failures=%s\nnext_attempt=%s\nlast_auth=%s\nlast_session_reset=%s\n' \
        "$FAILURES" "$NEXT_ATTEMPT" "$LAST_AUTH" "$LAST_SESSION_RESET" > "$temp" || return 1
    /bin/mv -f "$temp" "$STATE_FILE"
}

next_failure_delay() {
    case "$FAILURES" in
        0) NEXT_SLEEP=5 ;;
        1) NEXT_SLEEP=10 ;;
        2) NEXT_SLEEP=20 ;;
        3) NEXT_SLEEP=30 ;;
        *) NEXT_SLEEP=60 ;;
    esac
}

record_failure() {
    local now
    now="$(now_epoch)"
    next_failure_delay
    (( FAILURES < 5 )) && FAILURES=$((FAILURES + 1))
    NEXT_ATTEMPT=$((now + NEXT_SLEEP))
    save_state || log_message 'state=ERROR reason=retry_state_write_failed' || true
}

record_success() {
    FAILURES=0
    NEXT_ATTEMPT=0
    NEXT_SLEEP="$CHECK_INTERVAL"
    save_state || log_message 'state=ERROR reason=retry_state_write_failed' || true
    set_status CONNECTED internet_available
}

# Curl is always bounded. First probe intentionally follows the system's Internet route;
# Internet already working via a hotspot, VPN or wired link means no Wi-Fi changes.
probe_one() {
    local url="$1" kind="$2" response status body lower
    response="$(/usr/bin/curl -q --silent --noproxy '*' --connect-timeout 3 \
        --max-time 5 --max-filesize 4096 --max-redirs 0 --proto '=http' \
        --write-out $'\n%{http_code}' "$url" 2>/dev/null 9>&- | /usr/bin/head -c 8192 9>&-)"
    [[ "$response" == *$'\n'* ]] || {
        (( ${#response} >= 4096 )) && INTERNET_CAPTIVE=1
        return 1
    }
    status="${response##*$'\n'}"; body="${response%$'\n'*}"
    if [[ "$status" == 200 ]]; then
        if [[ "$kind" == microsoft && "$body" == 'Microsoft Connect Test' ]]; then return 0; fi
        if [[ "$kind" == apple ]]; then
            lower="$(printf '%s' "$body" | /usr/bin/tr '[:upper:]' '[:lower:]')"
            if [[ "$lower" == *'<title>success</title>'* && "$lower" == *'<body>success</body>'* ]]; then return 0; fi
        fi
        INTERNET_CAPTIVE=1
    elif [[ "$status" == 511 || "$status" == 3* ]]; then
        INTERNET_CAPTIVE=1
    fi
    return 1
}

internet_ok() {
    INTERNET_CAPTIVE=0
    probe_one 'http://captive.apple.com/hotspot-detect.html' apple && return 0
    probe_one 'http://www.msftconnecttest.com/connecttest.txt' microsoft && return 0
    return 1
}

wifi_device() {
    /usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '
      /^Hardware Port: (Wi-Fi|AirPort)[[:space:]]*$/ {wifi=1; next}
      /^Hardware Port:/ {wifi=0}
      wifi && /^Device: [A-Za-z][A-Za-z0-9]*[[:space:]]*$/ {print $2; exit}
    '
}

wifi_power() {
    local text
    text="$(/usr/sbin/networksetup -getairportpower "$WIFI_DEVICE" 2>/dev/null)"
    case "$text" in *': On') printf ON;; *': Off') printf OFF;; *) printf UNKNOWN;; esac
}

wifi_link() {
    local text
    text="$(/sbin/ifconfig "$WIFI_DEVICE" 2>/dev/null)"
    case "$text" in *'status: active'*) printf ACTIVE;; *'status: inactive'*) printf INACTIVE;; *) printf UNKNOWN;; esac
}

wifi_ip_ready() {
    local address
    address="$(/usr/sbin/ipconfig getifaddr "$WIFI_DEVICE" 2>/dev/null)"
    [[ -n "$address" && "$address" != 169.254.* ]]
}

profiler_json() {
    (( REPORT_READY )) && return 0
    REPORT_READY=1
    WIFI_REPORT="$(/usr/sbin/system_profiler SPAirPortDataType -json -detailLevel full -timeout 5 2>/dev/null 9>&- | /usr/bin/head -c 262144 9>&-)"
}

plist_raw() {
    printf '%s' "$WIFI_REPORT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

profiler_interface_index() {
    local index name
    PROFILER_INDEX=""
    profiler_json
    for index in {0..7}; do
        name="$(plist_raw "SPAirPortDataType.0.spairport_airport_interfaces.$index._name")"
        if [[ "$name" == "$WIFI_DEVICE" ]]; then
            PROFILER_INDEX="$index"
            return 0
        fi
    done
    return 1
}

current_ssid() {
    local value text
    CURRENT_SSID=UNKNOWN
    text="$(/usr/sbin/networksetup -getairportnetwork "$WIFI_DEVICE" 2>/dev/null)"
    if [[ "$text" == 'Current Wi-Fi Network: '* || "$text" == 'Current AirPort Network: '* ]]; then
        value="${text#*: }"
        if valid_ssid "$value"; then CURRENT_SSID="$value"; return 0; fi
    fi
    # Dynamic Store often retains the user's current SSID even when the
    # privacy-filtered networksetup answer says "not associated".
    text="$(printf 'show State:/Network/Interface/%s/AirPort\n' "$WIFI_DEVICE" | /usr/sbin/scutil 2>/dev/null 9>&-)"
    value="$(printf '%s\n' "$text" | /usr/bin/awk '/^[[:space:]]*SSID_STR[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
    if valid_ssid "$value"; then CURRENT_SSID="$value"; return 0; fi
    value="$(printf '%s\n' "$text" | /usr/bin/awk '/^[[:space:]]*SSID[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
    # scutil may return a CoreFoundation <data> blob. Decode only plausible
    # UTF-8 SSID bytes; 0x00 and other privacy placeholders stay UNKNOWN.
    if [[ "$value" == '<data> 0x'* ]]; then
        local hex="${value#'<data> 0x'}"
        if [[ "$hex" =~ ^[0-9a-fA-F]+$ && $(( ${#hex} % 2 )) -eq 0 && ${#hex} -le 64 ]]; then
            value="$(printf '%s' "$hex" | /usr/bin/xxd -r -p 2>/dev/null)"
        fi
    fi
    if valid_ssid "$value" && [[ "$value" != *[$'\001'-$'\037']* ]] &&
        printf '%s' "$value" | /usr/bin/iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        CURRENT_SSID="$value"; return 0
    fi
    text="$(/usr/sbin/ipconfig getsummary "$WIFI_DEVICE" 2>/dev/null)"
    value="$(printf '%s\n' "$text" | /usr/bin/awk '/^[[:space:]]*(SSID|ssid)[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
    if valid_ssid "$value"; then CURRENT_SSID="$value"; return 0; fi
    profiler_interface_index || return 1
    value="$(plist_raw "SPAirPortDataType.0.spairport_airport_interfaces.$PROFILER_INDEX.spairport_current_network_information._name")"
    if valid_ssid "$value"; then CURRENT_SSID="$value"; return 0; fi
    return 1
}

target_visible() {
    local network_index name
    profiler_interface_index || return 1
    for network_index in {0..31}; do
        name="$(plist_raw "SPAirPortDataType.0.spairport_airport_interfaces.$PROFILER_INDEX.spairport_airport_other_local_wireless_networks.$network_index._name")"
        [[ "$name" == "$TARGET_SSID" ]] && return 0
    done
    return 1
}

enable_wifi() {
    /usr/sbin/networksetup -setairportpower "$WIFI_DEVICE" on >/dev/null 2>&1 9>&-
}

join_target() {
    /usr/sbin/networksetup -setairportnetwork "$WIFI_DEVICE" "$TARGET_SSID" >/dev/null 2>&1 9>&-
}

# A positive response here identifies the GDOU SRun portal without relying on
# the SSID, which modern macOS may hide.  It never follows a redirect and does
# not send a credential.
srun_portal_available() {
    local headers
    headers="$(/usr/bin/curl -q --silent --noproxy '*' --connect-timeout 3 \
        --max-time 5 --max-filesize 4096 --max-redirs 0 --proto '=http' \
        --dump-header - --output /dev/null 'http://10.129.1.1/' 2>/dev/null 9>&- | /usr/bin/head -c 8192 9>&-)"
    [[ "$headers" == *$'\nSRunFlag: SRun portal server golang version'* ||
       "$headers" == *$'\nSRunFlag:'* ||
       "$headers" == *$'\nLocation: http://10.129.1.1/index_1.html'* ]]
}

run_auth() {
    /bin/bash "$SCRIPT_DIR/auth.sh" --attempt >/dev/null 2>&1 9>&-
}

run_self_logout() {
    /bin/bash "$SCRIPT_DIR/auth.sh" --self-logout >/dev/null 2>&1 9>&-
}

recover_stale_session() {
    # This is deliberately bounded to one verified self logout and one fresh
    # helper invocation.  auth.sh verifies rad_user_info and exact current-IP
    # ownership before it sends the Portal.js self-logout request.
    local now="$1" stale_reason="$2" reset_exit fresh_exit
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    set_status STALE_SESSION "$stale_reason"
    log_message 'state=STALE_SESSION_DETECTED result=two_probes_offline' || true
    if ! srun_portal_available; then
        log_message 'state=SESSION_RESET_FAILED reason=portal_not_confirmed' || true
        record_failure; return 1
    fi
    if (( now < LAST_SESSION_RESET + SESSION_RESET_COOLDOWN )); then
        log_message 'state=SESSION_RESET_FAILED reason=session_reset_cooldown' || true
        record_failure; return 1
    fi
    LAST_SESSION_RESET="$now"
    save_state || { log_message 'state=SESSION_RESET_FAILED reason=retry_state_write_failed' || true; record_failure; return 1; }
    log_message 'state=SELF_LOGOUT result=attempt_current_ip_only' || true
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    run_self_logout
    reset_exit=$?
    if (( reset_exit != 30 )); then
        log_message 'state=SESSION_RESET_FAILED reason=current_ip_session_not_confirmed_or_logout_failed' || true
        record_failure; return 1
    fi
    pause_seconds 3
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    log_message 'state=FRESH_REAUTH result=new_challenge_required' || true
    # A separate helper invocation always obtains a new challenge; no token
    # from the first login is retained or reused.  Its portal status is still
    # not treated as success until the Internet probe below passes.
    run_auth
    fresh_exit=$?
    if (( fresh_exit != 0 && fresh_exit != 10 )); then
        log_message 'state=SESSION_RESET_FAILED reason=fresh_login_not_accepted' || true
        record_failure; return 1
    fi
    pause_seconds 3
    if internet_ok; then
        log_message 'state=INTERNET_RESTORED result=after_fresh_reauth' || true
        record_success; return 0
    fi
    log_message 'state=SESSION_RESET_FAILED reason=fresh_login_still_offline' || true
    set_status NO_INTERNET fresh_login_did_not_restore_internet
    record_failure; return 1
}

attempt_srun_auth() {
    local reason="$1" auth_exit
    local now
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    now="$(now_epoch)"
    set_status AUTH_REQUIRED "$reason"
    if (( now < LAST_AUTH + AUTH_MIN_INTERVAL )); then
        set_status NO_INTERNET authentication_cooldown
        record_failure
        return 1
    fi
    LAST_AUTH="$now"
    save_state || { set_status NO_INTERNET retry_state_write_failed; record_failure; return 1; }
    set_status AUTHENTICATING srun_login
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    run_auth
    auth_exit=$?
    case "$auth_exit" in
        0)
            if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
            log_message 'state=AUTH_LOGIN_OK result=portal_login_ok' || true
            # Portal success alone is insufficient. Require two post-login
            # Internet probes before considering the session stale.
            pause_seconds 3
            if internet_ok; then
                log_message 'state=INTERNET_RESTORED result=after_login' || true
                record_success; return 0
            fi
            log_message 'state=AUTH_LOGIN_OK_BUT_OFFLINE result=first_probe_failed' || true
            pause_seconds 2
            if internet_ok; then
                log_message 'state=INTERNET_RESTORED result=after_login_retry_probe' || true
                record_success; return 0
            fi
            recover_stale_session "$now" login_ok_two_probes_offline
            return $?
            ;;
        10)
            if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
            log_message 'state=AUTH_LOGIN_OK result=ip_already_online' || true
            # "Already online" proves neither that the session is usable nor
            # that Internet access exists.  Probe twice before considering a
            # current-IP-only stale-session reset.
            pause_seconds 3
            if internet_ok; then
                log_message 'state=INTERNET_RESTORED result=already_online' || true
                record_success; return 0
            fi
            log_message 'state=AUTH_LOGIN_OK_BUT_OFFLINE result=already_online_first_probe_failed' || true
            pause_seconds 2
            if internet_ok; then
                log_message 'state=INTERNET_RESTORED result=already_online_retry_probe' || true
                record_success; return 0
            fi
            recover_stale_session "$now" already_online_two_probes_offline
            return $?
            ;;
        20) log_message 'Campus authentication failed: online device limit reached.' || true ;;
        *) log_message 'Campus authentication failed; details suppressed.' || true ;;
    esac
    pause_seconds 3
    if internet_ok; then record_success; return 0; fi
    set_status NO_INTERNET authentication_did_not_restore_internet
    record_failure
    return 1
}

recover_join() {
    local action="$1" current
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    set_status RECONNECTING "$action"
    join_target || log_message 'state=RECONNECTING result=join_command_failed' || true
    pause_seconds 5
    if is_paused; then NEXT_SLEEP="$CHECK_INTERVAL"; return 0; fi
    if internet_ok; then record_success; return 0; fi
    # Even a successful networksetup exit needs association/Internet verification.
    current_ssid || true
    set_status NO_INTERNET join_not_verified
    record_failure
    return 1
}

run_cycle() {
    local now power link original_ssid auth_exit
    NEXT_SLEEP="$CHECK_INTERVAL"
    # This is the first daemon action in every cycle.  A paused installation
    # makes no Internet probe, Wi-Fi change, authentication, or reset.
    if is_paused; then return 0; fi
    # Internet is checked before reading or changing the Wi-Fi association.
    if internet_ok; then record_success; return 0; fi
    now="$(now_epoch)"
    if (( now < NEXT_ATTEMPT )); then
        NEXT_SLEEP=$((NEXT_ATTEMPT - now))
        (( NEXT_SLEEP <= 60 )) || NEXT_SLEEP=60
        set_status NO_INTERNET recovery_cooldown
        return 1
    fi
    WIFI_DEVICE="$(wifi_device)"
    if [[ -z "$WIFI_DEVICE" ]]; then
        CURRENT_SSID=UNKNOWN
        set_status WIFI_DISCONNECTED no_wifi_device
        record_failure; return 1
    fi
    power="$(wifi_power)"; link="$(wifi_link)"
    if [[ "$power" == OFF ]]; then
        if is_paused; then return 0; fi
        CURRENT_SSID=UNKNOWN
        set_status RECONNECTING enabling_wifi
        if ! enable_wifi; then
            set_status WIFI_DISCONNECTED power_change_failed
            record_failure; return 1
        fi
        pause_seconds 2
        if internet_ok; then record_success; return 0; fi
        power="$(wifi_power)"; link="$(wifi_link)"
        if [[ "$power" != ON ]]; then
            set_status WIFI_DISCONNECTED power_not_on
            record_failure; return 1
        fi
    fi
    if [[ "$link" == INACTIVE ]]; then
        if is_paused; then return 0; fi
        CURRENT_SSID=UNKNOWN
        recover_join no_association; return $?
    fi
    if [[ "$link" != ACTIVE || "$power" != ON ]]; then
        CURRENT_SSID=UNKNOWN
        set_status NO_INTERNET wifi_state_unknown
        record_failure; return 1
    fi
    current_ssid || true
    if [[ "$CURRENT_SSID" == UNKNOWN ]]; then
        # UNKNOWN is an active association whose name is hidden, not a missing
        # association.  Only a locally verified SRun portal permits login.
        if ! is_paused && srun_portal_available; then
            attempt_srun_auth srun_portal_detected_ssid_unknown
            return $?
        fi
        set_status NO_INTERNET ssid_unknown_preserving_connection
        record_failure; return 1
    fi
    if [[ "$CURRENT_SSID" == "$TARGET_SSID" ]]; then
        if ! wifi_ip_ready; then
            set_status NO_INTERNET dhcp_pending
            pause_seconds 5
            if internet_ok; then record_success; return 0; fi
            record_failure; return 1
        fi
        if ! is_paused && { (( INTERNET_CAPTIVE )) || srun_portal_available; }; then
            attempt_srun_auth possible_srun_portal
            return $?
        else
            set_status NO_INTERNET probe_failed_without_portal_evidence
        fi
        record_failure; return 1
    fi
    original_ssid="$CURRENT_SSID"
    if ! target_visible; then
        set_status NO_INTERNET other_wifi_target_not_visible
        record_failure; return 1
    fi
    # The user can switch networks during the scan. Recheck Internet and association.
    if internet_ok; then record_success; return 0; fi
    REPORT_READY=0; WIFI_REPORT=""
    current_ssid || true
    if [[ "$CURRENT_SSID" != "$original_ssid" || "$(wifi_link)" != ACTIVE ]]; then
        set_status NO_INTERNET association_changed_preserving_connection
        record_failure; return 1
    fi
    if is_paused; then return 0; fi
    recover_join other_wifi_offline_target_visible; return $?
}

show_status() {
    local online=NO power link automation=ACTIVE
    is_paused && automation=PAUSED
    if internet_ok; then online=YES; fi
    WIFI_DEVICE="$(wifi_device)"
    if [[ -n "$WIFI_DEVICE" ]]; then
        power="$(wifi_power)"; link="$(wifi_link)"
        if [[ "$power" == ON && "$link" == ACTIVE ]]; then
            current_ssid || true
        else
            CURRENT_SSID=UNKNOWN
        fi
    else
        power=UNKNOWN; link=UNKNOWN; CURRENT_SSID=UNKNOWN
    fi
    printf 'Wi-Fi device: %s\nWi-Fi power: %s\nWi-Fi link: %s\nCurrent SSID: %s\nInternet: %s\nAuthentication adapter: SRun configured\nAutomation: %s\n' \
        "${WIFI_DEVICE:-NONE}" "$power" "$link" "$CURRENT_SSID" "$online" "$automation"
}

main() {
    local mode="${1:---daemon}"
    case "$mode" in --daemon|--once|--status|--pause|--resume) ;; *) printf 'Usage: gdou-connect.sh [--daemon|--once|--status|--pause|--resume]\n' >&2; return 2;; esac
    [[ "$(/usr/bin/uname -s)" == Darwin ]] || { printf 'macOS required.\n' >&2; return 2; }
    if [[ "$mode" == --daemon || "$mode" == --once ]] || { [[ "$mode" == --status && -e "$CONFIG_FILE" ]]; }; then
        read_config || { printf 'Non-secret config is invalid or missing.\n' >&2; return 2; }
    fi
    if [[ "$mode" == --pause ]]; then pause_automation; return $?; fi
    if [[ "$mode" == --resume ]]; then resume_automation; return $?; fi
    if [[ "$mode" == --status ]]; then show_status; return 0; fi
    prepare_runtime || { printf 'Runtime directory is unsafe or unavailable.\n' >&2; return 2; }
    [[ -L "$LOCK_FILE" ]] && return 2
    exec 9>> "$LOCK_FILE" || return 2
    if ! /usr/bin/lockf -s -t 0 9; then
        if [[ "$mode" == --once ]]; then
            printf 'Monitor is already running; --once made no network changes.\n' >&2
            return 75
        fi
        return 0
    fi
    load_state
    if [[ "$mode" == --once ]]; then run_cycle; return 0; fi
    trap 'exit 0' INT TERM
    while :; do
        run_cycle || true
        pause_seconds "$NEXT_SLEEP" 9>&- & wait $! || true
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
