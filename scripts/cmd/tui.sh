#!/usr/bin/env bash

# The entire screen runs in a child shell: traps and terminal settings never
# replace those belonging to an interactive parent shell.
clashtui() {
    case ${1:-} in
    -h | --help)
        cat <<'HELP'
用法: clashctl tui
打开终端可视化管理：代理开关、内核与自启、订阅和节点、端口与配置。
Language / 语言：可选择 English、简体中文；选择后立即生效并自动保存。
方向键或 j/k 移动，Enter 或数字键选择，q/Esc 返回；输入留空取消。
代理开关在退出 TUI 后同步到当前终端。
HELP
        return 0 ;;
    '') [ "$#" -eq 0 ] || return 1 ;;
    *) _ui_error 'Usage: clashctl tui'; return 1 ;;
    esac
    local result_file action='' rc=0
    result_file=$(mktemp "${TMPDIR:-/tmp}/clashctl-tui.XXXXXX") || return 1
    if _clashctl_in_bash; then
        _tui_session "$result_file" || rc=$?
    else
        _clashctl_run_in_bash _tui_session "$result_file" || rc=$?
    fi
    IFS= read -r action <"$result_file" || true
    command rm -f -- "$result_file"
    # Read a fixed action, never execute Shell code written by the child UI.
    case $action in
    on) set_system_proxy || return 1 ;;
    off) unset_system_proxy ;;
    esac
    return "$rc"
}

_tui_session() (
    local _TUI_PROXY_RESULT=$1
    if [ ! -t 0 ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ]; then
        _ui_error "$(_tui_tr 'The TUI requires an interactive terminal (TERM must not be dumb).')"
        return 1
    fi
    _tui_run
)

_tui_run() {
    local _TUI_STTY _TUI_CHOICE='' _TUI_VALUE='' _TUI_COLOR=false _TUI_LANGUAGE=en
    _tui_load_language
    _TUI_STTY=$(stty -g) || return 1
    _ui_color_enabled 1 && _TUI_COLOR=true
    trap 'trap "" HUP INT TERM; stty "$_TUI_STTY" 2>/dev/null; printf "\033[?25h\033[?1049l"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf '\033[?1049h'
    while _tui_menu 'Overview' 'Kernel & startup' 'Subscriptions' 'Nodes & latency' \
        'Proxy ports' 'Proxy settings' 'Dashboard & secret' 'Logs & diagnostics' 'Terminal proxy' 'Language / 语言'; do
        case $_TUI_CHOICE in
        0) _tui_kernel ;;
        1) _tui_subscriptions ;;
        2) _tui_nodes ;;
        3) _tui_ports ;;
        4) _tui_settings ;;
        5) _tui_dashboard ;;
        6) _tui_diagnostics ;;
        7) _tui_terminal_proxy ;;
        8) _tui_language_menu ;;
        esac
    done
    return 0
}

# Do not render subscription names, URIs or filenames as terminal escapes.
_tui_text() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'; }

_tui_header() {
    local state mode='unknown' port='unknown' startup='unavailable' subscription http_address socks_address terminal_proxy=disabled
    detect_service_manager
    state=$(service_state 2>/dev/null) || state=unknown
    if [ -f "$CLASH_CONFIG_RUNTIME" ]; then
        mode=$("$BIN_YQ" '.mode // "rule"' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || mode=unknown
        port=$("$BIN_YQ" '.mixed-port // 0' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || port=unknown
    fi
    case $service_manager in
    systemd-user)
        startup=$(systemctl --user is-enabled "$CLASHCTL_KERNEL" 2>/dev/null) || startup=${startup:-unknown} ;;
    systemd)
        startup=$(systemctl is-enabled "$CLASHCTL_KERNEL" 2>/dev/null) || startup=${startup:-unknown} ;;
    esac
    [ -z "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ] || terminal_proxy=enabled
    if [ -f "$CLASH_PROFILES_META" ]; then
        subscription=$("$BIN_YQ" -r '.use // ""' "$CLASH_PROFILES_META" 2>/dev/null) || subscription=$(_tui_tr 'Cannot read subscription')
    else subscription=''; fi
    [ -n "$subscription" ] || subscription=$(_tui_tr 'No active subscription')
    printf '\033[H\033[2J'
    if [ "$_TUI_COLOR" = true ]; then printf '\033[1;36m'; fi
    printf '  clashctl daemon  /  %s\n' "$(_tui_tr "$1")"
    [ "$_TUI_COLOR" != true ] || printf '\033[0m'
    _tui_say '  Kernel: %s    Mode: %s    Mixed port: %s' \
        "$(_tui_text "$(_tui_tr "$state")")" "$(_tui_text "$(_tui_tr "$mode")")" "$(_tui_text "$port")"
    _tui_say '  Service: %s    Login startup: %s    Terminal proxy: %s' \
        "$(_tui_text "$service_manager")" "$(_tui_text "$(_tui_tr "$startup")")" "$(_tui_tr "$terminal_proxy")"
    _tui_say '  Subscription: %s' "$(_tui_text "$subscription")"
    if _proxy_addresses "$CLASH_CONFIG_RUNTIME" false 2>/dev/null; then
        _tui_say '  HTTP: %s    SOCKS: %s' "${http_address:-$(_tui_tr Disabled)}" "${socks_address:-$(_tui_tr Disabled)}"
    fi
    printf '\n'
}

_tui_menu() {
    local title=$1 selected=0 key tail i rows rc
    shift
    local -a items=("$@")
    while :; do
        rows=$(tput lines 2>/dev/null) || rows=24
        _tui_header "$title"
        if [ "$rows" -lt "$((${#items[@]} + 12))" ]; then
            _tui_say '  Enlarge the terminal to at least %s rows.' "$((${#items[@]} + 12))"
        else
            for ((i=0; i<${#items[@]}; i++)); do
                if [ "$i" -eq "$selected" ]; then
                    [ "$_TUI_COLOR" != true ] || printf '\033[1;30;46m'
                    printf '  > %d  %s' "$((i + 1))" "$(_tui_tr "${items[i]}")"
                    [ "$_TUI_COLOR" != true ] || printf '\033[0m'
                    printf '\n'
                else
                    printf '    %d  %s\n' "$((i + 1))" "$(_tui_tr "${items[i]}")"
                fi
            done
        fi
        printf '\n'; _tui_say '  Up/Down or j/k: move   Enter: select   q/Esc: back'
        _tui_say '  Number keys select immediately.'; printf '\033[?25l'
        rc=0
        IFS= read -rsn1 -t 2 key || rc=$?
        # Timeouts refresh externally changed service/configuration state.
        if [ "$rc" -gt 128 ]; then continue; fi
        [ "$rc" -eq 0 ] || return 1
        case $key in
        $'\033')
            tail=''
            if IFS= read -rsn1 -t 0.1 tail && [ "$tail" = '[' ]; then
                IFS= read -rsn1 -t 0.1 tail || tail=''
                case $tail in A) key=k ;; B) key=j ;; *) continue ;; esac
            else return 1; fi ;;
        esac
        case $key in
        k) selected=$(((selected + ${#items[@]} - 1) % ${#items[@]})) ;;
        j) selected=$(((selected + 1) % ${#items[@]})) ;;
        '') _TUI_CHOICE=$selected; return 0 ;;
        [1-9])
            if [ "$key" -le "${#items[@]}" ]; then _TUI_CHOICE=$((key - 1)); return 0; fi ;;
        q | Q) return 1 ;;
        esac
    done
}

_tui_pause() {
    local key
    printf '\n%s' "$(_tui_tr 'Press any key to return...')"
    IFS= read -rsn1 key || true
}

_tui_action() {
    local rc=0
    _tui_header 'Action'
    printf '\033[?25h'
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then printf '\n'; _tui_say 'Operation failed (exit %d). Review the output above.' "$rc"; fi
    _tui_pause
    return 0
}

_tui_input() {
    local prompt=$1 secret=${2:-false}
    printf '\033[?25h\n%s (%s): ' "$(_tui_tr "$prompt")" "$(_tui_tr 'empty cancels')"
    _TUI_VALUE=''
    if [ "$secret" = true ]; then IFS= read -rs _TUI_VALUE || return 1; printf '\n'
    else IFS= read -r _TUI_VALUE || return 1; fi
    [ -n "$_TUI_VALUE" ]
}

_tui_confirm() {
    local answer
    printf '\033[?25h\n%s [y/N]: ' "$(_tui_tr "$1")"
    IFS= read -r answer || return 1
    case $answer in y | Y) return 0 ;; *) return 1 ;; esac
}

_tui_restart() { clashstop && clashstart; }

_tui_kernel() {
    while _tui_menu 'Kernel & startup' 'Start kernel' 'Stop kernel' 'Restart kernel' \
        'Enable login startup' 'Disable login startup' 'Detailed status'; do
        case $_TUI_CHOICE in
        0) _tui_action clashstart ;;
        1) _tui_confirm 'Stop the kernel for all connected clients?' && _tui_action clashstop ;;
        2) _tui_action _tui_restart ;;
        3) _tui_action _tui_startup enable ;;
        4) _tui_action _tui_startup disable ;;
        5) _tui_action clashstatus --verbose ;;
        esac
    done
}

_tui_startup() {
    detect_service_manager
    case $service_manager in
    systemd-user | systemd | openrc | sysvinit | runit) ;;
    *) _ui_error "$(_tui_tr 'This service backend does not support automatic startup.')"; return 1 ;;
    esac
    if [ "$1" = enable ]; then service_enable; else service_disable; fi || return 1
    if [ "$1" = enable ]; then _tui_say 'Login startup enabled.'; else _tui_say 'Login startup disabled.'; fi
    _tui_say 'Starting the kernel through clashctl enables automatic startup again.'
}

_tui_terminal_proxy() {
    while _tui_menu 'Terminal proxy' 'Enable proxy (start kernel if needed)' \
        'Disable proxy (keep kernel running)' 'Disable proxy and stop kernel'; do
        case $_TUI_CHOICE in
        0) _tui_action _tui_proxy on ;;
        1) _tui_action _tui_proxy off ;;
        2) _tui_action _tui_proxy stop ;;
        esac
    done
}

_tui_proxy() {
    local action=$1 rc=0
    case $action in
    on) clashon || return 1 ;;
    off) clashoff || return 1 ;;
    stop) clashoff --stop || rc=$?; action=off ;;
    *) return 1 ;;
    esac
    printf '%s\n' "$action" >"$_TUI_PROXY_RESULT" || return 1
    _tui_say 'The proxy selection will apply to this terminal when you exit the TUI.'
    return "$rc"
}

# Fish uses the existing escaping routine to export values into its own process.
_tui_proxy_env_fish() { set_system_proxy && _dump_proxy_env_fish; }

_tui_subscription_node() { clashstart && clashnode use "$@"; }

_tui_nodes() {
    while _tui_menu 'Nodes & latency' 'List policy groups' 'Switch node' 'Switch node with latency' 'Test group latency'; do
        case $_TUI_CHOICE in
        0) _tui_action clashnode list ;;
        1) _tui_action clashnode use ;;
        2) _tui_action clashnode use --delay ;;
        3) _tui_action clashnode delay ;;
        esac
    done
}

_tui_subscriptions() {
    while _tui_menu 'Subscriptions' 'List subscriptions' 'Add & activate subscription' \
        'Switch subscription' 'Update all subscriptions' 'Delete subscription' 'Subscription log' \
        'Select node for current subscription' 'Select node with latency'; do
        case $_TUI_CHOICE in
        0) _tui_action clashsub list ;;
        1) _tui_input 'Subscription URL' true && _tui_action clashsub add --use "$_TUI_VALUE" ;;
        2) _tui_action clashsub use ;;
        3) _tui_action clashsub update --all ;;
        4) _tui_action clashsub del ;;
        5) _tui_action clashsub log ;;
        6) _tui_action _tui_subscription_node ;;
        7) _tui_action _tui_subscription_node --delay ;;
        esac
    done
}

_tui_ports() {
    local key label value
    while _tui_menu 'Proxy ports' 'Mixed HTTP + SOCKS port' 'Dedicated HTTP port' 'Dedicated SOCKS port' 'Current proxy addresses'; do
        case $_TUI_CHOICE in
        0) key=mixed-port; label='Mixed port (1-65535)' ;;
        1) key=port; label='HTTP port (0 disables this listener)' ;;
        2) key=socks-port; label='SOCKS port (0 disables this listener)' ;;
        3) _tui_action clashstatus; continue ;;
        esac
        value=$("$BIN_YQ" ".\"$key\" // 0" "$CLASH_CONFIG_MIXIN" 2>/dev/null) || value=unknown
        printf '\n'; _tui_say 'Configured %s: %s' "$key" "$(_tui_text "$value")"
        _tui_input "$label" || continue
        _tui_action _tui_set "$key" "$_TUI_VALUE"
    done
}

# Update a candidate file, validate the complete runtime, then atomically persist.
# A stopped kernel stays stopped. Restart errors retain the validated selection.
_tui_set() {
    local key=$1 value=$2 expression state
    case $key in
    mixed-port | port | socks-port)
        [[ $value =~ ^[0-9]+$ ]] && [ "${#value}" -le 5 ] && ((10#$value <= 65535)) || {
            _ui_error "$(_tui_tr 'Port must be an integer between 0 and 65535.')"; return 1;
        }
        value=$((10#$value))
        [ "$key" != mixed-port ] || [ "$value" -gt 0 ] || {
            _ui_error "$(_tui_tr 'The mixed proxy port must be between 1 and 65535.')"; return 1;
        }
        expression=".\"$key\" = env(TUI_SETTING)" ;;
    mode)
        case $value in rule | global | direct) ;; *) return 1 ;; esac
        expression='.mode = strenv(TUI_SETTING)' ;;
    allow-lan)
        case $value in true | false) ;; *) return 1 ;; esac
        expression='.allow-lan = env(TUI_SETTING)' ;;
    external-controller)
        [[ $value == *:* ]] && _proxy_port "${value##*:}" >/dev/null &&
            _proxy_local_host "${value%:*}" >/dev/null || {
                _ui_error "$(_tui_tr 'Use a controller address such as 127.0.0.1:9090 or [::1]:9090.')"; return 1;
            }
        expression='.external-controller = strenv(TUI_SETTING)' ;;
    secret) expression='.secret = strenv(TUI_SETTING)' ;;
    *) return 1 ;;
    esac
    detect_service_manager
    state=$(service_state) || { _ui_error "$(_tui_tr 'Cannot read kernel state; no settings changed.')"; return 1; }
    case $state in running | stopped | failed) ;; *) _ui_error "$(_tui_tr 'Wait for the kernel to finish changing state.')"; return 1 ;; esac
    _tui_commit_setting "$expression" "$value" || return 1
    if [ "$state" = running ]; then
        _merge_config_restart || {
            _ui_error "$(_tui_tr 'Settings saved, but the kernel could not restart. Check the logs.')"; return 1;
        }
        _tui_say 'Settings saved and kernel restarted.'
    else
        _tui_say 'Settings saved. They will apply on the next kernel start.'
    fi
    case $key in mixed-port | port | socks-port)
        _tui_say 'Run clashctl on in each terminal to refresh its proxy environment.' ;;
    esac
}

_tui_commit_setting() (
    local expression=$1 value=$2 candidate='' backup='' lock_dir="$CLASH_DATA_DIR/startup.lock.d"
    local lock_pid='' lock_token=''
    trap 'trap "" HUP INT TERM; command rm -f -- "$candidate" "$backup"; _directory_lock_release "$lock_dir" "${lock_pid:-${_DIRECTORY_LOCK_PID:-}}" "${lock_token:-${_DIRECTORY_LOCK_TOKEN:-}}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    _directory_lock_acquire "$lock_dir" 10 || return 1
    lock_pid=$_DIRECTORY_LOCK_PID lock_token=$_DIRECTORY_LOCK_TOKEN
    candidate=$(mktemp "${CLASH_CONFIG_MIXIN}.tui.XXXXXX") || return 1
    backup=$(mktemp "${CLASH_CONFIG_RUNTIME}.tui.XXXXXX") || return 1
    cp -- "$CLASH_CONFIG_MIXIN" "$candidate" || return 1
    cp -- "$CLASH_CONFIG_RUNTIME" "$backup" || return 1
    TUI_SETTING="$value" "$BIN_YQ" -i "$expression" "$candidate" || return 1
    CLASH_CONFIG_MIXIN="$candidate" _merge_config || return 1
    if ! command mv -f -- "$candidate" "$CLASH_CONFIG_MIXIN"; then
        cp -- "$backup" "$CLASH_CONFIG_RUNTIME"
        return 1
    fi
)

_tui_settings() {
    while _tui_menu 'Proxy settings' 'Mode: Rule' 'Mode: Global' 'Mode: Direct' \
        'Allow LAN access' 'Restrict proxy to this computer' 'Enable TUN (sudo required)' 'Disable TUN' 'Edit full Mixin'; do
        case $_TUI_CHOICE in
        0) _tui_action _tui_set mode rule ;;
        1) _tui_action _tui_set mode global ;;
        2) _tui_action _tui_set mode direct ;;
        3) _tui_confirm 'Allow remote clients? Configure authentication and network access first.' && _tui_action _tui_set allow-lan true ;;
        4) _tui_action _tui_set allow-lan false ;;
        5) _tui_confirm 'Enable TUN with sudo? This changes network routing.' && _tui_action clashtun on ;;
        6) _tui_action clashtun off ;;
        7) _tui_action clashmixin -e ;;
        esac
    done
}

_tui_dashboard() {
    while _tui_menu 'Dashboard & secret' 'Show dashboard addresses' 'Set controller address' 'Change controller secret'; do
        case $_TUI_CHOICE in
        0) _tui_action clashui ;;
        1) _tui_input 'Controller address (for example 127.0.0.1:9090)' && _tui_action _tui_set external-controller "$_TUI_VALUE" ;;
        2) _tui_input 'New controller secret' true && _tui_action _tui_set secret "$_TUI_VALUE" ;;
        esac
    done
}

_tui_diagnostics() {
    while _tui_menu 'Logs & diagnostics' 'Recent kernel logs (100 lines)' 'Detailed status' 'Versions' 'Show runtime configuration'; do
        case $_TUI_CHOICE in
        0) _tui_action clashlog -n 100 ;;
        1) _tui_action clashstatus --verbose ;;
        2) _tui_action clashversion ;;
        3) _tui_action clashmixin -r ;;
        esac
    done
}

_tui_language_menu() {
    if _tui_menu 'Language / 语言' 'English' '简体中文'; then
        case $_TUI_CHOICE in
        0) _tui_set_language en ;;
        1) _tui_set_language zh-CN ;;
        esac
    fi
}
