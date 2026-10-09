# Menu option 5: a proper interactive shell. Found on real hardware
# 2026-10-08: a plain "bash" here showed no prompt and arrow keys / Del came
# out as ^[[A and ^[[3~, because SystemRescue's launcher sends this program's
# output through pipes, and bash only switches its prompt and line editing
# on when its input AND its error output are both a real terminal. So the
# shell is pointed at /dev/tty (the real screen/keyboard) explicitly, and
# started with -i (interactive). Without a /dev/tty it falls back to the old
# plain "bash".
drop_to_shell() {
  clear
  echo "Type 'exit' to come back to this menu."
  echo "Type 'startx' for the SystemRescue desktop (close it to return here)."
  if { : </dev/tty; } 2>/dev/null; then
    bash -i </dev/tty >/dev/tty 2>&1
  else
    bash
  fi
}

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

# Used by menu items 8, 9 and 10, which genuinely need the stick (8 copies
# from it, 9 writes updates onto it, 10 saves the NAS settings onto it).
# Returns 0 if the stick is there; if
# not, explains and returns 1 so the caller skips the action.
need_stick() {
  stick_present && return 0
  whiptail --msgbox "This option needs the stick, and the stick can't be read right now - it looks like it has been taken out.

Plug it back in and reboot (option 6) to use this one.

Options 1 to 7 don't need the stick and carry on working." 14 70
  return 1
}

main_menu() {
  local hostname_value="$1"
  local choice version channel_text newt_colors badge_pid backtitle badge_dev default_item=1
  local box_w=78 box_h=22
  # Boot-time snapshot of the things read from the stick's git checkout
  # (version, commit, update channel). Taken once here, while the stick is
  # certainly still in, and reused by the badge and status screen, so that
  # pulling the stick out later (options 1-7 don't need it) doesn't change
  # them - e.g. to a grey "NO GIT". main_menu() is also what a self-update
  # restarts, so a new version always takes a fresh snapshot. The "unset"
  # makes the four lines below compute live instead of reusing an older
  # snapshot.
  unset POPUP_VERSION_CACHE CHANNEL_NAME_CACHE CHANNEL_INFO_CACHE POPUP_COMMIT_CACHE POPUP_NUMBER_CACHE
  POPUP_VERSION_CACHE=$(popup_version)
  CHANNEL_NAME_CACHE=$(channel_name)
  CHANNEL_INFO_CACHE=$(channel_info)
  POPUP_COMMIT_CACHE=$(popup_commit)
  POPUP_NUMBER_CACHE=$(popup_number)
  version="$POPUP_VERSION_CACHE"
  # The update-channel banner (stable = green, stage = amber, anything
  # else = red; see channel_info in lib/selfupdate.sh). It is drawn as a
  # coloured line at the bottom centre of the menu box (menu_badge_overlay
  # in lib/display.sh). If the screen is too small for that, it falls back
  # to a plain coloured line at the top-left of the screen instead.
  channel_text="UPDATE CHANNEL: $(channel_info | cut -d'|' -f1)"
  newt_colors=$(channel_newt_colors)
  while true; do
    badge_pid=""
    backtitle=""
    badge_dev=$(badge_tty_dev)
    if menu_badge_fits "$box_w" "$box_h" "$badge_dev"; then
      menu_badge_overlay "$box_w" "$box_h" "$badge_dev" &
      badge_pid=$!
    else
      backtitle="$channel_text"
    fi
    # Items 1-7 work with the stick pulled out (the system runs from RAM
    # and these only touch this PC's disk). 8, 9 and 10 need the stick, so they
    # sit under a separator line. The "-" row is just that line: choosing
    # it does nothing (see the case below). Its text starts with a space on
    # purpose: whiptail reads any text starting with "--" as an option.
    choice=$(NEWT_COLORS="$newt_colors" whiptail --backtitle "$backtitle" --title "popup-nas [$hostname_value] - $version" --default-item "$default_item" --menu "What do you want to do?" "$box_h" "$box_w" 11 \
      "1" "Show status screen (hostname, IP, fleet)" \
      "2" "Set up the SMB share (pick the disk to use for it)" \
      "3" "Fill the share: pick images or files (NAS, another popup, USB)" \
      "4" "Reverse partitioning (delete share, restore original state)" \
      "5" "Drop to a shell (startx for systemrescue)" \
      "6" "Reboot" \
      "7" "Power off" \
      "-" " ------ Leave the stick IN to use the three below ------" \
      "8" "Make more sticks (build an ISO, or clone to a new USB)" \
      "9" "Update or roll back: pick a version, auto-update on/off" \
      "10" "Change the NAS settings (path, login) and pick files" 3>&1 1>&2 2>&3)
    local rc=$?
    if [ -n "$badge_pid" ]; then
      kill "$badge_pid" 2>/dev/null
      wait "$badge_pid" 2>/dev/null
    fi
    [ "$rc" -ne 0 ] && continue

    default_item=1
    case "$choice" in
      1) status_screen "$hostname_value" ;;
      2) setup_share ;;
      3) populate_share ;;
      4) reverse_share ;;
      5) drop_to_shell ;;
      6) reboot ;;
      7) poweroff ;;
      -) default_item=8 ;;
      8) need_stick && build_submenu ;;
      9) need_stick && pull_update_now ;;
      10) need_stick && edit_nas_settings ;;
    esac
  done
}
