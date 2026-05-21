#!/usr/bin/env bash
# Manage Intel CPU cores: show online P/E cores and toggle them.
# Works on hybrid Intel CPUs (12th gen and newer: P-cores + E-cores)
# and falls back to a single "all cores" group on non-hybrid Intel CPUs.

set -euo pipefail

P_CPUS_FILE=/sys/devices/cpu_core/cpus
E_CPUS_FILE=/sys/devices/cpu_atom/cpus
ALL_CPUS_FILE=/sys/devices/system/cpu/possible
ONLINE_FILE=/sys/devices/system/cpu/online
OFFLINE_FILE=/sys/devices/system/cpu/offline
SMT_CTL=/sys/devices/system/cpu/smt/control

HYBRID=0
if [[ -r $P_CPUS_FILE && -r $E_CPUS_FILE ]]; then
    HYBRID=1
fi

expand_range() {
    # Expand "0-3,5,7-9" -> "0 1 2 3 5 7 8 9". Empty input -> nothing.
    local part a b i
    local -a parts out=()
    [[ -z ${1:-} ]] && return 0
    IFS=',' read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        if [[ $part == *-* ]]; then
            a=${part%-*}; b=${part#*-}
            for ((i=a; i<=b; i++)); do out+=("$i"); done
        else
            out+=("$part")
        fi
    done
    printf '%s\n' "${out[@]}"
}

# Snapshot which CPUs were online before we touch anything.
mapfile -t PREV_ONLINE < <(expand_range "$(cat $ONLINE_FILE)")
PREV_SMT=$(cat $SMT_CTL 2>/dev/null || echo unknown)

# Cache sudo credentials up front so subsequent writes don't prompt mid-script.
echo "This script needs root to toggle CPUs. You may be asked for your sudo password."
if ! sudo -v; then
    echo "ERROR: cannot obtain sudo privileges." >&2
    exit 1
fi

sudo_write() {
    # sudo_write <value> <sysfs-file>  -> returns 0 if file content equals value afterwards.
    local val=$1 file=$2
    if ! echo "$val" | sudo tee "$file" >/dev/null; then
        echo "  write failed: $file <- $val" >&2
        return 1
    fi
    local got
    got=$(cat "$file")
    if [[ $got != "$val" ]]; then
        echo "  kernel rejected: $file is '$got', wanted '$val'" >&2
        return 1
    fi
    return 0
}

# Bring everything online to read the P/E layout, then restore.
detect_layout() {
    local off cpu f
    if [[ -e $SMT_CTL ]] && [[ $PREV_SMT != on && $PREV_SMT != notsupported && $PREV_SMT != unknown ]]; then
        sudo_write on $SMT_CTL || true
    fi
    off=$(cat $OFFLINE_FILE)
    if [[ -n $off ]]; then
        for cpu in $(expand_range "$off"); do
            f=/sys/devices/system/cpu/cpu$cpu/online
            [[ -e $f ]] && sudo_write 1 "$f" || true
        done
    fi
}

# Restore the pre-script online/offline state (and SMT) for every CPU.
restore_state() {
    local cpu f want
    declare -A in_prev=()
    for cpu in "${PREV_ONLINE[@]}"; do in_prev[$cpu]=1; done
    for cpu in $(expand_range "$(cat $ALL_CPUS_FILE)"); do
        f=/sys/devices/system/cpu/cpu$cpu/online
        [[ -e $f ]] || continue
        want=0
        [[ ${in_prev[$cpu]:-0} == 1 ]] && want=1
        [[ $(cat "$f") == "$want" ]] && continue
        sudo_write "$want" "$f" || true
    done
    if [[ -e $SMT_CTL && $PREV_SMT != unknown && $PREV_SMT != notsupported ]]; then
        local now
        now=$(cat $SMT_CTL)
        if [[ $now != "$PREV_SMT" ]]; then
            sudo_write "$PREV_SMT" $SMT_CTL || true
        fi
    fi
}

detect_layout

if [[ $HYBRID -eq 1 ]]; then
    mapfile -t P_CORES < <(expand_range "$(cat $P_CPUS_FILE)")
    mapfile -t E_CORES < <(expand_range "$(cat $E_CPUS_FILE)")
    expected=$(expand_range "$(cat $ALL_CPUS_FILE)" | wc -l)
    got=$(( ${#P_CORES[@]} + ${#E_CORES[@]} ))
    if (( got != expected )); then
        echo "ERROR: incomplete layout detected — saw $got of $expected CPUs." >&2
        echo "  cpu_core/cpus = $(cat $P_CPUS_FILE)" >&2
        echo "  cpu_atom/cpus = $(cat $E_CPUS_FILE)" >&2
        echo "  offline       = $(cat $OFFLINE_FILE)" >&2
        echo "Some CPUs could not be brought online to detect their type." >&2
        exit 1
    fi
else
    mapfile -t ALL_CORES < <(expand_range "$(cat $ALL_CPUS_FILE)")
fi

restore_state

is_online() {
    local cpu=$1
    # cpu0 usually has no "online" file — it is always online.
    local f=/sys/devices/system/cpu/cpu$cpu/online
    [[ ! -e $f ]] && { echo 1; return; }
    cat "$f"
}

count_online() {
    local total=0 cpu
    for cpu in "$@"; do
        [[ $(is_online "$cpu") == 1 ]] && ((total++)) || true
    done
    echo "$total"
}

list_online() {
    local cpu out=()
    for cpu in "$@"; do
        [[ $(is_online "$cpu") == 1 ]] && out+=("$cpu")
    done
    echo "${out[*]:-none}"
}

set_online() {
    local state=$1; shift
    local cpu f
    # Enabling cores? Make sure SMT is on first so sibling threads are toggleable.
    if [[ $state == 1 && -e $SMT_CTL ]]; then
        local v
        v=$(cat $SMT_CTL)
        if [[ $v != on && $v != notsupported ]]; then
            sudo_write on $SMT_CTL || true
        fi
    fi
    for cpu in "$@"; do
        f=/sys/devices/system/cpu/cpu$cpu/online
        if [[ ! -e $f ]]; then
            # cpu0 is hardwired online on most kernels — silently skip it.
            [[ $cpu != 0 ]] && echo "  cpu$cpu: cannot change state (no $f), skipping" >&2
            continue
        fi
        if [[ $(cat "$f") == "$state" ]]; then
            continue
        fi
        sudo_write "$state" "$f" || true
    done
}

show_status() {
    echo "---------------------------------------------"
    if [[ $HYBRID -eq 1 ]]; then
        local p_on e_on
        p_on=$(count_online "${P_CORES[@]}")
        e_on=$(count_online "${E_CORES[@]}")
        echo "P-cores (performance): $p_on / ${#P_CORES[@]} online"
        echo "E-cores (efficient):   $e_on / ${#E_CORES[@]} online"
    else
        local on
        on=$(count_online "${ALL_CORES[@]}")
        echo "Non-hybrid Intel CPU detected."
        echo "CPUs: $on / ${#ALL_CORES[@]} online"
    fi
    echo "---------------------------------------------"
}

apply_count() {
    # apply_count <desired-count> <cpu...>
    # Enable the first N CPUs from the list, disable the rest.
    local want=$1; shift
    local -a cpus=("$@")
    local total=${#cpus[@]}
    if (( want < 0 )); then want=0; fi
    if (( want > total )); then want=$total; fi
    local i cpu
    local -a enable=() disable=()
    for ((i=0; i<total; i++)); do
        cpu=${cpus[$i]}
        if (( i < want )); then enable+=("$cpu"); else disable+=("$cpu"); fi
    done
    if (( ${#enable[@]}  > 0 )); then set_online 1 "${enable[@]}"; fi
    if (( ${#disable[@]} > 0 )); then set_online 0 "${disable[@]}"; fi
    return 0
}

ask_count() {
    # ask_count <label> <max>  -> echoes chosen number, or returns 1 on skip.
    # All prompts/errors go to stderr so command substitution captures only the number.
    local label=$1 max=$2 ans
    while true; do
        read -rp "How many $label to keep online (1-$max, empty to skip): " ans >&2
        if [[ -z $ans ]]; then
            return 1
        fi
        if ! [[ $ans =~ ^[0-9]+$ ]]; then
            echo "  '$ans' is not a number, try again." >&2
            continue
        fi
        if (( ans < 1 || ans > max )); then
            echo "  $ans out of range (1-$max), try again." >&2
            continue
        fi
        echo "$ans"
        return 0
    done
}

show_status
P_WANT=""
E_WANT=""
ALL_WANT=""
if [[ $HYBRID -eq 1 ]]; then
    if n=$(ask_count "P-cores" "${#P_CORES[@]}"); then P_WANT=$n; fi
    if n=$(ask_count "E-cores" "${#E_CORES[@]}"); then E_WANT=$n; fi
    [[ -n $P_WANT ]] && apply_count "$P_WANT" "${P_CORES[@]}"
    [[ -n $E_WANT ]] && apply_count "$E_WANT" "${E_CORES[@]}"
else
    if n=$(ask_count "CPUs" "${#ALL_CORES[@]}"); then ALL_WANT=$n; fi
    [[ -n $ALL_WANT ]] && apply_count "$ALL_WANT" "${ALL_CORES[@]}"
fi
echo
echo "Done. New state:"
show_status
