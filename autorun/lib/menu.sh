ask_hostname() {
  local default_name="popup-$(tr -dc 'a-z0-9' </dev/urandom | head -c4)"
  whiptail --title "popup-nas" --inputbox \
    "Enter a name for this pop-up share (shown on screen and to the network, e.g. Room3-Shelf2):" \
    10 70 "$default_name" 3>&1 1>&2 2>&3
}

build_submenu() {
  local choice
  while true; do
    choice=$(whiptail --title "Make more sticks" --menu "Build onto what?" 14 74 2 \
      "1" "Build an ISO file (e.g. for a VM, or to flash later)" \
      "2" "Clone this stick straight onto a new USB drive" 3>&1 1>&2 2>&3) || return
    case "$choice" in
      1) build_popup_iso ;;
      2) make_new_stick ;;
    esac
  done
}

main_menu() {
  local hostname_value="$1"
  local choice version
  # Computed once per session, not per loop - popup_version() only ever
  # changes via self_update(), and that restarts this whole script fresh
  # anyway (see exec bash "$HERE/autorun0" in lib/selfupdate.sh), so this
  # loop never needs to re-read it.
  version=$(popup_version)
  while true; do
    choice=$(whiptail --title "popup-nas [$hostname_value] - $version" --menu "What do you want to do?" 21 78 9 \
      "1" "Show status screen (hostname, IP, fleet)" \
      "2" "Set up the SMB share (shrink NTFS, or use a wiped disk whole)" \
      "3" "Fill the share with the master image" \
      "4" "Reverse partitioning (delete share, restore original state)" \
      "5" "Drop to a shell" \
      "6" "Reboot" \
      "7" "Power off" \
      "8" "Make more sticks (build an ISO, or clone to a new USB)" \
      "9" "Pull latest update now (no reboot needed)" 3>&1 1>&2 2>&3) || continue

    case "$choice" in
      1) status_screen "$hostname_value" ;;
      2) setup_share ;;
      3) populate_share ;;
      4) reverse_share ;;
      5) clear; echo "Type 'exit' to come back to this menu."; bash ;;
      6) reboot ;;
      7) poweroff ;;
      8) build_submenu ;;
      9) pull_update_now ;;
    esac
  done
}
