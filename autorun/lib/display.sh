status_screen() {
  local hostname_value="$1"
  local key self_ip self_free free_bytes self_conn self_version display_version repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  self_version=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "-")
  # The fleet table's own VER column stays as the bare commit hash above
  # (self_version) - it's a narrow column built for a short value.
  # display_version is the fuller "vX.Y.Z (hash)" form from
  # popup_version(), shown once on its own line instead.
  display_version=$(popup_version)
  while true; do
    clear
    if command -v figlet >/dev/null 2>&1; then
      figlet -w 100 "$hostname_value" 2>/dev/null || echo "=== $hostname_value ==="
    else
      echo "=== $hostname_value ==="
    fi
    echo "Version: $display_version"
    echo ""
    echo "IP address(es):"
    ip -4 -o addr show scope global 2>/dev/null | awk '{print "  " $4}'
    echo ""
    if mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
      echo "Share: \\\\$(hostname)\\share  ($(df -h --output=avail "$SHARE_MOUNT" 2>/dev/null | tail -n1 | tr -d ' ') free)"
    else
      echo "Share: not set up yet (use the menu)"
    fi
    echo ""
    echo "Fleet (this box plus any others seen on this network):"
    self_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)
    if mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
      free_bytes=$(df --output=avail -B1 "$SHARE_MOUNT" 2>/dev/null | tail -n1)
      self_free=$(awk -v b="${free_bytes:-0}" 'BEGIN{printf "%.1f GB", b/1e9}')
    else
      self_free="-"
    fi
    self_conn=$(smb_connection_count)
    fleet_table "$hostname_value" "${self_ip:-?}" "$self_free" "$self_conn" "$self_version"
    echo ""
    echo "CONN colour key: green = idle, yellow = some load, red = busy"
    echo "Press Q then Enter to go back to the menu (this refreshes every 5s)"
    read -r -t 5 key
    [ "${key:-}" = "q" ] && return
  done
}
