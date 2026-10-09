#!/bin/bash
# THROWAWAY test helper - lives on the test-srm-160 branch only, never on
# stable. Usage:  bash pick-test.sh [name-for-this-popup] [nosrm]
#
# Add the word  nosrm  as the second argument to make THIS session pretend the
# stick has no popup-nas.srm, so "Make more sticks" has to download it from
# the GitHub Release. Nothing on the stick is moved or changed.
#
# Loads this branch's version of the menu code over the top of the stick's
# own copy, for THIS session only, then opens the main menu. Leave it with
# menu option 6 (Reboot) or 7 (Power off).
#
# What it does and does not touch:
#   - The stick's own code is NOT changed (nothing is pulled onto it).
#   - The one thing that does write to the stick is the "Change the NAS
#     settings" item, which saves into the stick's popup-nas.conf. A backup
#     copy is made first (see below).
#   - Option 9 (pull update) is switched off here, because the update branch
#     is pointed at this test branch for the session, so that "Make more
#     sticks" -> "Build an ISO" bakes THIS version into the ISO.
set -uo pipefail
BRANCH=test-srm-160
export HERE=/mnt/popup-media/autorun
[ -d "$HERE/lib" ] || { echo "Can't find the stick's autorun folder at $HERE - is this popup fully booted?"; exit 1; }
for f in network selfupdate partition samba fleet populate display build menu; do
  # shellcheck disable=SC1090
  source "$HERE/lib/$f.sh"
done
# shellcheck disable=SC1091
[ -f "$HERE/popup-nas.conf" ] && source "$HERE/popup-nas.conf"

# Keep a copy of the stick's settings file, once, before testing can change it.
if [ -f "$HERE/popup-nas.conf" ] && [ ! -f /root/popup-nas.conf.before-test ]; then
  cp "$HERE/popup-nas.conf" /root/popup-nas.conf.before-test
  echo "Backed up your popup-nas.conf to /root/popup-nas.conf.before-test"
fi

export UPDATE_BRANCH="$BRANCH"
BASE="https://raw.githubusercontent.com/PsyMan2000/popup-nas/$BRANCH/autorun"
mkdir -p /tmp/picktest
for f in selfupdate display fleet populate build menu; do
  curl -fsSL "$BASE/lib/$f.sh" -o "/tmp/picktest/$f.sh" || { echo "Download of $f.sh failed - check the network."; exit 1; }
  # shellcheck disable=SC1090
  source "/tmp/picktest/$f.sh"
done
curl -fsSL "$BASE/fleet-broadcast.py" -o /tmp/picktest/fleet-broadcast.py || { echo "Download of fleet-broadcast.py failed."; exit 1; }

pull_update_now() {
  whiptail --msgbox "Option 9 is switched off while testing, so the stick can't be moved onto the test branch by accident." 9 62
}

if [ "${2:-}" = nosrm ]; then
  find_srm() { return 0; }
  echo "TEST MODE: this session pretends the stick has no popup-nas.srm."
fi

NAME="${1:-$(hostname)}"
pkill -f "fleet-broadcast\.py" 2>/dev/null || true
python3 /tmp/picktest/fleet-broadcast.py "$NAME" "$FLEET_PORT" "$SHARE_MOUNT" "$FLEET_STATE" "$(cd "$HERE/.." && pwd)" "$(channel_name)" >/tmp/popup-fleet.log 2>&1 &
main_menu "$NAME"
