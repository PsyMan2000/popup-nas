# Build a new popup-nas.iso, or write a brand new popup-nas stick onto a
# spare disk, directly from an already-booted popup-nas machine - no
# separate VM/WSL needed, since SystemRescue itself already ships
# sysrescue-customize/xorriso/squashfs-tools. See docs/architecture.md for
# how this was worked out (live-boot source discovery, the symlink gotcha,
# the ISO download URL).

# (Overridable: the PC-side scripts in scripts/ and build/ set their own, because
# /root is not writable there.)
BUILD_CACHE="${BUILD_CACHE:-/root/.cache/popup-nas-build}"

# Fallback source ISO if popup-nas.conf doesn't set SYSRESCUE_ISO_URL. Keep
# this matching whatever SystemRescue version this stick itself is built
# from (check the boot label, e.g. RESCUE1302 = 13.02) - or just set
# SYSRESCUE_ISO_URL in popup-nas.conf instead of editing this file when the
# stock image gets upgraded.
DEFAULT_SYSRESCUE_ISO_URL="https://fastly-cdn.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso"

# Fallback download link for SystemRescue's official USB writer (the file
# make_new_stick() uses), used only if no copy is already on the stick or
# in the build cache and SYSRESCUE_USBWRITER_URL isn't set in
# popup-nas.conf. IMPORTANT: the writer's version must match the
# SystemRescue ISO's version - when DEFAULT_SYSRESCUE_ISO_URL above is
# upgraded, update this to the matching writer release at the same time
# (list: https://gitlab.com/systemrescue/systemrescue-usbwriter/-/releases).
DEFAULT_SYSRESCUE_USBWRITER_URL="https://fastly-cdn.system-rescue.org/download/usbwriter/1.1.1/sysrescueusbwriter-x86_64.AppImage"

# Where popup-nas.srm (the Samba/git/etc. module) is downloaded from when a
# stick or ISO needs one and there isn't a copy to hand - so a new stick never
# needs the file copied off an existing stick. It is a GitHub Release asset
# on the PUBLIC repo; the Release tag is "srm-<SystemRescue version>". The
# SHA-256 is checked after every download, so a damaged or wrong file is
# rejected rather than baked into a stick. When SystemRescue is upgraded:
# build a new .srm (build/README.md), publish it as a new Release (tag
# srm-<new version>, file name exactly popup-nas.srm), and update BOTH lines
# below together with DEFAULT_SYSRESCUE_ISO_URL and
# DEFAULT_SYSRESCUE_USBWRITER_URL above. popup-nas.conf can override them
# with SRM_URL (and SRM_SHA256; with SRM_URL set and no SRM_SHA256 only the
# "is it a SquashFS file" check is done).
DEFAULT_SRM_URL="https://github.com/PsyMan2000/popup-nas/releases/download/srm-13.02/popup-nas.srm"
DEFAULT_SRM_SHA256="c0a4522c390485dc42235309a259647e88455481265138cd5b89f6d5889a8527"

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

# True if $1 looks like a real popup-nas.srm: a SquashFS file (they start
# with "hsqs") of a plausible size and, if $2 is given, with exactly that
# SHA-256. Says why on stderr if not.
srm_ok() {
  local f="$1" want="${2:-}" got
  [ -s "$f" ] || { echo "empty or missing file" >&2; return 1; }
  [ "$(head -c 4 "$f" 2>/dev/null)" = "hsqs" ] || { echo "not a SquashFS file (a failed download or an error page?)" >&2; return 1; }
  [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 1000000 ] || { echo "file is too small to be popup-nas.srm" >&2; return 1; }
  if [ -n "$want" ]; then
    got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$(echo "$want" | tr '[:upper:]' '[:lower:]')" ] || { echo "checksum is $got, expected $want" >&2; return 1; }
  fi
  return 0
}

# Downloads popup-nas.srm from the GitHub Release (see DEFAULT_SRM_URL) into
# the build cache and checks it with srm_ok. Echoes the path and returns 0
# on success; returns 1, leaving nothing behind, if the download fails or
# the file is not the right one (why: $BUILD_CACHE/srm-download.log). A copy
# already downloaded earlier is reused if it still checks out. Deliberately
# silent (no whiptail), so scripts/make-stick.sh and build/make-iso.sh can
# use it too; its callers draw the "downloading..." message.
fetch_srm() {
  local url="${SRM_URL:-$DEFAULT_SRM_URL}" want dest tmp log
  if [ -n "${SRM_URL:-}" ]; then want="${SRM_SHA256:-}"; else want="${SRM_SHA256:-$DEFAULT_SRM_SHA256}"; fi
  mkdir -p "$BUILD_CACHE" 2>/dev/null || return 1
  dest="$BUILD_CACHE/popup-nas.srm"
  tmp="$dest.part"
  log="$BUILD_CACHE/srm-download.log"
  if [ -f "$dest" ] && srm_ok "$dest" "$want" >/dev/null 2>&1; then
    echo "$dest"
    return 0
  fi
  rm -f "$dest" "$tmp"
  if curl -fL --retry 2 --connect-timeout 15 -o "$tmp" "$url" 2>"$log" && srm_ok "$tmp" "$want" 2>>"$log"; then
    mv "$tmp" "$dest" && { echo "$dest"; return 0; }
  fi
  rm -f "$tmp"
  return 1
}

# This stick's own popup-nas.srm (find_srm) or, if it has none, the
# published one downloaded by fetch_srm. Echoes the path; returns 1 if
# neither works. >&2 on the box: this function's stdout is captured by its
# callers (see ensure_source_iso for the same gotcha).
ensure_srm() {
  local root="$1" srm
  srm=$(find_srm "$root")
  if [ -n "$srm" ] && [ -f "$srm" ]; then
    echo "$srm"
    return 0
  fi
  whiptail --infobox "This stick has no popup-nas.srm - downloading it from GitHub (about 33 MB)..." 8 70 >&2
  fetch_srm
}

# Finds SystemRescue's official USB writer (a single .AppImage file) - the
# tool make_new_stick() uses to write a new stick. Looked for, in order:
#   1. SYSRESCUE_USBWRITER_PATH from popup-nas.conf, if set and present
#   2. the build cache (e.g. just downloaded there by hand with curl)
#   3. this stick's own sysresccd/ folder, then its root - the best place
#      to keep it, since make_new_stick() also copies it onto every new
#      stick it makes, so a cloned stick can clone further sticks too
#   4. SYSRESCUE_USBWRITER_URL from popup-nas.conf, downloaded into the
#      build cache
# The writer's version must match the SystemRescue version being written
# (the tool checks this itself and refuses to run on a mismatch). This
# isn't hardcoded to a download URL on purpose: the right file depends on
# the SystemRescue release, and a wrong guess would silently fail.
# Echoes the path and returns 0 if found, returns 1 if not.
find_usbwriter() {
  local root="$1" dir found dest url
  if [ -n "${SYSRESCUE_USBWRITER_PATH:-}" ] && [ -f "$SYSRESCUE_USBWRITER_PATH" ]; then
    echo "$SYSRESCUE_USBWRITER_PATH"
    return 0
  fi
  for dir in "$BUILD_CACHE" "$root/sysresccd" "$root"; do
    [ -d "$dir" ] || continue
    found=$(find "$dir" -maxdepth 1 -iname '*usbwriter*.AppImage' 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  done
  url="${SYSRESCUE_USBWRITER_URL:-$DEFAULT_SYSRESCUE_USBWRITER_URL}"
  if [ -n "$url" ]; then
    mkdir -p "$BUILD_CACHE"
    dest="$BUILD_CACHE/sysrescueusbwriter.AppImage"
    # >&2: this function's stdout is captured by its caller (see
    # ensure_source_iso for the same gotcha).
    whiptail --infobox "Downloading SystemRescue's USB writer..." 8 60 >&2
    # Only accept the download if it is a plausible AppImage (an ELF
    # file) - a failed/redirected download can leave an HTML error page
    # that would otherwise be run as if it were the writer.
    if curl -fL -o "$dest" "$url" 2>"$BUILD_CACHE/usbwriter-download.log" \
       && [ "$(head -c 4 "$dest" 2>/dev/null | tail -c 3)" = "ELF" ]; then
      echo "$dest"
      return 0
    fi
    rm -f "$dest"
  fi
  return 1
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

# After SystemRescue's USB writer has written $1 (a whole disk), works out
# which partition on it is the writable boot filesystem our files belong
# on. Prefers a partition whose label starts with RESCUE (the label
# SystemRescue itself requires on its boot device, e.g. RESCUE1302);
# failing that, the largest partition with a normal writable filesystem
# type. Never goes by partition number or list position (see the
# numbering gotcha in docs/architecture.md) - only by label and size.
find_new_stick_partition() {
  local disk="$1" p fs lab size best="" best_size=0
  for p in $(lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'); do
    fs=$(blkid -s TYPE -o value "$p" 2>/dev/null)
    lab=$(blkid -s LABEL -o value "$p" 2>/dev/null)
    case "$fs" in
      vfat|exfat|ext4|ext3|ext2|ntfs) ;;
      *) continue ;;
    esac
    case "$lab" in
      RESCUE*) echo "$p"; return 0 ;;
    esac
    size=$(lsblk -bndo SIZE "$p" 2>/dev/null)
    if [ "${size:-0}" -gt "$best_size" ]; then
      best="$p"
      best_size="$size"
    fi
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
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

# Where SystemRescue keeps its own tools (sysrescue-customize etc). An SSH
# login has this folder on its PATH, but the menu that autorun0 runs at boot
# does NOT (its PATH is only /usr/local/sbin:/usr/local/bin:/usr/bin), so
# "sysrescue-customize" was "command not found" (exit code 127) when "Build an
# ISO file" was chosen from the monitor menu, while the very same build worked
# over SSH. Found on real hardware 2026-10-05 thanks to the build log.
SYSRESCUE_BIN_DIR="${SYSRESCUE_BIN_DIR:-/usr/share/sysrescue/bin}"

# Echoes the full path of sysrescue-customize: from PATH if it is there,
# otherwise from SystemRescue's own tools folder. Returns 1 if not found.
find_sysrescue_customize() {
  local found
  found=$(command -v sysrescue-customize 2>/dev/null)
  if [ -z "$found" ] && [ -x "$SYSRESCUE_BIN_DIR/sysrescue-customize" ]; then
    found="$SYSRESCUE_BIN_DIR/sysrescue-customize"
  fi
  [ -n "$found" ] || return 1
  echo "$found"
}

build_popup_iso() {
  local root srm src_iso dest_dir dest_iso free_mb recipe_dir default_dest log rc reason sc

  root=$(find_boot_media_root) || {
    whiptail --msgbox "Couldn't find this stick's own autorun/sysrescue.d folders - can't build from here." 10 70
    return
  }
  srm=$(ensure_srm "$root") || {
    whiptail --msgbox "Couldn't find popup-nas.srm on this stick (checked $root/sysresccd/ and $root/ directly), and downloading it from GitHub failed too - check the network and try again. Nothing has been touched.\n\nWhy it failed: $BUILD_CACHE/srm-download.log" 14 78
    return
  }

  # Checked now, before the big source-ISO download, so a missing tool is
  # reported straight away.
  sc=$(find_sysrescue_customize) || {
    whiptail --msgbox "Couldn't find sysrescue-customize (SystemRescue's own ISO builder) on this box - looked on the normal PATH and in $SYSRESCUE_BIN_DIR. Nothing has been built." 11 76
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
  # Everything sysrescue-customize prints is also saved in a log file, with a
  # short header of facts about this box. Found on real hardware 2026-10-05:
  # a build that failed from the monitor menu left only "scroll back up to
  # see the error", but the screen had already been cleared, so the reason
  # was lost. Now the last lines of the log are shown in the failure box
  # itself and the full log is kept for later.
  log="$BUILD_CACHE/iso-build.log"
  mkdir -p "$BUILD_CACHE"
  {
    echo "=== popup-nas ISO build $(date) ==="
    echo "cwd: $PWD  HOME: ${HOME:-<unset>}  TMPDIR: ${TMPDIR:-<unset>}"
    echo "stdin: $(readlink /proc/$$/fd/0)  stdout: $(readlink /proc/$$/fd/1)"
    echo "builder: $sc"
    echo "PATH: $PATH"
    echo "source ISO: $src_iso ($(du -h "$src_iso" 2>/dev/null | cut -f1))"
    echo "recipe: $recipe_dir ($(du -sh "$recipe_dir/iso_add" 2>/dev/null | cut -f1) to add)"
    df -h / /tmp "$dest_dir" "$BUILD_CACHE" 2>&1
    free -m 2>&1
    echo "=== sysrescue-customize output ==="
  } > "$log" 2>&1
  PATH="$PATH:$SYSRESCUE_BIN_DIR" "$sc" --auto --source="$src_iso" --dest="$dest_iso" --recipe-dir="$recipe_dir" --overwrite 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  rm -rf "$recipe_dir"
  if [ "$rc" -eq 0 ]; then
    whiptail --msgbox "Done: $dest_iso\n\nBoot-test this in a VM before trusting it, same as any other build of this." 12 76
  else
    # Long lines are wrapped (not cut) so the end of the error - the part
    # that says what went wrong - is never lost.
    reason=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$log" | grep -a -v '^[[:space:]]*$' | tail -8 | fold -s -w 72 | tail -12)
    whiptail --msgbox "sysrescue-customize failed (exit code $rc). Last lines of its output:\n\n$reason\n\nThe whole log is kept in:\n$log" 24 78
  fi
}

# Writes a brand new popup-nas stick onto a spare disk.
#
# HISTORY - why this does NOT use dd (found on real hardware 2026-10-04):
# this used to dd the stock ISO onto the disk and then add a second ext4
# partition (POPUPDATA) holding autorun/, sysrescue.d/ and the SRM. That
# stick booted to plain SystemRescue, not popup-nas. SystemRescue only
# looks for autorun/ and sysrescue.d/ at the root of its BOOT DEVICE
# filesystem (the one it booted from) - never on any other partition -
# and a dd'd ISO's boot filesystem is read-only, so our files could only
# ever sit somewhere SystemRescue never looks. SystemRescue's own docs
# say dd-style writing can't carry extra files, and recommend their USB
# writer (or Rufus on Windows), both of which make a WRITABLE boot
# filesystem. (autorun0's own partition scan doesn't help here: that only
# finds our files once autorun0 is already running, but SystemRescue has
# to find autorun/ first in order to launch it.) The earlier dd-era
# lessons - never trust the partition table for where ISO content ends,
# never pick a partition by list position - no longer apply, since
# nothing here partitions by hand any more.
#
# Now: SystemRescue's own USB writer writes the stick, then autorun/,
# sysrescue.d/, .git and popup-nas.srm go at the ROOT of the filesystem
# it created - the same layout a Rufus ISO-Image-mode stick has, which is
# known to boot into popup-nas.
make_new_stick() {
  local root srm usbwriter src_iso exclude_disk disk confirm data_part mnt sectors
  local iso_mb avail_mb uw tmp_unpack rc p lab_now
  local args=()

  root=$(find_boot_media_root) || {
    whiptail --msgbox "Couldn't find this stick's own autorun/sysrescue.d folders - can't build from here." 10 70
    return
  }
  srm=$(ensure_srm "$root") || {
    whiptail --msgbox "Couldn't find popup-nas.srm on this stick (checked $root/sysresccd/ and $root/ directly), and downloading it from GitHub failed too - check the network and try again. Nothing has been touched.\n\nWhy it failed: $BUILD_CACHE/srm-download.log" 14 78
    return
  }

  # Checked up front, before anything is erased.
  usbwriter=$(find_usbwriter "$root") || {
    whiptail --msgbox "This needs SystemRescue's official USB writer (one .AppImage file), and it isn't on this box yet. Nothing has been touched.\n\nGet the one matching your SystemRescue version (e.g. 13.02) from:\nhttps://gitlab.com/systemrescue/systemrescue-usbwriter/-/releases\n\nThe automatic download from the built-in link also failed (see $BUILD_CACHE/usbwriter-download.log). Either put the file in the sysresccd folder on this stick (best), OR set SYSRESCUE_USBWRITER_URL in popup-nas.conf, OR download it into $BUILD_CACHE/ with curl." 20 78
    return
  }

  src_iso=$(ensure_source_iso) || return

  # The writer unpacks the whole ISO into a temporary folder first, so the
  # place that folder lives needs about an ISO's worth of room (plus
  # slack for the unpacked writer itself). On this RAM-only OS that folder
  # is in memory - fail now, with nothing erased, rather than part way.
  iso_mb=$(( $(stat -c %s "$src_iso" 2>/dev/null || echo 0) / 1048576 ))
  avail_mb=$(df -Pm "$BUILD_CACHE" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$avail_mb" ] || [ "$avail_mb" -lt $(( iso_mb + 500 )) ]; then
    whiptail --msgbox "Not enough free working space for the USB writer: it needs about $(( iso_mb + 500 ))MB free in $BUILD_CACHE but only ${avail_mb:-0}MB is available. This box probably doesn't have enough RAM free for this. Nothing has been touched." 12 76
    return
  fi

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

  # Make sure nothing on the target is mounted before it gets rewritten.
  for p in $(lsblk -lnpo NAME "$disk" 2>/dev/null | tac); do
    umount "$p" 2>/dev/null || true
  done

  # Wipe stale data off the target first. The USB writer only rewrites sector
  # 0 and its own partition; anything left elsewhere on a REUSED stick (e.g.
  # from a whole ISO that was dd'd to it earlier) can make Windows mark the
  # new partition Offline, so the stick boots but gets no drive letter. Zero
  # the first 64 MiB and the last 16 MiB (the same areas Rufus clears).
  sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo 0)
  whiptail --infobox "Wiping old data from $disk ..." 8 60
  wipefs -a "$disk" >/dev/null 2>&1 || true
  if [ "$sectors" -le 131072 ]; then
    whiptail --msgbox "$disk is too small to use (or its size couldn't be read). Nothing else was done." 10 70
    return
  fi
  if ! dd if=/dev/zero of="$disk" bs=1M count=64 conv=fsync status=none 2>/dev/null; then
    whiptail --msgbox "Couldn't write to the start of $disk (is it write-protected or failing?). Nothing else was done." 10 70
    return
  fi
  if ! dd if=/dev/zero of="$disk" bs=512 seek=$((sectors - 32768)) count=32768 conv=fsync status=none 2>/dev/null; then
    whiptail --msgbox "Couldn't write to the end of $disk (is it write-protected or failing?). Nothing else was done." 10 70
    return
  fi
  sync
  blockdev --rereadpt "$disk" 2>/dev/null || true

  # Run a copy of the writer from the build cache: the stick it may be
  # stored on is FAT, which is often mounted noexec. Extract-and-run mode
  # means it doesn't need FUSE (which this live system may not have).
  mkdir -p "$BUILD_CACHE"
  uw="$BUILD_CACHE/usbwriter-run.AppImage"
  [ "$usbwriter" -ef "$uw" ] || cp -f "$usbwriter" "$uw"
  chmod +x "$uw"
  tmp_unpack="$BUILD_CACHE/usbwriter-tmp"
  rm -rf "$tmp_unpack"
  mkdir -p "$tmp_unpack"

  clear
  echo "Writing $src_iso to $disk with SystemRescue's USB writer ..."
  echo "(It may ask you to confirm - answer yes if so. Messages stay on screen if it fails.)"
  echo ""
  # Run directly on the terminal (not piped) so any prompt it shows works.
  APPIMAGE_EXTRACT_AND_RUN=1 TMPDIR="$tmp_unpack" "$uw" --cli --targetdev="$disk" --tmpdir="$tmp_unpack" "$src_iso"
  rc=$?
  rm -rf "$tmp_unpack"
  if [ "$rc" -ne 0 ]; then
    whiptail --msgbox "SystemRescue's USB writer reported a problem (exit code $rc) - scroll back up in the shell output to see why. $disk is now in an unknown state, don't trust it. (A version mismatch between the writer and the ISO is the most likely cause - they must be the same SystemRescue version.)" 14 78
    return
  fi
  sync
  partprobe "$disk" 2>/dev/null || true
  sleep 2

  data_part=$(find_new_stick_partition "$disk")
  if [ -z "$data_part" ] || [ ! -b "$data_part" ]; then
    whiptail --msgbox "The USB writer finished, but I couldn't find a writable boot partition on $disk to add popup-nas's files to. Check 'lsblk -f $disk' from a shell - this stick will boot as plain SystemRescue until fixed." 12 78
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
    whiptail --msgbox "The USB writer finished, but I couldn't mount $data_part to add popup-nas's files after several tries. See /tmp/popup-stick-mount.log, or try 'mount $data_part /mnt' by hand from a shell." 12 78
    return
  fi
  if ! touch "$mnt/.popup-write-test" 2>/dev/null; then
    umount "$mnt" 2>/dev/null
    rmdir "$mnt" 2>/dev/null
    whiptail --msgbox "The boot partition ($data_part) on the new stick is READ-ONLY, so popup-nas's files can't be added to it. That's the same problem a plain dd stick has - this stick will boot as plain SystemRescue." 12 78
    return
  fi
  rm -f "$mnt/.popup-write-test"
  echo "Mounted $data_part: $(df -h --output=avail "$mnt" 2>/dev/null | tail -n1 | tr -d ' ') free."

  echo "Getting the latest popup-nas files ready..."
  stage_update_source "$root" "$mnt"
  # This stick is FAT/exFAT, which can't hold real Unix permissions - same
  # reason self_update() sets this on every boot; set it now so a stick
  # never starts out looking 'modified' to git.
  git -C "$mnt" config core.fileMode false 2>/dev/null || true
  mkdir -p "$mnt/sysresccd"
  if ! cp "$srm" "$mnt/sysresccd/"; then
    umount "$mnt" 2>/dev/null
    rmdir "$mnt" 2>/dev/null
    whiptail --msgbox "Wrote the new stick, but ran out of room while copying popup-nas.srm onto it ($data_part) - check 'df -h' and 'lsblk $disk' from a shell before trusting this stick." 12 78
    return
  fi
  # Best-effort: keep a copy of the USB writer on the new stick too, so it
  # can make further sticks itself.
  cp -f "$usbwriter" "$mnt/sysresccd/" 2>/dev/null || true
  sync

  # Check the result against what SystemRescue actually needs to find at
  # the root of the boot filesystem, instead of just saying Done.
  local ok=1 report="" spec flag rest rel desc
  for spec in \
    "-f|autorun/autorun0|autorun/autorun0 (our menu script)" \
    "-f|sysrescue.d/200-popup-nas.yaml|sysrescue.d settings (copytoram, SRM, SSH key)" \
    "-d|.git|.git folder (needed for self-update)" \
    "-f|sysresccd/popup-nas.srm|popup-nas.srm module (Samba, git)"; do
    flag="${spec%%|*}"; rest="${spec#*|}"; rel="${rest%%|*}"; desc="${rest#*|}"
    if [ "$flag" "$mnt/$rel" ]; then
      report="${report}  OK       $desc\n"
    else
      report="${report}  MISSING  $desc\n"
      ok=0
    fi
  done
  lab_now=$(blkid -s LABEL -o value "$data_part" 2>/dev/null)
  case "$lab_now" in
    RESCUE*) report="${report}  OK       drive label ${lab_now}\n" ;;
    *) report="${report}  WRONG    drive label '${lab_now:-none}' (SystemRescue needs RESCUExxxx)\n"; ok=0 ;;
  esac

  umount "$mnt"
  rmdir "$mnt"

  if [ "$ok" -eq 1 ]; then
    whiptail --msgbox "Done - $disk is now a popup-nas stick.\n\n${report}\nBoot-test it before relying on it (it should reach the popup-nas menu, not plain SystemRescue)." 18 78
  else
    whiptail --msgbox "$disk was written, but it is NOT ready:\n\n${report}\nDon't rely on this stick." 18 78
  fi
}
