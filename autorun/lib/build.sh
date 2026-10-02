# Build a new popup-nas.iso, or write a brand new popup-nas stick onto a
# spare disk, directly from an already-booted popup-nas machine - no
# separate VM/WSL needed, since SystemRescue itself already ships
# sysrescue-customize/xorriso/squashfs-tools. See docs/architecture.md for
# how this was worked out (live-boot source discovery, the symlink gotcha,
# the ISO download URL).

BUILD_CACHE="/root/.cache/popup-nas-build"

# Fallback source ISO if popup-nas.conf doesn't set SYSRESCUE_ISO_URL. Keep
# this matching whatever SystemRescue version this stick itself is built
# from (check the boot label, e.g. RESCUE1302 = 13.02) - or just set
# SYSRESCUE_ISO_URL in popup-nas.conf instead of editing this file when the
# stock image gets upgraded.
DEFAULT_SYSRESCUE_ISO_URL="https://fastly-cdn.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso"

# Finds the root of the currently-booted medium (where autorun/,
# sysrescue.d/ and popup-nas.srm live). Tries the normal archiso mount
# point first (fast, and where it's been every time so far), falls back to
# scanning every partition - the same method autorun0 itself uses to find
# its own files - in case that's ever not where it is.
find_boot_media_root() {
  local candidate="/run/archiso/bootmnt"
  if [ -f "$candidate/autorun/autorun0" ] && [ -d "$candidate/sysrescue.d" ]; then
    echo "$candidate"
    return 0
  fi
  local dev d
  for dev in $(lsblk -rno NAME,TYPE 2>/dev/null | awk '$2=="part"{print "/dev/"$1}'); do
    mount | grep -q "^$dev " || continue
    d=$(mount | awk -v dev="$dev" '$1==dev{print $3; exit}')
    [ -n "$d" ] || continue
    if [ -f "$d/autorun/autorun0" ] && [ -d "$d/sysrescue.d" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

# Finds this stick's own popup-nas.srm, wherever it happens to live.
# Different sticks have been built with it in different places - directly
# at the drive root (confirmed working that way on real hardware), or
# under a sysresccd/ folder (how scripts/make-stick.sh and make-iso.sh
# build it, also confirmed working, via the ISO booted in Proxmox).
# Checking only one fixed location here was a real bug - fixed 2026-10-02
# after it broke "Make more sticks" on the first real attempt to use it.
find_srm() {
  local root="$1" candidate
  for candidate in "$root/sysresccd/popup-nas.srm" "$root/popup-nas.srm"; do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  find "$root" -maxdepth 3 -iname 'popup-nas.srm' 2>/dev/null | head -n1
}

# Downloads the stock SystemRescue ISO once per boot session and caches it
# (the OS is RAM-only, so this doesn't persist across a reboot, but that's
# fine - rebuilding more than once in the same session shouldn't re-fetch a
# ~1.3GB file each time). Echoes the local path on success.
ensure_source_iso() {
  local url="${SYSRESCUE_ISO_URL:-$DEFAULT_SYSRESCUE_ISO_URL}"
  local fname dest
  fname=$(basename "$url")
  mkdir -p "$BUILD_CACHE"
  dest="$BUILD_CACHE/$fname"
  if [ -f "$dest" ]; then
    echo "$dest"
    return 0
  fi
  # >&2 here is deliberate: this function's whole stdout is captured by
  # callers (src_iso=$(ensure_source_iso)), and whiptail draws its box by
  # writing to whatever stdout it's given - without this redirect, that
  # drawing leaks straight into $src_iso instead of appearing on screen.
  whiptail --infobox "Downloading $fname (around 1.3GB, only needed once per boot)..." 8 70 >&2
  if ! curl -fL -o "$dest" "$url" 2>"$BUILD_CACHE/download.log"; then
    rm -f "$dest"
    whiptail --msgbox "Download failed. Check network access and the URL:\n$url\n\n(set SYSRESCUE_ISO_URL in popup-nas.conf to change it)\n\nSee $BUILD_CACHE/download.log for details." 14 78
    return 1
  fi
  echo "$dest"
}

# Finds the block device backing the currently booted medium, so "make a
# new stick" can refuse to offer wiping the very disk we're running from.
boot_disk() {
  local src part
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null) || return 1
  part=$(basename "$src")
  lsblk -no PKNAME "/dev/$part" 2>/dev/null | head -n1
}

# Fills $dest_dir with a working autorun/ + sysrescue.d/ pair, for either
# build_popup_iso() or make_new_stick() to then copy onto their actual
# destination. Tries the public repo first (so the result is a real git
# checkout that can self-update from its first boot - see
# lib/selfupdate.sh); if that's not reachable, falls back to this box's own
# currently-running files instead, so the build still works offline - it
# just won't self-update. $1 = this box's own autorun/sysrescue.d root (as
# found by find_boot_media_root), $2 = empty directory to fill.
stage_update_source() {
  local root="$1" dest="$2" clone_dir

  clone_dir=$(mktemp -d)
  if clone_update_repo "$clone_dir"; then
    if [ -f "$root/autorun/popup-nas.conf" ]; then
      cp "$root/autorun/popup-nas.conf" "$clone_dir/autorun/popup-nas.conf"
    fi
    cp -r "$clone_dir/." "$dest/"
    rm -rf "$clone_dir"
    return 0
  fi
  rm -rf "$clone_dir"

  echo "Couldn't reach the public repo - using this box's own current files instead (the result won't self-update)."
  cp -r "$root/autorun" "$dest/autorun"
  cp -r "$root/sysrescue.d" "$dest/sysrescue.d"
}

build_popup_iso() {
  local root srm src_iso dest_dir dest_iso free_mb recipe_dir default_dest

  root=$(find_boot_media_root) || {
    whiptail --msgbox "Couldn't find this stick's own autorun/sysrescue.d folders - can't build from here." 10 70
    return
  }
  srm=$(find_srm "$root")
  [ -n "$srm" ] && [ -f "$srm" ] || {
    whiptail --msgbox "Couldn't find popup-nas.srm anywhere on this stick (checked $root/sysresccd/ and $root/ directly) - this stick doesn't have the SRM module baked in." 10 76
    return
  }

  src_iso=$(ensure_source_iso) || return

  # Only suggest the SMB share as the destination when it's an actually-live
  # mount - $SHARE_MOUNT is just a fixed path, so if no share has been set
  # up yet that folder may be empty or not exist, which would be a
  # misleading default.
  if mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
    default_dest="$SHARE_MOUNT"
  else
    default_dest="/mnt/usb"
  fi
  dest_dir=$(whiptail --inputbox "Folder to write popup-nas.iso into (needs ~3GB free - e.g. the share this box is currently serving, or a mounted USB drive):" 10 76 "$default_dest" 3>&1 1>&2 2>&3) || return
  if [ ! -d "$dest_dir" ] && ! mkdir -p "$dest_dir" 2>/dev/null; then
    whiptail --msgbox "Couldn't create/access $dest_dir." 10 60
    return
  fi
  free_mb=$(df -Pm "$dest_dir" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$free_mb" ] || [ "$free_mb" -lt 3000 ]; then
    whiptail --yesno "$dest_dir only shows ${free_mb:-0}MB free - this needs roughly 3GB. Continue anyway?" 10 70 || return
  fi
  dest_iso="$dest_dir/popup-nas.iso"

  whiptail --yesno "Build $dest_iso now?\n\nSource ISO: $src_iso\nSRM module: $srm\n\nThis can take several minutes - don't interrupt it once started." 14 78 || return

  recipe_dir=$(mktemp -d)
  mkdir -p "$recipe_dir/iso_add" "$recipe_dir/iso_delete" "$recipe_dir/iso_patch_and_script" "$recipe_dir/build_into_srm"

  clear
  echo "Getting the latest popup-nas files ready to bake in..."
  stage_update_source "$root" "$recipe_dir/iso_add"
  mkdir -p "$recipe_dir/iso_add/sysresccd"
  cp "$srm" "$recipe_dir/iso_add/sysresccd/popup-nas.srm"

  echo "Building $dest_iso ..."
  if sysrescue-customize --auto --source="$src_iso" --dest="$dest_iso" --recipe-dir="$recipe_dir" --overwrite; then
    rm -rf "$recipe_dir"
    whiptail --msgbox "Done: $dest_iso\n\nBoot-test this in a VM before trusting it, same as any other build of this." 12 76
  else
    rm -rf "$recipe_dir"
    whiptail --msgbox "sysrescue-customize failed - scroll back up in the shell output to see the error." 10 72
  fi
}

make_new_stick() {
  local root srm src_iso exclude_disk disk confirm data_part mnt
  local args=()

  root=$(find_boot_media_root) || {
    whiptail --msgbox "Couldn't find this stick's own autorun/sysrescue.d folders - can't build from here." 10 70
    return
  }
  srm=$(find_srm "$root")
  [ -n "$srm" ] && [ -f "$srm" ] || {
    whiptail --msgbox "Couldn't find popup-nas.srm anywhere on this stick (checked $root/sysresccd/ and $root/ directly) - this stick doesn't have the SRM module baked in." 10 76
    return
  }

  src_iso=$(ensure_source_iso) || return
  exclude_disk=$(boot_disk)

  while read -r name size model; do
    [ -n "$exclude_disk" ] && [ "$name" = "$exclude_disk" ] && continue
    args+=("/dev/$name" "$size $model")
  done < <(lsblk -dno NAME,SIZE,MODEL)
  if [ "${#args[@]}" -eq 0 ]; then
    whiptail --msgbox "No other disks found to write to - plug in a blank USB stick first." 10 60
    return
  fi

  disk=$(whiptail --title "Pick a disk to turn into a new popup-nas stick" --menu "This stick itself (${exclude_disk:-unknown}) is left out of this list for safety.\n\nWARNING: everything on the chosen disk will be ERASED." 18 74 8 "${args[@]}" 3>&1 1>&2 2>&3) || return

  whiptail --title "About to ERASE $disk" --yesno "THIS WILL ERASE EVERYTHING on $disk and turn it into a new popup-nas stick. This cannot be undone.\n\nContinue?" 12 74 || return

  confirm=$(whiptail --inputbox "Type the device path again to confirm ($disk):" 10 70 3>&1 1>&2 2>&3) || return
  [ "$confirm" = "$disk" ] || { whiptail --msgbox "Confirmation didn't match - nothing was touched." 10 60; return; }

  clear
  echo "Writing $src_iso to $disk ..."
  if ! dd if="$src_iso" of="$disk" bs=4M status=progress conv=fsync; then
    whiptail --msgbox "Writing the ISO to $disk failed partway through - that disk is now in an unknown state, don't trust it." 10 74
    return
  fi
  sync
  partprobe "$disk" 2>/dev/null || true
  sleep 2

  data_part=$(lsblk -lno NAME,FSTYPE "$disk" | awk '$2=="vfat" || $2=="exfat" {print "/dev/"$1; exit}')
  if [ -z "$data_part" ]; then
    whiptail --msgbox "Wrote the ISO to $disk, but couldn't find its writable data partition to copy autorun/sysrescue.d/SRM onto. Check 'lsblk $disk' from a shell and copy them on by hand." 12 78
    return
  fi

  mnt=$(mktemp -d)
  local mount_tries=0 mounted=0
  while [ "$mount_tries" -lt 5 ]; do
    if mount "$data_part" "$mnt" 2>/tmp/popup-stick-mount.log; then
      mounted=1
      break
    fi
    sleep 1
    mount_tries=$((mount_tries + 1))
  done
  if [ "$mounted" -ne 1 ]; then
    rmdir "$mnt" 2>/dev/null
    whiptail --msgbox "Wrote the ISO to $disk, but couldn't mount its data partition ($data_part) after several tries to copy autorun/sysrescue.d/SRM onto - it may need longer to settle after writing on this particular stick. See /tmp/popup-stick-mount.log, or try 'mount $data_part /mnt' by hand from a shell." 12 78
    return
  fi
  echo "Mounted $data_part: $(df -h --output=avail "$mnt" 2>/dev/null | tail -n1 | tr -d ' ') free for autorun/sysrescue.d/SRM."

  echo "Getting the latest popup-nas files ready..."
  stage_update_source "$root" "$mnt"
  mkdir -p "$mnt/sysresccd"
  if ! cp "$srm" "$mnt/sysresccd/"; then
    umount "$mnt" 2>/dev/null
    rmdir "$mnt" 2>/dev/null
    whiptail --msgbox "Wrote $disk's boot image, but ran out of room on its data partition ($data_part) while copying popup-nas.srm onto it - that partition may be too small on this particular stick. Check 'lsblk $disk' and 'df -h' from a shell before trusting this stick." 12 78
    return
  fi

  umount "$mnt"
  rmdir "$mnt"

  whiptail --msgbox "Done - $disk is now a ready-to-boot popup-nas stick. Boot-test it before relying on it." 10 70
}
