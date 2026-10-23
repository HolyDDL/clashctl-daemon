#!/usr/bin/env bash

clashon() {
    local _CLASHCTL_START_FROM_ON=1
    [ "$#" -le 1 ] || { _ui_fail '用法: clashctl on [--help]'; return 1; }
    case "${1:-}" in
    -h | --help)
        on_help
        return
        ;;
    '') clashstart || return ;;
    *) _ui_fail '用法: clashctl on [--help]'; return 1 ;;
    esac
    set_system_proxy || return 1
    _ui_ok_out 'Terminal proxy enabled.'
}

on_help() {
    cat <<EOF

clashctl on - 启用当前终端代理，内核未运行时先启动

Usage:
  clashctl on [OPTIONS]

Options:
  -h, --help  显示帮助信息

仅影响当前终端及其后续子进程。端口改变后重新执行本命令。
关闭代理使用 clashctl off，同时停止内核使用 clashctl off --stop。
也可使用 clashctl tui 中的当前终端代理菜单。

EOF
}

_proxy_env_values() {
    local http_address socks_address
    _proxy_addresses "$CLASH_CONFIG_RUNTIME" || {
        _ui_error 'Cannot read proxy connection settings.'; return 1;
    }
    if [ -z "$http_address" ] || [ -z "$socks_address" ]; then
        _ui_error 'No usable HTTP or SOCKS proxy port is configured.'
        return 1
    fi
    printf '%s|%s\n' "$http_address" "$socks_address"
}

set_system_proxy() {
    local proxy_values http_proxy_addr socks_proxy_addr
    if _clashctl_in_bash; then
        proxy_values=$(_proxy_env_values) || return 1
    else
        proxy_values=$(_clashctl_run_in_bash _proxy_env_values) || return 1
    fi
    IFS='|' read -r http_proxy_addr socks_proxy_addr <<<"$proxy_values"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export HTTP_PROXY=$http_proxy

    export https_proxy=$http_proxy
    export HTTPS_PROXY=$https_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
    return 0
}

_dump_proxy_env_fish() {
    local v val
    for v in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
        val=${!v}
        [ -z "$val" ] && continue
        val=${val//\\/\\\\}
        val=${val//\'/\\\'}
        printf "set -gx %s '%s'\n" "$v" "$val"
    done
}
