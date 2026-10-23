#!/usr/bin/env bash

# This wrapper must remain in the invoking shell so cleanup affects that shell.
clashuninstall() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl uninstall [--yes]\n停止内核、移除安装，并清除当前终端代理变量和命令。\n--yes 跳过确认；取消或卸载失败时保留当前终端环境。\n'
        return 0 ;;
    '' | -y | --yes) [ "$#" -le 1 ] || { _ui_error '用法: clashctl uninstall [--yes]'; return 1; } ;;
    *) _ui_error '用法: clashctl uninstall [--yes]'; return 1 ;;
    esac
    local installation=$CLASHCTL_HOME command_file name functions_to_remove='clashctl'
    [ -f "$installation/uninstall.sh" ] || { _ui_error '未找到卸载脚本，请检查安装目录。'; return 1; }
    for command_file in "$installation"/scripts/cmd/*.sh; do
        name=${command_file##*/}
        name=${name%.sh}
        case $name in clashctl | *[!a-zA-Z0-9_-]*) continue ;; esac
        functions_to_remove+=" clash$name"
    done
    CLASHCTL_UNINSTALL_SHELL_CLEANUP=1 bash "$installation/uninstall.sh" "$@" || return
    # Cancellation returns success but retains the installation.
    [ ! -e "$installation" ] && [ ! -L "$installation" ] || return 0
    unset_system_proxy
    unset CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_KERNEL INIT_TYPE
    # Use native word splitting in each supported shell; no eval is involved.
    if [ -n "${ZSH_VERSION:-}" ] && [ -z "${BASH_VERSION:-}" ]; then
        for name in ${=functions_to_remove}; do unfunction "$name" 2>/dev/null || true; done
    else
        for name in $functions_to_remove; do unset -f "$name" 2>/dev/null || true; done
    fi
    printf '当前终端代理与 clashctl 命令已清理。\n'
    return 0
}
