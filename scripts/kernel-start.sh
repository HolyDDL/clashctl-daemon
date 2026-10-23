#!/usr/bin/env bash
# systemd pre/post hooks also cover login and automatic kernel restarts.
set -e
export CLASHCTL_HOME=${2:?Missing installation directory}
export CLASHCTL_SRC=$CLASHCTL_HOME
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
case ${1:-} in
prepare)
    # The kernel is not running during ExecStartPre.
    service_is_active() { return 1; }
    _prepare_kernel_start
    _show_proxy_startup_report
    ;;
remember) _remember_proxy_start ;;
*) printf 'Usage: kernel-start.sh prepare|remember HOME\n' >&2; exit 2 ;;
esac
