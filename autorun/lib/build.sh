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

  # dd'ing the ISO also copies its existing partition table as-is, which
  # still describes the ISO's own small original size, not whatever's
  # actually available on this physical stick. On a GPT-labelled ISO,
  # sgdisk -e fixes that up by relocating the backup GPT structures to the
  # disk's real end - but SystemRescue's hybrid ISO has turned out to use
  # a plain old-style MBR (msdos) table instead on the hardware tested so
  # far, confirmed 2026-10-02 ('Partition Table: msdos' in parted's
  # output), for which there's no equivalent stale-header problem - MBR
  # doesn't store a separate backup copy the way GPT does. This call is
  # still harmless to leave in (sgdisk simply logs "Invalid partition
  # data!" and does nothing on an MBR disk) in case some build of the ISO
  # ever does use GPT instead.
  sgdisk -e "$disk" >/tmp/popup-stick-gpt-fix.log 2>&1 || true
  partprobe "$disk" 2>/dev/null || true
  sleep 1

  # IMPORTANT, found on real hardware 2026-10-02: SystemRescue's hybrid
  # ISO doesn't put its actual OS content (kernel, airootfs squashfs,
  # GRUB's own menu/config) in a normal partition at all - the whole
  # ISO9660 filesystem just starts at the very beginning of the disk and
  # is read directly, with only a tiny EFI System Partition (a megabyte
  # or so, for UEFI booting) showing up as a real entry in the partition
  # table. That means the partition table can NEVER be trusted to say
  # where the ISO's real content ends - reading it back (as this used to)
  # found only that tiny EFI partition and concluded free space started
  # right after it, at ~1.5MiB in. Formatting a new partition there
  # landed it WITHIN the live ISO content rather than past it, destroying
  # enough of it (GRUB's menu/config and/or the kernel) that a stick
  # built that way wrote and reported success, but only ever reached a
  # bare "grub>" prompt on boot - confirmed by a real boot test.
  #
  # The one number that can always be trusted instead is the exact byte
  # size of the ISO file $src_iso that was just dd'd onto this disk - dd
  # copied precisely that many bytes starting at the very start of the
  # disk and touched nothing beyond it, regardless of what any partition
  # table does or doesn't claim. Starting the new partition comfortably
  # past that point (rounded up, plus a spare megabyte of margin) is
  # always safe.
  #
  # Rather than growing the ISO's own content or its tiny EFI partition
  # in place (risks corrupting boot files actually needed to boot at
  # all), this creates a brand new partition in the stick's genuinely
  # free remaining space purely to hold autorun/sysrescue.d/popup-nas.srm.
  # autorun0 finds its own files by scanning every partition's actual
  # content (see find_boot_media_root and the real-hardware gotcha it's
  # built for), not by any fixed partition number or label, so a new
  # partition works exactly the same as the first one for this.
  local src_size_bytes src_end_mib part_end new_part_mb
  src_size_bytes=$(stat -c %s "$src_iso" 2>/dev/null)
  if [ -z "$src_size_bytes" ]; then
    whiptail --msgbox "Wrote $disk's boot image, but couldn't read $src_iso's size back to work out where it safely ends on the disk, so nothing further was touched. Don't add a data partition to this stick by hand without checking 'stat $src_iso' first." 12 78
    return
  fi
  # Round the ISO's exact byte size up to the next whole MiB, then add
  # one more MiB of margin on top - cheap insurance against any rounding
  # difference between the file's exact size and how it actually landed
  # on the disk.
  src_end_mib=$(( (src_size_bytes + 1048575) / 1048576 + 1 ))
  part_end="${src_end_mib}MiB"
  if ! parted -s "$disk" mkpart primary ext4 "$part_end" 100% 2>/tmp/popup-stick-part.log; then
    whiptail --msgbox "Wrote $disk's boot image, but couldn't create a second partition in its remaining free space for autorun/sysrescue.d/SRM - this stick may be too small overall. See /tmp/popup-stick-part.log." 12 78
    return
  fi
  partprobe "$disk" 2>/dev/null || true
  sleep 2

  # Picking the partition by "whichever one lsblk lists last" assumed a
  # brand new partition always gets the highest number - wrong on real
  # hardware, 2026-10-02: a stick whose only existing partition was
  # numbered 2 (the small EFI partition near the very start) left number
  # 1 free, so the new partition created just above took number 1 instead
  # - putting it FIRST in lsblk's output (which lists by number, not by
  # physical position on the disk or by size), with the small original
  # partition coming last. That picked the wrong, tiny partition. Picking
  # the LARGEST partition on the disk instead is reliable regardless of
  # numbering, since this new partition always uses the stick's entire
  # remaining free space and will dwarf any small boot/EFI partition
  # already there.
  data_part=$(lsblk -brno NAME,TYPE,SIZE "$disk" | awk '$2=="part"{print $3, $1}' | sort -n | tail -n1 | awk '{print "/dev/"$2}')
  if [ -z "$data_part" ] || [ ! -b "$data_part" ]; then
    whiptail --msgbox "Wrote $disk's boot image, but couldn't work out which partition on it is the new one just created. Check 'lsblk -b $disk' from a shell." 12 78
    return
  fi
  new_part_mb=$(lsblk -bno SIZE "$data_part" 2>/dev/null | awk '{print int($1/1024/1024)}')
  if [ -z "$new_part_mb" ] || [ "$new_part_mb" -lt 100 ]; then
    whiptail --msgbox "Wrote $disk's boot image, but only found ${new_part_mb:-0}MB free to use for autorun/sysrescue.d/SRM - this stick is too small overall for this to work. Try a bigger stick." 12 78
    return
  fi

  mkfs.ext4 -F -L POPUPDATA "$data_part" >/tmp/popup-stick-mkfs.log 2>&1

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
    whiptail --msgbox "Wrote $disk's boot image and data partition, but ran out of room while copying popup-nas.srm onto it ($data_part) - check 'df -h' and 'lsblk $disk' from a shell before trusting this stick." 12 78
    return
  fi

  umount "$mnt"
  rmdir "$mnt"

  whiptail --msgbox "Done - $disk is now a ready-to-boot popup-nas stick. Boot-test it before relying on it." 10 70
}
