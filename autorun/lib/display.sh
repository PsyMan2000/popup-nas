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

# One-line traffic-light badge for the update channel (see channel_info in
# lib/selfupdate.sh): black/white text on a green, amber, red or grey
# background, with the channel written out in words as well so the colour
# is never the only signal.
channel_badge() {
  local info label colour style
  info=$(channel_info)
  label="${info%|*}"
  colour="${info##*|}"
  case "$colour" in
    green) style="1;30;42" ;;
    amber) style="1;30;43" ;;
    red)   style="1;97;41" ;;
    *)     style="1;30;47" ;;
  esac
  printf '\033[%sm UPDATE CHANNEL: %s \033[0m\n' "$style" "$label"
}

# Works out which terminal device is the real screen/terminal this menu
# is on, and echoes its path (e.g. /dev/tty1 on the stick's own monitor, or
# /dev/pts/3 over SSH). Found on real hardware 2026-10-05: on the stick's
# own console autorun0's output and error streams are pipes (only its
# INPUT is attached to /dev/tty1), so asking "how big is the screen?" of
# the error stream failed and the badge fell back to the top-left corner.
# Input is tried first, then error output, then normal output. Called
# from main_menu() itself (not from the background overlay job, because a
# background job in a non-interactive script has its input replaced by
# /dev/null).
badge_tty_dev() {
  local fd dev
  for fd in 0 2 1; do
    dev=$(tty <&"$fd" 2>/dev/null) || continue
    [ -n "$dev" ] && [ -c "$dev" ] && { echo "$dev"; return 0; }
  done
  return 1
}

# Draws the coloured channel badge on the blank row just under the OK /
# Cancel buttons of the main menu box, centred, so it's right in front of
# whoever is looking at the menu even on a big monitor. whiptail itself
# can only colour whole widget types, never one line of text inside a box,
# so this paints that one line over the top AFTER whiptail has drawn the
# menu. Started in the background by main_menu() just before whiptail runs
# and killed as soon as whiptail returns.
#
# $1 = box width, $2 = box height (the same two numbers given to whiptail),
# $3 = the terminal device from badge_tty_dev. whiptail centres its box on screen: top = (rows - height) / 2, left =
# (cols - width) / 2 (checked against real whiptail at many screen sizes).
# The blank row is 2 rows above the box's bottom edge. The badge is
# redrawn once a second so it comes back if something paints over it (a
# stray system message). Cursor position is saved and restored around each
# draw so whiptail never notices.
menu_badge_overlay() {
  local box_w="$1" box_h="$2" dev="$3" info label colour style text len esc size rows cols row col
  info=$(channel_info)
  label="${info%|*}"
  colour="${info##*|}"
  case "$colour" in
    green) style="1;30;42" ;;
    amber) style="1;30;43" ;;
    red)   style="1;97;41" ;;
    *)     style="1;30;47" ;;
  esac
  text=" UPDATE CHANNEL: $label "
  len=${#text}
  esc=$(printf '\033')
  # The screen size is read ONCE, right now, because whiptail reads it once
  # when it draws its box and never re-centres the box if the window is
  # resized afterwards (found on real hardware over SSH: the box stayed put
  # but a badge that re-read the size moved away from it). Using the same
  # frozen size keeps the badge locked to the box.
  size=$(stty -F "$dev" size 2>/dev/null) || return 0
  rows="${size% *}"
  cols="${size#* }"
  [ "$rows" -ge "$box_h" ] 2>/dev/null && [ "$cols" -ge "$box_w" ] 2>/dev/null || return 0
  row=$(( (rows - box_h) / 2 + box_h - 1 ))
  col=$(( (cols - box_w) / 2 + (box_w - len) / 2 + 1 ))
  [ "$col" -lt 1 ] && col=1
  sleep 0.3
  while true; do
    printf '%s7%s[%d;%dH%s[%sm%s%s[0m%s8' "$esc" "$esc" "$row" "$col" "$esc" "$style" "$text" "$esc" "$esc" > "$dev" 2>/dev/null
    sleep 1
  done
}

# True if the screen is big enough for the badge overlay above to fit
# under the main menu box (so main_menu() knows whether it also needs the
# plain top-left banner as a fallback). $1 = box width, $2 = box height,
# $3 = the terminal device from badge_tty_dev.
menu_badge_fits() {
  local size rows cols
  [ -n "$3" ] || return 1
  size=$(stty -F "$3" size 2>/dev/null) || return 1
  rows="${size% *}"
  cols="${size#* }"
  [ "$rows" -ge "$2" ] 2>/dev/null && [ "$cols" -ge "$1" ] 2>/dev/null
}

# The same colours for whiptail's top line (its --backtitle). whiptail
# can't show ANSI codes, but NEWT_COLORS can colour that line. Echoes a
# value for NEWT_COLORS; "amber" is whiptail's "yellow".
channel_newt_colors() {
  local info colour
  info=$(channel_info)
  colour="${info##*|}"
  case "$colour" in
    green) echo "roottext=black,green" ;;
    amber) echo "roottext=black,yellow" ;;
    red)   echo "roottext=white,red" ;;
    *)     echo "roottext=black,lightgray" ;;
  esac
}

status_screen() {
  local hostname_value="$1"
  local key self_ip self_free free_bytes self_conn self_version display_version repo_root banner_text self_channel badge self_images
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  self_version=$(popup_commit)
  # The fleet table's own VER column stays as the bare commit hash above
  # (self_version) - it's a narrow column built for a short value.
  # display_version is the fuller "vX.Y.Z (hash)" form from
  # popup_version(), shown once on its own line instead.
  display_version=$(popup_version)
  # Worked out once per visit to this screen (git status on a FAT stick
  # is not instant), not on every 5-second refresh.
  self_channel=$(channel_name)
  badge=$(channel_badge)
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
    echo "$badge"
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
    self_images=$(share_image_summary)
    fleet_table "$hostname_value" "${self_ip:-?}" "$self_free" "$self_conn" "$self_version" "$self_channel" "$self_images"
    echo ""
    echo "CONN colour key: green = idle, yellow = some load, red = busy"
    echo "CHANNEL colour key: green = stable, yellow = stage, red = anything else (dev/test)"
    echo "Press Q then Enter to go back to the menu (this refreshes every 5s)"
    read -r -t 5 key
    [ "${key:-}" = "q" ] && return
  done
}
