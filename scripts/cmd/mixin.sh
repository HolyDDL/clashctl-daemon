#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashmixin() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashmixin "$@"
        return
    fi
    case "$1" in
    -h | --help)
        mixin_help
        return 0
        ;;
    -e)
        "${EDITOR:-vim}" "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    -c)
        less "$CLASH_CONFIG_BASE"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

mixin_help() {
    cat <<EOF
用法: clashctl mixin [-e|-r|-c]

  无选项    查看 Mixin 用户配置：$CLASH_CONFIG_MIXIN
  -e        使用 EDITOR（默认 vim）编辑；校验成功后重启生效
  -r        查看合并后的运行配置：$CLASH_CONFIG_RUNTIME
  -c        查看当前订阅基础配置：$CLASH_CONFIG_BASE

端口、运行模式等常用设置也可通过 clashctl tui 调整。
端口改变后，请在各终端执行 clashctl on 刷新代理变量。
EOF
}
