#!/usr/bin/env bash

# 首次初始化时 .env 尚未创建
if [ -f "$CLASHCTL_HOME/.env" ]; then
    . "$CLASHCTL_HOME/.env" || return 1
fi

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    # shellcheck disable=SC1090  # 运行时按安装目录加载公共库
    . "$lib_file" || return 1
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    # Match the filename only: custom directories may contain "clashctl.".
    case ${cmd_file##*/} in clashctl.sh) continue ;; esac
    # shellcheck disable=SC1090  # 运行时按安装目录加载子命令
    . "$cmd_file" || return 1
done

clashctl() {
    local sub_cmd
    sub_cmd=${1:-help}
    shift

    case $sub_cmd in
    -h | --help | help) sub_cmd=help ;;
    -v | --version) sub_cmd=version ;;
    -*)
        _ui_fail "Unknown option: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
        ;;
    esac

    local target="clash${sub_cmd}"
    # Files can be updated while this terminal still holds the previous functions.
    if ! typeset -f "$target" >/dev/null 2>&1; then
        case $sub_cmd in
        '' | *[!a-zA-Z0-9_-]*) ;;
        *)
            if [ -f "$CLASHCTL_HOME/scripts/cmd/$sub_cmd.sh" ]; then
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || return 1
            fi
            ;;
        esac
    fi
    typeset -f "$target" >/dev/null 2>&1 || {
        if [ "$sub_cmd" = tui ]; then
            _ui_fail 'TUI files are missing or the installation is out of date.'
            _ui_fail 'Run clashctl update, then reopen your terminal.'
            return 1
        fi
        _ui_fail "Unknown subcommand: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
    }

    # on/off/tui/uninstall 需要修改当前 Shell 的代理变量，update 需要把新版本重新载入当前
    # Shell，help/version 为零依赖纯文本；其余命令统一在 Bash 子进程中执行。
    case $sub_cmd in
    on | off | tui | uninstall | update | help | version) ;;
    *)
        if ! _clashctl_in_bash; then
            _clashctl_run_in_bash "$target" "$@"
            return
        fi
        ;;
    esac

    "$target" "$@"
}
