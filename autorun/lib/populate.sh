populate_share() {
  if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
    whiptail --msgbox "Set up the share first (menu option 2) before filling it." 10 60
    return
  fi

  local choice
  choice=$(whiptail --menu "Where's the master image coming from?" 14 70 2 \
    "1" "Default NAS location (from popup-nas.conf)" \
    "2" "Browse / enter a different source path" 3>&1 1>&2 2>&3) || return

  local source_path
  if [ "$choice" = "1" ]; then
    if [ -z "${MASTER_IMAGE_SMB_PATH:-}" ]; then
      whiptail --msgbox "No default NAS path is set in popup-nas.conf on this stick - pick option 2 instead, or edit that file." 10 70
      return
    fi
    source_path="$MASTER_IMAGE_SMB_PATH"
  else
    source_path=$(whiptail --inputbox "Enter the source path - an SMB path like //nas-server/masterimages, or a local path (e.g. another mounted USB drive):" 10 74 3>&1 1>&2 2>&3) || return
  fi

  mkdir -p /mnt/source
  local mounted_smb=0
  if [[ "$source_path" == //* ]]; then
    if ! mount -t cifs "$source_path" /mnt/source -o "username=${MASTER_IMAGE_USER:-guest},password=${MASTER_IMAGE_PASS:-},ro"; then
      whiptail --msgbox "Couldn't mount $source_path - check the path and credentials in popup-nas.conf, or pick option 2 to try a different path." 10 74
      return
    fi
    mounted_smb=1
  elif [ ! -d "$source_path" ]; then
    whiptail --msgbox "$source_path doesn't look like a mounted local path." 10 60
    return
  else
    mount --bind "$source_path" /mnt/source
  fi

  whiptail --infobox "Copying from $source_path to $SHARE_MOUNT - this can take a while for a large image, watch the console below." 8 74
  clear
  rsync -ah --info=progress2 /mnt/source/ "$SHARE_MOUNT/"
  local rc=$?
  umount /mnt/source 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    whiptail --msgbox "Copy finished. Check the file listing on the status screen." 10 60
  else
    whiptail --msgbox "rsync exited with an error (code $rc) - scroll back on the console to see what happened." 10 70
  fi
}
