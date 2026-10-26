#!/bin/bash
#
# autosuspend.sh
#
# Powers off (or suspends/hibernates) the machine when it has been idle for
# a configurable time. The machine is considered busy if ANY of these is true:
#   - a user is active on a console/tty (input within USER_IDLE_TIME seconds)
#   - network traffic on the monitored interface is above the threshold
#   - the lock file has been touched within USER_IDLE_TIME seconds
#   - (optional) the 1-minute load average is above LOAD_THRESHOLD
#
# Usage:
#   autosuspend.sh [countdown_seconds [timestep_seconds]]
#
#   countdown_seconds  overrides BOTH the day and night countdown
#   timestep_seconds   polling interval (default 30)
#
# Everything can also be set through environment variables, e.g.:
#   NETWORK_INTERFACE=enp3s0 ACTION=hibernate DRY_RUN=1 ./autosuspend.sh
#
# Control files (in STATE_DIR):
#   autosuspend.lock  touch it to postpone shutdown
#   autosuspend.stop  touch it to make the script exit
#
# Original author : Maxime Morel <maxime.morel69@gmail.com>
#
# Changelog
# 2026 revision:
#   Action is now explicit and configurable (poweroff|hibernate|suspend).
#   CLI arguments are honoured again.
#   Network interface auto-detected, matched exactly, first sample primed.
#   Fail safe: if the interface or a check cannot be read, assume "busy".
#   Idle detection uses stat instead of parsing ls output.
#   State files moved from /tmp to /run (or a per-user dir when not root).
#   Single-instance protection with flock.
#   Stop file checked at the top of the loop and during sleep.
#   Optional load-average check and DRY_RUN mode.
# 2017/02/03: Separate threshold for day and night.
# 2016/09/29: Human readable remaining time, parameters, stop file.
# 2016/09/09: Date in log, network traffic fix.
# 2016/09/07: Systemd detection, lock file, KiB unit.
# 2015/10/02: Poweroff if kernel updated; prefer systemctl.
# 2014/01/08: Use /proc/net/dev instead of dstat; tty idle via stat.
# 2014/01/06: Initial version.

set -u

# ---------------------------------------------------------------- settings --

# What to do when idle: poweroff | hibernate | suspend
ACTION=${ACTION:-poweroff}

# Day time window [DAY_START, NIGHT_START) in hours (0-23)
DAY_START=${DAY_START:-7}
NIGHT_START=${NIGHT_START:-23}

# Idle countdown in seconds
COUNTDOWN_DAY=${COUNTDOWN_DAY:-14400}
COUNTDOWN_NIGHT=${COUNTDOWN_NIGHT:-7200}

# Network threshold (KiB/s, rx+tx) above which the machine is "busy"
NET_THRESHOLD_DAY=${NET_THRESHOLD_DAY:-100}
NET_THRESHOLD_NIGHT=${NET_THRESHOLD_NIGHT:-2000}

# Network interface to monitor (auto-detected from default route if empty)
NETWORK_INTERFACE=${NETWORK_INTERFACE:-}

# Seconds of tty/lock-file inactivity before they stop counting as "active"
USER_IDLE_TIME=${USER_IDLE_TIME:-60}

# Optional: 1-minute load average above which the machine is busy
# (e.g. LOAD_THRESHOLD=0.5). Empty = disabled.
LOAD_THRESHOLD=${LOAD_THRESHOLD:-}

# Polling interval in seconds
TIMESTEP=${TIMESTEP:-30}

# 1 = only log what would happen, never shut down
DRY_RUN=${DRY_RUN:-0}

# Where the lock/stop/pid files live
if [[ $EUID -eq 0 ]]; then
    STATE_DIR=${STATE_DIR:-/run/autosuspend}
else
    STATE_DIR=${STATE_DIR:-/tmp/autosuspend-$EUID}
fi

# ---------------------------------------------------------- CLI arguments --

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

if [[ $# -ge 1 ]]; then
    is_uint "$1" || { echo "countdown must be a positive integer" >&2; exit 2; }
    COUNTDOWN_DAY=$1
    COUNTDOWN_NIGHT=$1
fi
if [[ $# -ge 2 ]]; then
    is_uint "$2" || { echo "timestep must be a positive integer" >&2; exit 2; }
    TIMESTEP=$2
fi
(( TIMESTEP > 0 )) || { echo "timestep must be > 0" >&2; exit 2; }

# ------------------------------------------------------------------ setup --

# Sticky, world-writable dir: any user may touch the lock/stop files, but
# cannot tamper with files owned by others (no /tmp symlink games).
mkdir -p "$STATE_DIR" || { echo "cannot create $STATE_DIR" >&2; exit 1; }
chmod 1777 "$STATE_DIR" 2>/dev/null

LOCK_FILE="$STATE_DIR/autosuspend.lock"
STOP_FILE="$STATE_DIR/autosuspend.stop"
PID_FILE="$STATE_DIR/autosuspend.pid"

touch "$LOCK_FILE" && chmod 666 "$LOCK_FILE" 2>/dev/null

# Single instance
exec 9>"$PID_FILE"
if ! flock -n 9; then
    echo "autosuspend is already running" >&2
    exit 1
fi
echo $$ >&9

HAS_SYSTEMD=0
command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=1

if [[ -z $NETWORK_INTERFACE ]]; then
    NETWORK_INTERFACE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    NETWORK_INTERFACE=${NETWORK_INTERFACE:-eth0}
fi

# ---------------------------------------------------------------- helpers --

log() { echo "$(date '+%F %T') $*"; }

format_time() {
    local t=$1
    local h=$(( t / 3600 ))
    local m=$(( (t % 3600) / 60 ))
    local s=$(( t % 60 ))
    local out=""
    (( h > 0 )) && out+="${h}h "
    (( h > 0 || m > 0 )) && out+="${m}m "
    out+="${s}s"
    echo "$out"
}

# Total rx+tx bytes of the monitored interface (exact match). Fails if absent.
read_net_bytes() {
    awk -v i="$NETWORK_INTERFACE" '
        { sub(/:/, " ") }
        $1 == i { print $2 + $10; found = 1 }
        END { exit !found }
    ' /proc/net/dev
}

# ----------------------------------------------------------------- checks --
# Each check returns 0 when it considers the machine BUSY, 1 when idle.

OLD_NET_TOTAL=""

check_user_active() {
    local busy=1 now tty last idle
    now=$(date +%s)
    while read -r tty; do
        [[ -n $tty && -e /dev/$tty ]] || continue
        last=$(stat -c %X "/dev/$tty" 2>/dev/null) || continue
        idle=$(( now - last ))
        if (( idle < USER_IDLE_TIME )); then
            log "User active on $tty (last input $(format_time "$idle") ago)"
            busy=0
        fi
    done < <(who | awk '{print $2}')
    return $busy
}

check_network_used() {
    local total rate
    if ! total=$(read_net_bytes); then
        log "Cannot read interface '$NETWORK_INTERFACE', assuming network busy"
        return 0
    fi

    # First sample only primes the counter
    if [[ -z $OLD_NET_TOTAL ]]; then
        OLD_NET_TOTAL=$total
        return 1
    fi

    local diff=$(( total - OLD_NET_TOTAL ))
    OLD_NET_TOTAL=$total
    (( diff < 0 )) && diff=0            # counter reset or wrap

    rate=$(( diff / TIMESTEP / 1024 ))  # KiB/s
    if (( rate > NET_THRESHOLD )); then
        log "Network active: ${rate} KiB/s (limit ${NET_THRESHOLD} KiB/s)"
        return 0
    fi
    return 1
}

check_lock_file() {
    [[ -f $LOCK_FILE ]] || return 1
    local age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
    if (( age < USER_IDLE_TIME )); then
        log "Lock file touched $(format_time "$age") ago"
        return 0
    fi
    return 1
}

check_load() {
    [[ -n $LOAD_THRESHOLD ]] || return 1
    local load
    read -r load _ < /proc/loadavg || return 1
    if awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN { exit !(l > t) }'; then
        log "Load average high: $load (limit $LOAD_THRESHOLD)"
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------- action --

do_action() {
    local action=$ACTION

    # A new kernel without matching modules may not resume properly
    if [[ ! -d /lib/modules/$(uname -r) && $action != poweroff ]]; then
        log "Kernel has been updated, powering off instead of $action"
        action=poweroff
    fi

    log "Going to $action"
    if (( DRY_RUN )); then
        log "DRY_RUN set, doing nothing"
        return
    fi

    sync
    if (( HAS_SYSTEMD )); then
        systemctl "$action"
    else
        case $action in
            poweroff)  shutdown -h now ;;
            hibernate) pm-hibernate ;;
            suspend)   pm-suspend ;;
        esac
    fi
}

# ------------------------------------------------------------- main loop --

main_loop() {
    local idle=0 hour countdown busy

    log "Started: interface=$NETWORK_INTERFACE action=$ACTION timestep=${TIMESTEP}s dry_run=$DRY_RUN"

    while :; do
        if [[ -f $STOP_FILE ]]; then
            rm -f "$STOP_FILE"
            log "Stop file found, exiting"
            return
        fi

        hour=$(date +%-H)
        if (( hour >= DAY_START && hour < NIGHT_START )); then
            countdown=$COUNTDOWN_DAY
            NET_THRESHOLD=$NET_THRESHOLD_DAY
        else
            countdown=$COUNTDOWN_NIGHT
            NET_THRESHOLD=$NET_THRESHOLD_NIGHT
        fi

        # Run every check (no short-circuit) so each one logs and updates state
        busy=0
        check_user_active  && busy=1
        check_network_used && busy=1
        check_lock_file    && busy=1
        check_load         && busy=1

        if (( busy )); then
            idle=0
            log "Busy, countdown reset to $(format_time "$countdown")"
        else
            idle=$(( idle + TIMESTEP ))
            log "Idle, $(format_time $(( countdown > idle ? countdown - idle : 0 ))) before $ACTION"
        fi

        if (( idle >= countdown )); then
            do_action
            idle=0
        fi

        # Sleep in 1s slices so the stop file is honoured quickly
        local i
        for (( i = 0; i < TIMESTEP; i++ )); do
            [[ -f $STOP_FILE ]] && break
            sleep 1
        done
    done
}

main_loop
