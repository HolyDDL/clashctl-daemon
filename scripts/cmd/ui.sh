#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashui() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl ui\n首次使用时准备 Web 面板，必要时启动内核，显示面板访问地址。\n终端可视化管理请使用 clashctl tui。\n'
        return 0 ;;
    '') [ "$#" -eq 0 ] || return 1 ;;
    *) _ui_error '用法: clashctl ui'; return 1 ;;
    esac
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashui
        return
    fi
    [ -f "$CLASH_RESOURCES_DIR/dist/index.html" ] || _ci_provision ui || return 1
    service_is_active >&/dev/null || clashstart >/dev/null || return 1
    _detect_ext_addr || return 1
    service_is_active >&/dev/null || _errorcat "无法启动服务，请检查日志" || return

    local query_url='https://api64.ipify.org'
    local public_ip
    public_ip=$(curl -s --noproxy "*" --location --max-time 2 "$query_url")
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"

    local common_address='http://board.zash.run.place'
    
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                  Web 控制台                   ║\n"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$EXT_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$common_address"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}
