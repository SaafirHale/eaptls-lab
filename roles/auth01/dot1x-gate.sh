#!/bin/sh
# hostapd_cli action script: opens and closes the access port per MAC.
#
# hostapd_cli -a calls this as: <script> <ifname> <event> <station-mac> [...]
# hostapd raises AP-STA-CONNECTED when it marks a supplicant authorized (RADIUS
# Access-Accept) and AP-STA-DISCONNECTED when that authorization ends (logoff,
# failed re-authentication, link loss).
#
# The set lives in the bridge-family nftables table loaded from
# /etc/nftables.conf; frames from the access port whose source MAC is not in it
# are dropped before they can be forwarded.
set -eu

ifname="${1:-}"
event="${2:-}"
mac="${3:-}"

case "$event" in
    AP-STA-CONNECTED)
        nft add element bridge dot1x authorized "{ $mac }"
        logger -t dot1x-gate "authorized $mac on $ifname"
        ;;
    AP-STA-DISCONNECTED)
        nft delete element bridge dot1x authorized "{ $mac }" 2>/dev/null || true
        logger -t dot1x-gate "unauthorized $mac on $ifname"
        ;;
    *)
        ;;
esac
