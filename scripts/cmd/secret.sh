#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashsecret() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashsecret "$@"
        return
    fi
    case "$1" in
    -h | --help)
        secret_help
        return 0
        ;;
    esac

    case $# in
    0)
        printf '控制接口密钥：%s\n' "$(_get_secret)"
        ;;
    1)
        SECRET=$1 "$BIN_YQ" -i '.secret = strenv(SECRET)' "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        case $? in
        1)
            _failcat "密钥已写入 Mixin，但配置验证未通过，暂未生效"
            return 1
            ;;
        2)
            _failcat "密钥已写入 Mixin 与运行配置，但服务重启失败，请检查代理内核日志"
            return 1
            ;;
        esac
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "参数错误，请使用 -h 查看帮助"
        ;;
    esac
}

secret_help() {
    cat <<'EOF'
用法: clashctl secret [密钥]

无参数查看控制接口密钥；传入新密钥后保存配置并重启生效。
该密钥用于 Web 面板和内核管理接口，与代理用户名/密码不同。
也可通过 clashctl tui 的面板与密钥菜单修改，输入时不回显。
EOF
}
