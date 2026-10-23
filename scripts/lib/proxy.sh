#!/usr/bin/env bash

_proxy_local_host() {
    local host=$1
    case $host in
    '' | '*' | 0.0.0.0) host=127.0.0.1 ;;
    :: | '[::]') host='::1' ;;
    esac
    host=${host#\[}
    host=${host%\]}
    case $host in '' | *[!a-zA-Z0-9.:%_-]*) return 1 ;; esac
    case $host in *:*) host="[${host//%/%25}]" ;; esac
    printf '%s\n' "$host"
}

_proxy_port() {
    local port=${1:-0}
    [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] || return 1
    if [ "$((10#$port))" -eq 0 ]; then port=${2:-0}; fi
    [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] || return 1
    ((10#$port > 0 && 10#$port <= 65535)) || return 1
    printf '%d\n' "$((10#$port))"
}

_proxy_urlencode() {
    local LC_ALL=C value=$1 encoded='' character code index
    for ((index = 0; index < ${#value}; index++)); do
        character=${value:index:1}
        case $character in
        [a-zA-Z0-9._~-]) encoded+=$character ;;
        *) printf -v code '%%%02X' "'$character"; encoded+=$code ;;
        esac
    done
    printf '%s' "$encoded"
}

# Output variables belong to the caller. Reports omit credentials entirely.
_proxy_addresses() {
    local config=${1:-$CLASH_CONFIG_RUNTIME} credentials=${2:-true}
    local values mixed_port http_port socks_port bind_addr allow_lan host port auth_base64 auth='' auth_prefix=''
    http_address='' socks_address=''
    values=$("$BIN_YQ" -er 'select(tag == "!!map") |
        [.mixed-port // 0, .port // 0, .socks-port // 0,
         .bind-address // "*", .allow-lan // false,
         (.authentication[0] // "" | @base64)] | @tsv' "$config" 2>/dev/null) || return 1
    values=${values//$'\t'/$'\x1f'}
    IFS=$'\x1f' read -r mixed_port http_port socks_port bind_addr allow_lan auth_base64 <<<"$values"
    if [ "$credentials" = true ] && [ -n "$auth_base64" ]; then
        auth=$(printf '%s' "$auth_base64" | base64 --decode 2>/dev/null && printf '.') || return 1
        auth=${auth%.}
        if [ -n "$auth" ]; then
            case $auth in
            *:*) auth_prefix="$(_proxy_urlencode "${auth%%:*}"):$(_proxy_urlencode "${auth#*:}")@" ;;
            *) auth_prefix="$(_proxy_urlencode "$auth")@" ;;
            esac
        fi
    fi
    case $allow_lan in
    false) host=127.0.0.1 ;;
    true) host=$(_proxy_local_host "$bind_addr") || return 1 ;;
    *) return 1 ;;
    esac
    if port=$(_proxy_port "$http_port" "$mixed_port"); then http_address="http://${auth_prefix}${host}:${port}"; fi
    if port=$(_proxy_port "$socks_port" "$mixed_port"); then socks_address="socks5h://${auth_prefix}${host}:${port}"; fi
    return 0
}
