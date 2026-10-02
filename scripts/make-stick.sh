#!/bin/bash
# make-stick.sh: write a complete, ready-to-boot popup-nas USB stick.
# Usage: ./make-stick.sh /dev/sdX /path/to/systemrescue.iso /path/to/popup-nas.srm
#
# Clones this repo's "stable" branch straight onto the stick (rather than
# copying this local checkout's files), so the result is a real git
# checkout that self-updates on its own from its very first boot - see
# autorun/lib/selfupdate.sh. Override the repo/branch with the
# UPDATE_REPO_URL / UPDATE_BRANCH environment variables if needed. Falls
# back to this checkout's own autorun/sysrescue.d/ if there's no network
# reachable right now - the stick still gets made, it just won't
# self-update until it's rebuilt from an online machine.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 /dev/sdX systemrescue.iso popup-nas.srm" >&2
  exit 1
fi

DEV="$1"; ISO="$2"; SRM="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_REPO_URL="${UPDATE_REPO_URL:-https://github.com/PsyMan2000/popup-nas.git}"
UPDATE_BRANCH="${UPDATE_BRANCH:-stable}"

[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }
[ -f "$ISO" ] || { echo "$ISO not found" >&2; exit 1; }
[ -f "$SRM" ] || { echo "$SRM not found" >&2; exit 1; }

echo "THIS WILL ERASE EVERYTHING on $DEV:"
lsblk "$DEV"
read -r -p "Type the device path again to confirm you want to WIPE $DEV: " CONFIRM
[ "$CONFIRM" = "$DEV" ] || { echo "Confirmation didn't match, aborting." >&2; exit 1; }

echo "Writing $ISO to $DEV..."
sudo dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync
sync
sudo partprobe "$DEV" 2>/dev/null || true
sleep 2

# SystemRescue's official USB writer leaves a writable FAT/exFAT data
# partition on the stick for exactly this purpose - find it.
DATA_PART=$(lsblk -lno NAME,FSTYPE "$DEV" | awk '$2=="vfat" || $2=="exfat" {print "/dev/"$1; exit}')
if [ -z "$DATA_PART" ]; then
  echo "Couldn't find a writable (FAT/exFAT) data partition on $DEV - check it manually with 'lsblk $DEV' and adjust this script if the layout doesn't match." >&2
  exit 1
fi

MNT=$(mktemp -d)
sudo mount "$DATA_PART" "$MNT"

CLONE_DIR=$(mktemp -d)
if command -v git >/dev/null 2>&1 && \
   GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$UPDATE_BRANCH" --single-branch "$UPDATE_REPO_URL" "$CLONE_DIR" 2>/tmp/make-stick-clone.log; then
  echo "Cloned $UPDATE_REPO_URL ($UPDATE_BRANCH) - this stick will self-update from its first boot."
  if [ -f "$HERE/../autorun/popup-nas.conf" ]; then
    cp "$HERE/../autorun/popup-nas.conf" "$CLONE_DIR/autorun/popup-nas.conf"
  fi
  sudo cp -r "$CLONE_DIR/." "$MNT/"
else
  echo "Couldn't clone $UPDATE_REPO_URL (see /tmp/make-stick-clone.log) - using this checkout's own files instead. This stick won't self-update."
  sudo mkdir -p "$MNT/autorun" "$MNT/sysrescue.d"
  sudo cp -r "$HERE/../autorun/." "$MNT/autorun/"
  sudo cp -r "$HERE/../sysrescue.d/." "$MNT/sysrescue.d/"
fi
rm -rf "$CLONE_DIR"

sudo mkdir -p "$MNT/sysresccd"
sudo cp "$SRM" "$MNT/sysresccd/"

if [ ! -f "$MNT/autorun/popup-nas.conf" ]; then
  echo "NOTE: no popup-nas.conf found - copy autorun/popup-nas.conf.example to popup-nas.conf and edit it (NAS path/credentials) before relying on the default image-source option."
fi

sudo umount "$MNT"
rmdir "$MNT"

echo "Done. Just boot this stick and press Enter at the boot menu - copytoram and loadsrm are set as defaults, no typing needed."
