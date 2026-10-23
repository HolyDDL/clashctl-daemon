#!/usr/bin/env bash

_write_proxy_startup_report() (
    umask 077
    local http_address socks_address previous_http='None (first start)' previous_socks='None (first start)' report
    if [ -f "$CLASH_PROXY_LAST" ]; then
        _proxy_addresses "$CLASH_PROXY_LAST" false || {
            _ui_error 'Cannot read the previous proxy addresses.'; return 1;
        }
        previous_http=${http_address:-Disabled}
        previous_socks=${socks_address:-Disabled}
    fi
    _proxy_addresses "$CLASH_CONFIG_RUNTIME" false || return 1
    report=$(mktemp "${CLASH_PROXY_REPORT}.XXXXXX") || return 1
    trap 'command rm -f -- "$report"' EXIT
    printf '%s\t%s\t%s\t%s\t%s\n' "$previous_http" "$previous_socks" "${_PROXY_PORT_CONFLICT:-No}" \
        "${http_address:-Disabled}" "${socks_address:-Disabled}" >"$report" || return 1
    command mv -f -- "$report" "$CLASH_PROXY_REPORT"
)

_show_proxy_startup_report() {
    local values previous_http previous_socks conflict current_http current_socks
    [ -f "$CLASH_PROXY_REPORT" ] || return 0
    IFS= read -r values <"$CLASH_PROXY_REPORT" || return 1
    values=${values//$'\t'/$'\x1f'}
    IFS=$'\x1f' read -r previous_http previous_socks conflict current_http current_socks <<<"$values"
    local conflict_color=32
    case $conflict in Yes*) conflict_color=33 ;; esac
    printf '\n' >&2
    _proxy_startup_line 'Proxy startup' '' 36
    _proxy_startup_line 'Previous HTTP' "$previous_http" 90
    _proxy_startup_line 'Previous SOCKS' "$previous_socks" 90
    _proxy_startup_line 'Port conflict' "$conflict" "$conflict_color"
    _proxy_startup_line 'Current HTTP' "$current_http" 32
    _proxy_startup_line 'Current SOCKS' "$current_socks" 32
    printf '\n' >&2
}

_proxy_startup_line() {
    if _ui_color_enabled 2; then
        printf '  \033[1;%sm%-15s\033[0m %s\n' "$3" "$1" "$2" >&2
    else
        printf '  %-15s %s\n' "$1" "$2" >&2
    fi
}

_remember_proxy_start() (
    umask 077
    local snapshot
    snapshot=$(mktemp "${CLASH_PROXY_LAST}.XXXXXX") || return 1
    trap 'command rm -f -- "$snapshot"' EXIT
    # Persist listeners only; do not copy subscription contents or credentials.
    "$BIN_YQ" '{"mixed-port": (.mixed-port // 0), "port": (.port // 0),
        "socks-port": (.socks-port // 0), "bind-address": (.bind-address // "*"),
        "allow-lan": (.allow-lan // false)}' "$CLASH_CONFIG_RUNTIME" >"$snapshot" || return 1
    command mv -f -- "$snapshot" "$CLASH_PROXY_LAST"
)

_prepare_kernel_start() (
    local lock_dir="${CLASH_DATA_DIR}/startup.lock.d" lock_pid='' lock_token='' _PROXY_PORT_CONFLICT='No'
    trap 'trap "" HUP INT TERM; _directory_lock_release "$lock_dir" "${lock_pid:-${_DIRECTORY_LOCK_PID:-}}" "${lock_token:-${_DIRECTORY_LOCK_TOKEN:-}}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    _directory_lock_acquire "$lock_dir" 10 || return 1
    lock_pid=$_DIRECTORY_LOCK_PID lock_token=$_DIRECTORY_LOCK_TOKEN
    _merge_config || return 1
    _detect_proxy_port || return 1
    _detect_ext_addr || return 1
    _write_proxy_startup_report
)

_service_has_startup_hook() {
    local target
    case ${service_manager:-} in systemd | systemd-user) ;; *) return 1 ;; esac
    target=$(_service_target) || return 1
    [ -f "$target" ] && grep -Fq "ExecStartPre=/usr/bin/env bash $CLASHCTL_HOME/scripts/kernel-start.sh prepare " "$target"
}

_kernel_start() {
    local privileged=${1:-} rc=0 report_before=''
    detect_service_manager
    if [ "$privileged" != privileged ] && ! _is_tun_enabled && _service_has_startup_hook; then
        # systemd runs the same check on login, automatic restart, and CLI start.
        report_before=$(stat -c %i -- "$CLASH_PROXY_REPORT" 2>/dev/null) || report_before=''
        service_start || rc=$?
        if [ "$(stat -c %i -- "$CLASH_PROXY_REPORT" 2>/dev/null)" != "$report_before" ]; then
            _show_proxy_startup_report || return 1
        fi
    else
        _prepare_kernel_start || return 1
        _show_proxy_startup_report || return 1
        if [ "$privileged" = privileged ]; then service_sudo_start || rc=$?; else service_start || rc=$?; fi
    fi
    [ "$rc" -eq 0 ] || return "$rc"
    _remember_proxy_start
}
