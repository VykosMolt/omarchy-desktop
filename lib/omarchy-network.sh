# Which link actually carries the connection. A VPN puts its own tunnel on the
# internet route, and a tunnel has no carrier, speed or SSID, so callers that
# want to name the connection want the link underneath it.

OMARCHY_INTERNET_PROBE=1.1.1.1

# Overridable so the tunnel classification can be tested against a fixture tree.
OMARCHY_NET_SYSFS="${OMARCHY_NET_SYSFS:-/sys/class/net}"

# tun/tap devices carry no DEVTYPE, so they go by their tun_flags attribute.
omarchy_link_is_tunnel() {
  local device=$1 line

  [[ -n $device ]] || return 1
  [[ -e $OMARCHY_NET_SYSFS/$device/tun_flags ]] && return 0
  [[ -r $OMARCHY_NET_SYSFS/$device/uevent ]] || return 1

  while IFS= read -r line; do
    [[ $line == DEVTYPE=* ]] || continue
    case ${line#DEVTYPE=} in
      wireguard | ppp | vti | vti6 | ipip | sit | gre | gretap | ip6tnl | xfrm) return 0 ;;
      *) return 1 ;;
    esac
  done <"$OMARCHY_NET_SYSFS/$device/uevent"

  return 1
}

# The first default route that is not itself a tunnel. A VPN that installs its
# own default leaves the physical one in the table, so walk them.
omarchy_underlying_device() {
  local device

  while read -r device; do
    omarchy_link_is_tunnel "$device" || {
      printf '%s\n' "$device"
      return 0
    }
  done < <(ip route show default 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }')

  return 1
}

omarchy_link_device() {
  local device

  device=$(ip route get "$OMARCHY_INTERNET_PROBE" 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')

  if omarchy_link_is_tunnel "$device"; then
    omarchy_underlying_device && return 0
  fi

  printf '%s\n' "$device"
}
