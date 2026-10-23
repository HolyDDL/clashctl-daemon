#!/usr/bin/env bash

clashhelp() {
  cat <<'EOF'
clashctl-daemon — 命令行与终端可视化代理管理

Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  tui                   打开 TUI；Language / 语言可选 English、简体中文
  on                    启动内核并启用当前终端代理
  off [--stop]          关闭当前终端代理；--stop 同时停止内核
  start                 仅启动内核，不修改终端代理变量
  stop                  仅停止内核，不清除终端代理变量
  status [--verbose]    查看内核、订阅、终端代理及连接地址
  sub                   添加、切换、更新订阅
  node                  选择策略组和节点，或测量延迟
  mixin [-e|-r|-c]      查看配置；-e 编辑并校验、重启生效
  ui                    准备 Web 面板并显示访问地址
  tun [on|off]          查看或切换 TUN；启用需要 sudo
  secret [密钥]         查看或修改控制接口密钥
  log [-n 行数] [-f]    查看内核日志，-f 持续跟踪
  update                更新本 fork 的管理脚本与资源
  upgrade               升级代理内核
  version               查看脚本与内核版本
  uninstall [--yes]     卸载并清除当前终端代理和命令

Global Options:
  -h, --help            显示此帮助
  -v, --version         显示版本

常用操作:
  clashctl sub add --use "<订阅链接>"
  clashctl on
  clashctl tui

默认使用用户级 systemd 守护进程。代理端口默认 37700，占用时自动更换。
端口改变后，请在各终端执行 clashctl on 刷新代理变量。
子命令帮助: clashctl <命令> --help
项目文档: https://github.com/HolyDDL/clashctl-daemon
EOF
}
