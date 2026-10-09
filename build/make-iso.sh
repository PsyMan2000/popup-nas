#!/bin/bash
# make-iso.sh: build a self-contained popup-nas.iso using SystemRescue's own
# sysrescue-customize tool (https://www.system-rescue.org/scripts/sysrescue-customize/).
#
# The resulting ISO has autorun/, sysrescue.d/, and the SRM module already
# baked in - flash it to a stick with Rufus/Etcher/dd, or boot it directly
# in a VM, with no extra copy step needed afterwards.
#
# Usage: ./make-iso.sh /path/to/systemrescue.iso /path/to/popup-nas.srm /path/to/popup-nas.iso
#
# Write "auto" instead of the .srm path to have it downloaded from this
# repo's GitHub Release (and checked against its SHA-256) rather than
# copying the file off another stick:
#   ./make-iso.sh /path/to/systemrescue.iso auto /path/to/popup-nas.iso
#
# Needs sysrescue-customize on PATH, plus its own dependencies (xorriso,
# mksquashfs). It's preinstalled if you run this from inside a booted
# SystemRescue system. On Windows, WSL works too:
#   sudo apt install xorriso squashfs-tools
#   (then download sysrescue-customize itself - see build/README.md)
#
# This always builds from THIS checkout's own autorun/sysrescue.d/ - it's
# the developer-focused build path, for testing a change before promoting
# it to the public repo's "stable" branch. The live in-menu "Make more
# sticks" option is the one that pulls from stable.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 systemrescue.iso popup-nas.srm|auto popup-nas.iso" >&2
  echo "  (auto = download popup-nas.srm from the GitHub Release)" >&2
  exit 1
fi

SRC_ISO="$1"; SRM="$2"; DEST_ISO="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

[ -f "$SRC_ISO" ] || { echo "$SRC_ISO not found" >&2; exit 1; }
if [ "$SRM" = auto ]; then
  # Same download-and-check code the stick's own menu uses (fetch_srm in
  # autorun/lib/build.sh).
  BUILD_CACHE="${BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/popup-nas-build}"
  # shellcheck source=../autorun/lib/build.sh
  source "$REPO_ROOT/autorun/lib/build.sh"
  echo "Downloading popup-nas.srm from the GitHub Release..."
  SRM=$(fetch_srm) || { echo "Couldn't download popup-nas.srm (see $BUILD_CACHE/srm-download.log) - check the network, or pass the file instead of 'auto'." >&2; exit 1; }
  echo "Got it: $SRM"
fi
[ -f "$SRM" ] || { echo "$SRM not found" >&2; exit 1; }
command -v sysrescue-customize >/dev/null 2>&1 || {
  echo "sysrescue-customize not found on PATH - see build/README.md for how to get it." >&2
  exit 1
}

RECIPE_DIR=$(mktemp -d)
trap 'rm -rf "$RECIPE_DIR"' EXIT

# sysrescue-customize's recipe-dir format: files under iso_add/ are copied
# into the ISO at the matching path (overwriting anything already there).
# iso_delete/ and iso_patch_and_script/ are required to exist even when
# unused. We don't use build_into_srm/ - popup-nas.srm is already built
# separately (see build/README.md) and just gets copied in via iso_add.
mkdir -p "$RECIPE_DIR/iso_add" "$RECIPE_DIR/iso_delete" "$RECIPE_DIR/iso_patch_and_script" "$RECIPE_DIR/build_into_srm"

cp -r "$REPO_ROOT/autorun" "$RECIPE_DIR/iso_add/autorun"
cp -r "$REPO_ROOT/sysrescue.d" "$RECIPE_DIR/iso_add/sysrescue.d"
mkdir -p "$RECIPE_DIR/iso_add/sysresccd"
cp "$SRM" "$RECIPE_DIR/iso_add/sysresccd/popup-nas.srm"

if [ ! -f "$RECIPE_DIR/iso_add/autorun/popup-nas.conf" ]; then
  echo "NOTE: no popup-nas.conf in autorun/ - copy autorun/popup-nas.conf.example to autorun/popup-nas.conf and edit it (NAS path/credentials) before relying on the default image-source option in the built ISO."
fi

echo "Building $DEST_ISO from $SRC_ISO ..."
sysrescue-customize --auto \
  --source="$SRC_ISO" \
  --dest="$DEST_ISO" \
  --recipe-dir="$RECIPE_DIR" \
  --overwrite

echo "Done: $DEST_ISO"
echo "Boot-test this in a VM before flashing it to real sticks or trusting it on real hardware."
echo "Flash to a stick the same way as the stock ISO (Rufus/Etcher/dd) - no extra copy step needed, autorun/sysrescue.d/the SRM module are already baked in."
