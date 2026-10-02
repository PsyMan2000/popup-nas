SHARE_LABEL="POPUP-SHARE"
SHARE_MOUNT="/srv/popup-share"

pick_disk() {
  local args=()
  while read -r name size model; do
    args+=("/dev/$name" "$size $model")
  done < <(lsblk -dno NAME,SIZE,MODEL)
  whiptail --title "Pick a disk" --menu "Which disk do you want to set up the share on?" 18 70 8 "${args[@]}" 3>&1 1>&2 2>&3
}

has_ntfs_partition() {
  lsblk -lno FSTYPE "$1" 2>/dev/null | grep -qx ntfs
}

pick_ntfs_partition() {
  local disk="$1"
  local args=()
  while read -r name fstype size; do
    [ "$fstype" = "ntfs" ] || continue
    args+=("/dev/$name" "$size")
  done < <(lsblk -lno NAME,FSTYPE,SIZE "$disk")
  if [ "${#args[@]}" -eq 0 ]; then
    whiptail --msgbox "No NTFS partition found on $disk." 10 60
    return 1
  fi
  whiptail --title "Pick a partition" --menu "Which partition on $disk is the NTFS partition to shrink?" 18 78 8 "${args[@]}" 3>&1 1>&2 2>&3
}

# $1 = disk (e.g. /dev/sda or /dev/nvme0n1), $2 = 1-based partition index on
# that disk. Looks the actual partition device name up via lsblk instead of
# gluing disk+number together, since that guess is wrong for NVMe naming
# (nvme0n1 + "1" is not nvme0n1p1).
part_dev() {
  local disk="$1" idx="$2" name
  name=$(lsblk -lno NAME "$disk" | tail -n +2 | sed -n "${idx}p")
  [ -n "$name" ] || return 1
  echo "/dev/$name"
}

setup_share() {
  local disk
  disk=$(pick_disk) || return

  if ! has_ntfs_partition "$disk"; then
    setup_share_whole_disk "$disk"
    return
  fi

  local part
  part=$(pick_ntfs_partition "$disk") || return

  local info min_size_mb
  info=$(ntfsresize --info --force "$part" 2>&1) || true
  min_size_mb=$(echo "$info" | grep -oP 'resize.*to \K[0-9]+' | head -n1 || true)

  whiptail --title "About to shrink $part" --scrolltext --yesno \
    "This will shrink $part and use the freed space for a new share partition labelled $SHARE_LABEL on $disk.\n\n$info\n\nThis changes the partition table on $disk. Continue?" \
    22 78 || return

  local size_gb
  size_gb=$(whiptail --inputbox "How many GB to free up for the share?" 10 60 "20" 3>&1 1>&2 2>&3) || return
  case "$size_gb" in ''|*[!0-9]*) whiptail --msgbox "That's not a whole number of GB." 8 50; return ;; esac

  local current_size_mb new_size_mb
  current_size_mb=$(( $(blockdev --getsize64 "$part") / 1024 / 1024 ))
  new_size_mb=$(( current_size_mb - size_gb * 1024 ))

  if [ -n "$min_size_mb" ] && [ "$new_size_mb" -lt "$min_size_mb" ]; then
    whiptail --msgbox "Can't shrink by that much - $part needs at least ${min_size_mb}MB (it has more used data than that GB figure allows for). Try a smaller amount." 10 70
    return
  fi
  if [ "$new_size_mb" -le 0 ]; then
    whiptail --msgbox "That's more space than $part has. Pick a smaller amount." 8 60
    return
  fi

  echo "Shrinking $part to ${new_size_mb}MB, this can take a while..."
  if ! yes | ntfsresize --force --size "${new_size_mb}M" "$part"; then
    whiptail --msgbox "ntfsresize failed - nothing else was touched. Check the output above before retrying." 10 70
    return
  fi

  local partnum
  partnum=$(echo "$part" | grep -oP '[0-9]+$')
  if ! parted -s "$disk" resizepart "$partnum" "${new_size_mb}MiB"; then
    whiptail --msgbox "parted resizepart failed AFTER ntfsresize already shrank the filesystem. Run 'ntfsresize --info $part' before doing anything else on this disk." 12 78
    return
  fi

  if ! parted -s "$disk" mkpart primary ext4 "${new_size_mb}MiB" 100%; then
    whiptail --msgbox "Failed to create the new partition. $disk's NTFS partition was already shrunk - check 'parted $disk print' before retrying." 12 78
    return
  fi
  partprobe "$disk" 2>/dev/null || true
  sleep 2

  local new_part
  new_part=$(lsblk -lno NAME "$disk" | tail -n1)
  new_part="/dev/$new_part"

  mkfs.ext4 -F -L "$SHARE_LABEL" "$new_part"
  mkdir -p "$SHARE_MOUNT"
  mount "$new_part" "$SHARE_MOUNT"
  chmod 0777 "$SHARE_MOUNT"

  configure_and_start_samba "$SHARE_MOUNT"

  whiptail --msgbox "Share ready at $SHARE_MOUNT and shared over SMB as \\\\$(hostname)\\share. Use 'Fill the share with the master image' next." 10 74
}

# Used when the chosen disk has no NTFS partition at all - a freshly wiped
# or blank PC, or one that was never Windows. Rather than formatting it NTFS
# first just to immediately shrink it again (pointless extra work when
# there's nothing on the disk worth keeping), this uses the whole disk
# directly as the share.
setup_share_whole_disk() {
  local disk="$1"

  whiptail --title "No NTFS partition on $disk" --yesno \
    "No NTFS partition was found on $disk - it looks wiped/blank (or was never Windows).\n\nUse the WHOLE disk as the share instead? This ERASES ANY EXISTING PARTITIONS OR DATA on $disk and turns it entirely into one share partition.\n\nContinue?" \
    14 78 || return

  systemctl stop smb nmb 2>/dev/null || pkill -x smbd nmbd 2>/dev/null || true
  umount "$SHARE_MOUNT" 2>/dev/null || true

  wipefs -a "$disk" >/dev/null 2>&1 || true
  if ! parted -s "$disk" mklabel gpt; then
    whiptail --msgbox "Failed to create a new partition table on $disk." 10 60
    return
  fi
  if ! parted -s "$disk" mkpart primary ext4 0% 100%; then
    whiptail --msgbox "Failed to create the share partition on $disk." 10 60
    return
  fi
  partprobe "$disk" 2>/dev/null || true
  sleep 2

  local new_part
  new_part=$(lsblk -lno NAME "$disk" | tail -n1)
  new_part="/dev/$new_part"

  mkfs.ext4 -F -L "$SHARE_LABEL" "$new_part"
  mkdir -p "$SHARE_MOUNT"
  mount "$new_part" "$SHARE_MOUNT"
  chmod 0777 "$SHARE_MOUNT"

  configure_and_start_samba "$SHARE_MOUNT"

  whiptail --msgbox "Share ready at $SHARE_MOUNT (the whole of $disk) and shared over SMB as \\\\$(hostname)\\share. Use 'Fill the share with the master image' next." 10 74
}

find_share_partition() {
  lsblk -lno NAME,LABEL 2>/dev/null | awk -v l="$SHARE_LABEL" '$2==l{print "/dev/"$1; exit}'
}

reverse_share() {
  local share_part
  share_part=$(find_share_partition)
  if [ -z "$share_part" ]; then
    whiptail --msgbox "No partition labelled $SHARE_LABEL was found on this machine - nothing to reverse." 10 60
    return
  fi

  local disk partnum
  disk="/dev/$(lsblk -no PKNAME "$share_part")"
  partnum=$(echo "$share_part" | grep -oP '[0-9]+$')

  if [ "$partnum" -eq 1 ]; then
    # This share was set up on a wiped/blank disk with the whole-disk
    # option (no NTFS partition existed to shrink from), so there's nothing
    # to grow back - reversing means wiping the disk back to blank, the
    # same state it was found in.
    whiptail --title "Reverse partitioning" --yesno \
      "$share_part is the only partition on $disk - this share was set up on a wiped/blank disk, not shrunk from an existing Windows partition.\n\nThis will WIPE $disk's partition table entirely, leaving it blank again (matching how it was found).\n\nContinue?" \
      14 78 || return

    systemctl stop smb nmb 2>/dev/null || pkill -x smbd nmbd 2>/dev/null || true
    umount "$SHARE_MOUNT" 2>/dev/null || true

    if ! wipefs -a "$disk"; then
      whiptail --msgbox "Failed to wipe $disk's partition table." 10 60
      return
    fi
    whiptail --msgbox "Done - $disk is blank again. Reboot the machine to hand it back cleanly." 10 70
    return
  fi

  local ntfs_partnum ntfs_part
  ntfs_partnum=$((partnum - 1))
  ntfs_part=$(part_dev "$disk" "$ntfs_partnum") || {
    whiptail --msgbox "Couldn't work out the NTFS partition's device name on $disk - stopping here rather than guessing. Run 'lsblk $disk' to check the layout." 10 70
    return
  }

  whiptail --title "Reverse partitioning" --yesno \
    "This will DELETE $share_part (and everything on it) and grow $ntfs_part back to fill the space.\n\nContinue?" 12 78 || return

  systemctl stop smb nmb 2>/dev/null || pkill -x smbd nmbd 2>/dev/null || true
  umount "$SHARE_MOUNT" 2>/dev/null || true

  if ! parted -s "$disk" rm "$partnum"; then
    whiptail --msgbox "Failed to delete $share_part - stopping here rather than touching $ntfs_part." 10 70
    return
  fi
  parted -s "$disk" resizepart "$ntfs_partnum" 100%
  yes | ntfsresize --force "$ntfs_part"

  whiptail --msgbox "Done - $ntfs_part has been grown back to fill the disk. Reboot the machine to hand it back cleanly." 10 70
}
