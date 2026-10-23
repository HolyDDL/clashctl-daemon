#!/usr/bin/env bash

clashlog() {
    if [ "$#" -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
        cat <<'EOF'
用法: clashctl log [日志选项]

  clashctl log -n 50     查看最近 50 行
  clashctl log -f        持续跟踪日志（Ctrl+C 退出）

用户级服务读取用户 journal；nohup 或特权 TUN 内核读取安装目录中的日志。
其他参数传给相应后端 journalctl / tail；无参数使用默认查看方式。
EOF
        return 0
    fi
    service_log "$@"
}
