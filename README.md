# clashctl-daemon

Linux 上的 Mihomo / Clash 安装与管理工具，基于 [nelvko/clashctl](https://github.com/nelvko/clashctl) 开发。本 fork 默认使用普通用户的 systemd 守护进程，统一通过 `clashctl` 管理内核、订阅和配置。

项目使用 Bash 实现安装与管理逻辑，支持 Bash、Zsh、Fish 命令集成，使用 MikeFarah yq v4 处理 YAML。实际代理转发由独立的 Mihomo / Clash 内核完成。

## 特性

- **按需安装**：安装代理内核与运行依赖，Web 面板和订阅转换器在首次使用时准备。
- **广泛兼容**：支持 `root` 与普通用户，适配主流 Linux 发行版及容器环境。兼容 systemd、OpenRC 等服务方式，提供 Bash、Zsh 和 Fish 命令集成。
- **功能丰富**：涵盖代理开关、内核启停、状态查看、日志追踪等常用操作，支持 Web 面板、TUN 模式、内核升级及 `Mixin` 配置。
- **订阅管理**：支持多订阅添加、切换与更新，集成 [subconverter](https://github.com/asdlokj1qpi233/subconverter) 实现订阅格式转换。

## 安装

首次安装或从旧版升级，在普通用户会话中执行以下命令（使用下载代理）：

```bash
GH_PROXY=https://gh-proxy.org/
curl -fsSL "${GH_PROXY}https://raw.githubusercontent.com/HolyDDL/clashctl-daemon/HEAD/install.sh" | \
  bash -s -- --gh-proxy "$GH_PROXY"
```

- `GH_PROXY`：[GitHub 下载加速代理](https://gh-proxy.org/)，失效时可更换[其他可用地址](https://ghproxy.link/)。

也可以直接克隆本 fork 后安装：

```bash
git clone https://github.com/HolyDDL/clashctl-daemon.git
cd clashctl-daemon
bash install.sh --local
```

`--local` 表示使用刚克隆的本地源码；缺失的内核等依赖仍会按需联网下载。

需要自定义安装位置时，单独指定绝对路径，例如：

```bash
bash install.sh --local --install-dir /data/ryw/clashctl
```

安装完成后按安装器提示加载 Shell 配置，或重新打开终端，再执行 `clashctl help`。默认安装目录为 `~/.clashctl`；自定义目录使用 `--install-dir`，不要与开发源码目录混用。

### 普通用户安装与守护

在普通用户的登录会话中，从本地源码安装用户级 systemd 服务，无需 `sudo`：

```bash
bash install.sh --local
```

默认使用 `--service systemd-user`，需要在普通用户的登录会话中运行，并且用户级 systemd 管理器可连接、版本不低于 243。不满足条件时安装报错，不会回退到 `nohup` 或系统级服务。重新运行以上命令也会将当前用户的 `nohup` 安装切换为用户级服务；安装在其他位置时，请通过 `--install-dir` 指定实际目录。

需要保留已有运行方式或兼容无用户级 systemd 的环境时，可显式使用 `--service auto`；仅需后台运行时可显式使用 `--service nohup`。

服务文件写入 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`，支持登录自启和异常自动重启。日常操作统一使用 `clashctl`，服务由脚本调用用户级 systemd 管理：

```bash
clashctl start        # 启动内核
clashctl stop         # 停止内核
clashctl status       # 查看内核与当前终端代理状态
clashctl log          # 查看内核日志
clashctl sub list     # 查看订阅
clashctl mixin -e     # 编辑配置，合并、校验后重启生效
```

普通 HTTP/SOCKS 代理的安装、启停、日志查看和异常自动重启均无需管理员权限。用户级服务的生命周期与用户管理器一致；若还需要退出所有登录会话后继续运行，以及未登录时开机自启，可手动执行：

```bash
loginctl enable-linger "$(id -un)"
loginctl show-user "$(id -un)" -p Linger
```

开启 linger 是否需要管理员授权取决于系统策略；安装器不会自动开启。TUN 模式需要网络管理权限，当前实现仍通过 `sudo` 启动特权内核。`nohup` 支持后台运行，不提供异常自动重启或开机自启。

已有 root 安装的系统级服务需要先由管理员停用，避免与用户级服务重复运行；普通用户安装不会接管系统级服务。

### 启动时的端口检测

默认 HTTP/SOCKS 混合代理端口为 `37700`。每次启动优先检查配置中已保存的端口，空闲时继续使用；被占用时从 `49152–65535` 随机选择空闲端口，并保存到 Mixin，供下次启动复用。独立 HTTP、SOCKS 监听端口也会分别检查，避免选到同一个端口或控制接口端口。端口检测失败时停止启动，不会将未知状态当作空闲。

启动时用英文显示上一次启动的代理地址、端口冲突结果和本次选择的代理地址，例如：

```text
  Proxy startup
  Previous HTTP   http://127.0.0.1:37700
  Previous SOCKS  socks5h://127.0.0.1:37700
  Port conflict   Yes (mixed-port: 37700 -> 55283)
  Current HTTP    http://127.0.0.1:55283
  Current SOCKS   socks5h://127.0.0.1:55283
```

终端支持颜色时使用彩色输出，重定向输出和设置 `NO_COLOR` 时保持纯文本。报告与历史记录不包含代理用户名、密码或订阅内容；首次启动会标明 `None (first start)`。内核已经运行时重复执行 `clashctl on` 只启用当前终端代理，不会把内核自己的端口当作冲突重新分配。

检测覆盖 `clashctl start/on`、配置或订阅切换引起的重启，以及 systemd 登录自启、手动重启和异常自动重启；自动启动的报告写入服务日志。已有安装需要重新执行本地安装命令以更新 systemd 服务定义。

后台重启若更换端口，已打开终端的环境变量不会自动变化；重新执行 `clashctl on` 即可使用本次端口。

### 服务管理的操作逻辑

`systemd` 是服务管理器，`systemctl` 是操作它的命令行工具。`clashctl` 负责配置合并、校验、端口检查及状态展示，再调用选定的服务后端。

| 操作 | 默认用户级服务的行为 |
| --- | --- |
| 安装 | 写入用户服务定义，执行 `systemctl --user daemon-reload` |
| 启动 | 执行 `systemctl --user start`，成功后启用登录自启 |
| 停止 | 执行 `systemctl --user stop`，不取消下次登录自启 |
| 配置或订阅切换 | 合并、校验新配置，再停止并启动内核 |
| 异常退出 | systemd 按 `Restart=on-failure` 自动重启，并重新检查端口 |
| 卸载 | 停止服务、取消自启、删除服务定义并重新加载管理器 |

默认内核的服务名为 `mihomo.service`。排障时可直接使用：

```bash
systemctl --user status mihomo
journalctl --user -u mihomo -n 100
systemctl --user restart mihomo
```

使用 Clash 内核时将服务名换成 `clash`。日常优先使用 `clashctl`；直接调用 `systemctl` 不会更新当前终端的代理变量。项目没有单独的 `clashctl restart` 命令，可执行 `clashctl stop && clashctl start`。

## 终端可视化管理

安装并重新打开终端后，执行：

```bash
clashctl tui
```

界面使用英文，通过方向键或 `j` / `k` 移动，Enter 进入，也可以按数字直接选择；`q` / Esc 返回，主菜单返回即退出。输入框留空取消操作。支持彩色终端，设置 `NO_COLOR=1` 可关闭颜色。需要交互终端，不额外依赖 Python、dialog 或图形桌面。

界面定期刷新状态。顶部显示内核状态、运行模式、代理端口、登录自启、当前订阅和代理地址。菜单包含：

| 菜单 | 可执行操作 |
| --- | --- |
| Kernel & startup | 内核启动、停止、重启，启用或禁用登录自启，查看详细状态 |
| Subscriptions | 查看、添加并启用、切换、更新全部、删除订阅及操作日志 |
| Nodes & latency | 进入已有的节点切换和延迟选择界面 |
| Proxy ports | 修改混合端口、独立 HTTP/SOCKS 端口，查看代理地址 |
| Proxy settings | Rule/Global/Direct 模式、局域网访问、TUN、完整 Mixin 编辑 |
| Dashboard & secret | 面板地址、控制接口监听地址、控制接口密钥 |
| Logs & diagnostics | 最近日志、详细状态、版本及运行配置 |

端口、运行模式、局域网访问、控制接口地址和密钥在临时配置中修改，通过完整配置校验后保存；校验失败保持原配置。内核运行时重启生效，内核停止时仅保存，在下次启动时生效。完整 Mixin 编辑、订阅切换及 TUN 操作沿用对应命令的启停逻辑。更改端口后，每个终端需要执行 `clashctl on` 刷新代理变量。

TUI 管理的是后台内核，当前终端的代理环境仍使用 `clashctl on/off` 管理。禁用登录自启不会停止正在运行的内核；随后使用 `clashctl start` 启动内核会重新启用自启。退出界面会恢复终端显示，后台服务继续按当前状态运行。

## 快速上手

未添加订阅时可以以直连模式启动；这只提供本地代理入口，不会产生远程代理节点。

添加并启用订阅（可选）：

```bash
clashctl sub add --use "<订阅链接>"
```

开启当前终端代理：

```bash
# 自动启动内核，并开启当前终端代理
clashctl on

# 测试连通性
curl -I https://www.google.com
```

## 命令一览

```text
Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  on                    启用当前终端代理，自动启动内核
  off                   关闭当前终端代理，默认保留内核运行
  start                 仅启动内核
  stop                  仅停止内核
  status                内核、终端代理状态及代理地址
  tui                   终端可视化管理
  ui                    面板地址
  sub                   订阅管理
  node                  节点切换
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  log                   查看日志
  upgrade               升级内核
  update                更新 clashctl
  version               脚本和内核版本

Global Options:
  -h, --help            显示帮助信息
  -v, --version         显示版本信息
```

### 终端代理与内核的区别

| 命令 | 内核 | 当前终端代理环境变量 |
| --- | --- | --- |
| `clashctl on` | 未运行时启动，已运行时复用 | 按当前端口设置 |
| `clashctl off` | 保持运行 | 清除 |
| `clashctl off --stop` | 停止 | 先清除，即使停止失败也保持清除 |
| `clashctl start` | 启动 | 不修改 |
| `clashctl stop` | 停止，影响共享此内核的客户端 | 不修改，需要时再执行 `off` |

`on` 设置大小写的 `http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`。HTTP 与 HTTPS 请求使用 HTTP 代理，`all_proxy` 使用 `socks5h`；本地回环地址不走代理。独立 HTTP/SOCKS 端口为 `0` 时使用混合端口，地址支持 IPv6 和认证信息编码。

这些变量只影响当前 Shell 及其后续启动的子进程，不会自动配置桌面系统、其他终端或已运行的应用。浏览器等客户端需要自行填写 `clashctl status` 显示的代理地址。内核端口改变后，每个需要代理的终端应重新执行 `clashctl on`。

### 订阅与节点

```bash
clashctl sub add --use "<订阅链接>"  # 添加、校验并启用
clashctl sub list                  # 查看订阅名称
clashctl sub use "<名称>"          # 切换订阅并重启生效
clashctl sub update "<名称>"       # 更新指定订阅
clashctl sub update --all          # 更新全部订阅
clashctl sub del "<名称>"          # 删除订阅
clashctl node list                 # 查看策略组
clashctl node                      # 交互式切换节点
clashctl node delay -h             # 查看测速参数
```

订阅下载后经过解析与校验，必要时使用订阅转换器。更新当前使用的订阅会重新生成运行配置；下载或校验失败不会被当成成功切换。节点管理通过内核控制接口操作，要求内核正在运行。

### 配置、面板与 TUN

```bash
clashctl mixin -e             # 编辑持久化配置，校验后重启
clashctl mixin -r             # 查看合并后的运行配置
clashctl mixin -c             # 查看当前订阅的原始配置
clashctl ui                   # 准备面板，必要时启动内核并显示地址
clashctl secret               # 查看控制接口密钥
clashctl secret '<新密钥>'    # 修改密钥并重启
clashctl tun -h               # 查看 TUN 操作方式
clashctl log -n 50            # 查看最近 50 行日志
```

配置合并以订阅为基础，由 Mixin 覆盖常规字段；规则、节点与策略组支持 `prepend`、`append`，节点和策略组支持按名称 `override`，策略组支持 `inject`。示例见 [resources/mixin.yaml.example](resources/mixin.yaml.example)。无订阅时使用直连配置作为基础。合并结果先经过内核校验，校验失败不替换运行配置；校验通过后若重启失败，会明确报错，需要查看日志处理。

默认代理为 `mixed-port: 37700`、`allow-lan: false`，TUN 默认关闭。控制接口默认是 `0.0.0.0:9090`，与代理监听独立，安装器会在密钥为空时生成随机密钥。仅需本机管理时，可在 Mixin 中将控制接口改为 `127.0.0.1:9090`。控制接口端口冲突时也会选择新端口并持久化；请以当前状态和配置为准。

TUN 通过独立特权 helper 启动内核，需要显式 `sudo` 授权。普通用户 systemd 服务不会在登录时自动启动无权限的 TUN 副本。

### 文件布局

以下路径相对于安装目录 `$CLASHCTL_HOME`：

| 路径 | 用途 |
| --- | --- |
| `.env` | 下载、订阅超时、内核和服务后端等选项 |
| `bin/` | 内核、yq 及按需安装的转换器 |
| `data/mixin.yaml` | 用户配置及持久化的代理端口 |
| `data/config.yaml` | 当前订阅的基础配置 |
| `data/runtime.yaml` | 自动生成的运行配置，不应直接编辑 |
| `data/profiles/`、`data/profiles.yaml` | 订阅文件及管理记录 |
| `data/last-proxy.yaml` | 上一次成功启动记录的监听配置 |
| `data/proxy-startup.tsv` | 本次启动地址和冲突报告 |
| `resources/` | 内核运行资源与 Web 面板 |

开发仓库中的修改需要通过本地安装流程同步到安装目录，才会影响已安装的服务。

## 更新

```bash
# 更新当前 fork 的 clashctl 版本
clashctl update

# 升级代理内核
clashctl upgrade
```

## 卸载

```bash
# 清理当前 Shell 的代理环境变量（卸载脚本无法清理）
clashctl off

# 执行卸载脚本
bash "$CLASHCTL_HOME/uninstall.sh"
```

卸载会删除安装目录及其数据，需要保留的内容请提前备份。`.clashctl-backups/` 中的恢复资料会保留，确认无需回退后可手动清理。

## 文档

- [上游 Wiki](https://github.com/nelvko/clashctl/wiki)（上游说明可能与本 fork 的默认服务和端口不同，以本 README 为准）
- [常见问题](https://github.com/nelvko/clashctl/wiki/FAQ)

## 特别声明

- 编写本项目主要是为了学习和研究 `Shell` 编程，不得将项目内容用于违反适用法律法规及相关规定的活动。
- 本项目保留对本声明进行补充或修改的权利。使用本项目前，请阅读并遵守本声明。
