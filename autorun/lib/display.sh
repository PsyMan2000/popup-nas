# Colours the hostname banner one ANSI colour per text row, cycling
# through a short fixed palette, giving the big figlet letters a simple
# "rainbow" stripe effect. Deliberately pure bash + standard ANSI escape
# codes - no extra package (e.g. lolcat) - because self_update() never
# touches the compiled popup-nas.srm bundle, so anything needing a new
# package would need every stick's SRM module rebuilt by hand before it
# could show up; this works immediately on any stick the moment it pulls
# this update, no reboot and no rebuild needed.
rainbow_banner() {
  local colours=(31 33 32 36 34 35) # red yellow green cyan blue magenta
  local i=0 line
  while IFS= read -r line; do
    printf '\033[1;%sm%s\033[0m\n' "${colours[$((i % ${#colours[@]}))]}" "$line"
    i=$((i + 1))
  done
}

status_screen() {
  local hostname_value="$1"
  local key self_ip self_free free_bytes self_conn self_version display_version repo_root banner_text
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  self_version=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "-")
  # The fleet table's own VER column stays as the bare commit hash above
  # (self_version) - it's a narrow column built for a short value.
  # display_version is the fuller "vX.Y.Z (hash)" form from
  # popup_version(), shown once on its own line instead.
  display_version=$(popup_version)
  while true; do
    clear
    banner_text=""
    if command -v figlet >/dev/null 2>&1; then
      banner_text=$(figlet -w 100 "$hostname_value" 2>/dev/null)
    fi
    if [ -n "$banner_text" ]; then
      echo "$banner_text" | rainbow_banner
    else
      printf '\033[1;36m=== %s ===\033[0m\n' "$hostname_value"
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
