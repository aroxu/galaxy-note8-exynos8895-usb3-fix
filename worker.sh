#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/usb3fix.log"
LOCK="$MODDIR/.running"

DWC3="/sys/devices/platform/10c00000.usb/10c00000.dwc3"
CCIC="/sys/class/sec/ccic"

#
# Do not trust transient SuperSpeed enumeration during early boot.
#
# On the affected Note 8, the SuperSpeed hub may briefly appear during
# boot and later fall back to USB 2.0. Therefore the actual RTL8153
# negotiated speed is checked after the system has settled.
#
SETTLE_DELAY=60

#
# Keep the DWC3 host disabled long enough for the USB DRD PHY and xHCI
# controller to completely shut down.
#
HOST_OFF_DELAY=10

#
# Maximum time to wait for RTL8153 to come back at SuperSpeed after
# restarting the DWC3 host.
#
RECOVER_TIMEOUT=45


log() {
    TS="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"

    [ -n "$TS" ] || TS="$(date 2>/dev/null)"

    echo "$TS $*" >> "$LOG"
}


#
# Check whether a USB device with a specific VID/PID exists.
#
# This intentionally uses sysfs instead of lsusb because lsusb may not
# be available in Magisk's boot-time environment.
#
has_usb() {
    want_vid="$1"
    want_pid="$2"

    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        [ -f "$d/idProduct" ] || continue

        vid="$(cat "$d/idVendor" 2>/dev/null)"
        pid="$(cat "$d/idProduct" 2>/dev/null)"

        [ "$vid" = "$want_vid" ] &&
        [ "$pid" = "$want_pid" ] &&
        return 0
    done

    return 1
}


#
# Return the negotiated USB bus speed of the Realtek RTL8153.
#
# Expected values:
#
#   480   -> USB 2.0 High-Speed (broken/fallback state)
#   5000  -> USB 3.x SuperSpeed (healthy state)
#
rtl8153_speed() {
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        [ -f "$d/idProduct" ] || continue

        vid="$(cat "$d/idVendor" 2>/dev/null)"
        pid="$(cat "$d/idProduct" 2>/dev/null)"

        if [ "$vid" = "0bda" ] &&
           [ "$pid" = "8153" ]; then

            cat "$d/speed" 2>/dev/null
            return 0
        fi
    done

    return 1
}


get_state() {
    cat "$DWC3/state" 2>/dev/null
}


get_id() {
    cat "$DWC3/id" 2>/dev/null
}


get_ccic_ids() {
    cat "$CCIC/usbpd_ids" 2>/dev/null
}


#
# Prevent multiple workers from running simultaneously.
#
if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null' EXIT


#
# Prevent the log from growing forever.
#
if [ -f "$LOG" ]; then
    size="$(wc -c < "$LOG" 2>/dev/null)"

    case "$size" in
        ''|*[!0-9]*)
            ;;
        *)
            if [ "$size" -gt 131072 ]; then
                tail -c 65536 "$LOG" > "$LOG.tmp" 2>/dev/null &&
                    mv "$LOG.tmp" "$LOG"
            fi
            ;;
    esac
fi


log "v3.1 start; waiting ${SETTLE_DELAY}s for boot/USB to settle"

sleep "$SETTLE_DELAY"


#
# DWC3 sysfs interface must exist.
#
if [ ! -e "$DWC3/id" ] ||
   [ ! -e "$DWC3/state" ]; then

    log "DWC3 sysfs missing; no action"
    exit 0
fi


#
# 2109:2822 is the USB 2.0 companion hub of the tested VIA USB-C dock.
#
# If this device is absent, the target dock is not connected and the
# module must not touch the USB controller.
#
if ! has_usb 2109 2822; then
    log "target VIA USB2 hub 2109:2822 not present; no action"
    exit 0
fi


speed="$(rtl8153_speed)"

[ -n "$speed" ] || speed="missing"


#
# The actual RTL8153 negotiated speed is used as the final health check.
#
# Do NOT use only the presence of the VIA SuperSpeed hub (2109:0822)
# because it may transiently appear during early boot.
#
if [ "$speed" = "5000" ]; then
    log "healthy: RTL8153 speed=5000; no action"
    exit 0
fi


state="$(get_state)"
id="$(get_id)"
ccic_ids="$(get_ccic_ids)"

log "degraded: RTL8153 speed=$speed state=$state id=$id ccic_ids=$ccic_ids"


#
# Safety checks.
#
# The recovery is intentionally conservative because writing to the
# DWC3 OTG id sysfs node changes the controller's USB role.
#

if [ "$state" != "a_host" ]; then
    log "not in a_host; abort"
    exit 0
fi


if [ "$id" != "0" ]; then
    log "DWC3 id is not 0; abort"
    exit 0
fi


#
# USB-PD identity reported by the tested VIA dock.
#
if [ "$ccic_ids" != "2109:0102" ]; then
    log "unexpected CCIC accessory id ($ccic_ids); abort"
    exit 0
fi


#
# Re-check immediately before touching the controller.
#
if ! has_usb 2109 2822; then
    log "dock disappeared before recovery; abort"
    exit 0
fi


#
# Force DWC3 out of host mode.
#
# This causes the kernel to tear down xHCI and power down the USB DRD PHY.
#
log "recovery: host OFF (id=1)"

if ! echo 1 > "$DWC3/id"; then
    log "failed to write id=1; abort"
    exit 0
fi


#
# Wait for the OTG state machine to reach b_idle.
#
elapsed=0

while [ "$elapsed" -lt 10 ]; do
    state="$(get_state)"

    [ "$state" = "b_idle" ] && break

    sleep 1
    elapsed=$((elapsed + 1))
done


log "host-off state=$(get_state); keeping PHY off for ${HOST_OFF_DELAY}s"

sleep "$HOST_OFF_DELAY"


#
# Return DWC3 to host mode.
#
# The Exynos USB DRD PHY is powered on again and PIPE3 initialization
# runs before xHCI is recreated.
#
log "recovery: host ON (id=0)"

if ! echo 0 > "$DWC3/id"; then
    log "failed to write id=0"
    exit 0
fi


#
# Wait for RTL8153 to enumerate over SuperSpeed.
#
elapsed=0

while [ "$elapsed" -lt "$RECOVER_TIMEOUT" ]; do
    speed="$(rtl8153_speed)"

    if [ "$speed" = "5000" ]; then
        log "SUCCESS: RTL8153 speed=5000 after ${elapsed}s"
        exit 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
done


speed="$(rtl8153_speed)"

[ -n "$speed" ] || speed="missing"

log "FAILED: RTL8153 speed=$speed state=$(get_state) id=$(get_id) ccic_ids=$(get_ccic_ids)"

exit 0
