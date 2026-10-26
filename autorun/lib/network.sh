wait_for_network() {
  echo -n "Waiting for a network address"
  for _ in $(seq 1 30); do
    if ip -4 -o addr show scope global 2>/dev/null | grep -q .; then
      echo " - got one."
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo ""
  echo "No network address yet after 30s - continuing anyway. Check a cable is connected, or use the menu to retry later."
}

primary_ip() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# Make "<hostname>.local" names work (mDNS, via Avahi), IPv4 only.
# Found 2026-10-26 on real hardware: Avahi was installed but not running, and
# once started it answered name.local lookups with an IPv6 address only, which
# the other PCs could not use. So: switch IPv6 off on this box, tell Avahi to
# use IPv4 only, and (re)start it AFTER the hostname has been set, so it
# announces the real name. IPv6 is not needed for the SMB share or SSH.
# Never fatal: every step is best-effort and the boot carries on regardless.
start_mdns() {
  local conf="${AVAHI_CONF:-/etc/avahi/avahi-daemon.conf}" k
  for k in all default; do
    sysctl -qw "net.ipv6.conf.$k.disable_ipv6=1" 2>/dev/null || true
  done
  command -v avahi-daemon >/dev/null 2>&1 || return 0
  if [ -f "$conf" ]; then
    if grep -q '^#\?use-ipv6=' "$conf"; then
      sed -i 's/^#\?use-ipv6=.*/use-ipv6=no/' "$conf" 2>/dev/null || true
    else
      sed -i '/^\[server\]/a use-ipv6=no' "$conf" 2>/dev/null || true
    fi
  fi
  systemctl restart avahi-daemon 2>/dev/null || true
  return 0
}
