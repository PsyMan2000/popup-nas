# Filling the share with master images (.wim files) or any other files, and
# the NAS settings that go with it.
#
# The flow (menu option 3):
#   1. Pick a SOURCE: the upstream NAS, another popup-nas on this network
#      that already has files, a USB drive plugged into this box, or a
#      path typed by hand.
#   2. The source is mounted read-only. Its .wim files are listed with their
#      sizes: tick the ones this box needs. If the source holds other files
#      too, there is one extra question first (see choose_copy_mode): the
#      .wim images as before (the default - just press Enter), pick any
#      files from a list, or "sync" = copy everything that is new or changed.
#      COPY_MODE=wim|all|sync in popup-nas.conf answers that question in
#      advance. Nothing is ever deleted from the share.
#   3. A free-space check, then each ticked file is copied into the share.
#      A copy that is interrupted (a 350 GB file takes a while) carries on
#      from where it stopped when run again - it does not start over.
#
# Rules that other parts of popup-nas rely on:
#   - Each file is copied under a hidden name, .NAME.<size>-<time>.part, and
#     renamed to its real name only when it is complete. So a .wim with its
#     real name on the share is always a finished one, and everything here
#     (and the fleet announcement in fleet-broadcast.py) ignores names
#     starting with ".". The size and time in the hidden name mean a source
#     file that has changed since is never "continued" from an old
#     half-copy. (rsync --append does the continuing: it only reads the
#     missing tail of the source, which matters when the source is a NAS.
#     The more usual --partial-dir would NOT resume here: with a mounted
#     source rsync sees two local folders, copies whole files, and ignores
#     the half-copy.)
#   - Sub-folders on the source are kept on the share, so two files with
#     the same name in different folders can't overwrite each other. Normal
#     use is .wim files at the root, where nothing changes.
#   - No extra verification pass is run (it would double the time on a
#     350 GB file). That is safe because of the next rule:
#   - Before a half-finished copy is carried on, the LAST 16 MiB of it is cut
#     off and copied again (trim_part_tail). Found 2026-10-07 with plain
#     rsync: when rsync is stopped part-way (Ctrl+C, or the network drops)
#     the last 256 KiB it wrote can be wrong, and --append trusts what is
#     already there - so the finished file had one bad block, and everything
#     reported success. (Seen in about 1 stop in 6.)

IMAGE_MOUNT="/mnt/source"
# How many characters of each image's file name are shown on the status
# screen (the IMAGES column), so staff can tell the images apart and number
# them. fleet-broadcast.py has its own copy of this number - change both.
IMAGE_NAME_CHARS=8
MOUNT_ERR=""
PICKED_LABEL=""

# ---------------------------------------------------------------- helpers

# "45.3 GB" from a number of bytes.
fmt_gb() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f GB", b/1e9}'
}

# Strips leading and trailing whitespace from $1.
trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Lists the finished .wim files under folder $1, one per line:
#   <size in bytes><TAB><path relative to $1>
# Looks up to 4 levels deep. Hidden files and folders (names starting with
# ".") are skipped: that is where rsync keeps half-finished copies.
# -mindepth 1 matters: without it the starting "." itself would match the
# hidden-name rule and nothing would ever be listed.
list_wims() {
  ( cd "$1" 2>/dev/null && find . -mindepth 1 -maxdepth 4 -name '.*' -prune -o -type f -iname '*.wim' -printf '%s\t%P\n' 2>/dev/null | sort -t "$(printf '\t')" -k2 )
}

# Lists the finished files of ANY type under folder $1, one per line:
#   <size in bytes><TAB><path relative to $1>
# $2 = how many levels deep to look (default 4). Same rules as list_wims:
# hidden names (rsync's half-finished copies) are skipped. Also skipped:
# folders that are never wanted data - lost+found (every ext4 share has one)
# and the Windows System Volume Information and $RECYCLE.BIN.
list_files() {
  local depth="${2:-4}"
  ( cd "$1" 2>/dev/null && find . -mindepth 1 -maxdepth "$depth" \( -name '.*' -o -name 'lost+found' -o -name 'System Volume Information' -o -name '$RECYCLE.BIN' \) -prune -o -type f -printf '%s\t%P\n' 2>/dev/null | sort -t "$(printf '\t')" -k2 )
}

# One-line summary of the images on THIS box's share, for the status
# screen's IMAGES column: the first few characters of each image's name
# (without ".wim"), then the total size, e.g. "Win11-Pr,Win10-Ed (45.3 GB)".
# More than 3 images shows the first 3 then "+N". "none" if there are none.
# fleet_table in lib/fleet.sh builds the same text for the other popups.
share_image_summary() {
  list_wims "$SHARE_MOUNT" | awk -F'\t' -v w="$IMAGE_NAME_CHARS" -v max=3 '
    { n++; s += $1; p = $2; sub(/.*\//, "", p); sub(/\.[wW][iI][mM]$/, "", p); names[n] = substr(p, 1, w) }
    END {
      if (!n) { print "none"; exit }
      out = ""
      for (i = 1; i <= n && i <= max; i++) out = out (i > 1 ? "," : "") names[i]
      if (n > max) out = out ",+" (n - max)
      printf "%s (%.1f GB)\n", out, s / 1e9
    }'
}

# How much of the end of a half-finished copy is thrown away before it is
# carried on (see the rules at the top). Re-copying 16 MiB takes a fraction
# of a second.
PART_TAIL_CUT=$((16 * 1024 * 1024))

# Cuts the last PART_TAIL_CUT bytes off half-finished copy $1 (all of it, if
# it is smaller than that), so the copy is carried on from a part that is
# certainly right.
trim_part_tail() {
  local part="$1" size
  size=$(stat -c %s "$part" 2>/dev/null) || return 0
  if [ "$size" -gt "$PART_TAIL_CUT" ]; then
    truncate -s $(( size - PART_TAIL_CUT )) "$part"
  else
    : > "$part"
  fi
}

# The hidden name an unfinished copy of source file $1 (path relative to the
# source) is kept under on the share - see the rules at the top.
part_path() {
  local rel="$1" dir base
  dir=$(dirname "$SHARE_MOUNT/$rel")
  base=$(basename "$rel")
  echo "$dir/.$base.$(stat -c '%s-%Y' "$IMAGE_MOUNT/$rel").part"
}

unmount_source() {
  mountpoint -q "$IMAGE_MOUNT" 2>/dev/null && umount "$IMAGE_MOUNT" 2>/dev/null
  return 0
}

# Mounts an SMB share read-only on $IMAGE_MOUNT.
#   $1 = //server/share   $2 = user (empty or "guest" = no login)   $3 = password
# The password goes in through a temporary credentials file, NOT on the
# command line: a password containing a comma would otherwise be cut short
# by mount's own option parsing. On failure MOUNT_ERR holds mount's message.
mount_cifs_source() {
  local unc="$1" user="$2" pass="$3" cred opts rc
  unmount_source
  mkdir -p "$IMAGE_MOUNT"
  if [ -z "$user" ] || [ "$user" = "guest" ]; then
    opts="guest,ro"
    cred=""
  else
    cred=$(mktemp /run/popup-cred.XXXXXX 2>/dev/null || mktemp /tmp/popup-cred.XXXXXX) || { MOUNT_ERR="couldn't make a temporary file"; return 1; }
    chmod 600 "$cred"
    printf 'username=%s\npassword=%s\n' "$user" "$pass" > "$cred"
    opts="credentials=$cred,ro"
  fi
  # timeout: an unreachable server would otherwise make this wait for ages.
  MOUNT_ERR=$(timeout 25 mount -t cifs "$unc" "$IMAGE_MOUNT" -o "$opts" 2>&1)
  rc=$?
  [ -n "$cred" ] && rm -f "$cred"
  [ "$rc" -eq 124 ] && MOUNT_ERR="no answer from the server within 25 seconds"
  return "$rc"
}

# Mounts the NAS from the current popup-nas.conf settings.
mount_nas_source() {
  mount_cifs_source "${MASTER_IMAGE_SMB_PATH:-}" "${MASTER_IMAGE_USER:-}" "${MASTER_IMAGE_PASS:-}"
}

# Another popup-nas box: its share allows guests, so no login is needed.
mount_peer_source() {
  mount_cifs_source "//$1/share" "guest" ""
}

# A USB drive (or any block device): read-only, so nothing on it can be
# changed or left "dirty" by being unplugged afterwards.
mount_device_source() {
  local dev="$1" existing
  unmount_source
  mkdir -p "$IMAGE_MOUNT"
  existing=$(findmnt -no TARGET "$dev" 2>/dev/null | head -n1)
  if [ -n "$existing" ]; then
    MOUNT_ERR=$(mount --bind "$existing" "$IMAGE_MOUNT" 2>&1) && MOUNT_ERR=$(mount -o remount,bind,ro "$IMAGE_MOUNT" 2>&1)
  else
    MOUNT_ERR=$(mount -o ro "$dev" "$IMAGE_MOUNT" 2>&1)
  fi
}

# Whatever was typed by hand: //server/share (uses the NAS login from
# popup-nas.conf) or a folder on this machine.
mount_typed_source() {
  local path="$1"
  if [[ "$path" == //* ]]; then
    mount_cifs_source "$path" "${MASTER_IMAGE_USER:-}" "${MASTER_IMAGE_PASS:-}"
  elif [ -d "$path" ]; then
    unmount_source
    mkdir -p "$IMAGE_MOUNT"
    MOUNT_ERR=$(mount --bind "$path" "$IMAGE_MOUNT" 2>&1) && MOUNT_ERR=$(mount -o remount,bind,ro "$IMAGE_MOUNT" 2>&1)
  else
    MOUNT_ERR="$path isn't a folder on this machine"
    return 1
  fi
}

# Other popup-nas boxes seen on the network that have at least one file.
# One line each:  name|ip|image count|image GB|connections|image names|file count|file GB
# (file count = files of any type, .wim images included. A popup running an
# older version doesn't report it, so its image count is used instead.)
list_peer_sources() {
  python3 - "$FLEET_STATE" <<'PYEOF'
import json, sys, time
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
now = time.time()
for name, info in sorted(data.items()):
    if now - info.get("seen", 0) >= 30:
        continue
    n = info.get("images") or 0
    f = info.get("files")
    if f is None:
        f = n
    if not n and not f:
        continue
    names = ",".join(info.get("image_names") or [])
    print("|".join(str(x) for x in (name, info.get("ip", ""), n, info.get("images_gb", 0), info.get("connections", 0), names, f, info.get("files_gb", info.get("images_gb", 0)))))
PYEOF
}

# USB drives plugged into this box that could hold images. One line each:
#   device|size in bytes|label|filesystem
# Never lists the stick this box booted from, nor the disk its own share
# lives on, so the wrong drive can't be picked by mistake. Done in python
# so an odd drive label can never be run as a command.
list_usb_sources() {
  local own_src share_src
  own_src=$(findmnt -T "$HERE" -no SOURCE 2>/dev/null)
  share_src=""
  mountpoint -q "$SHARE_MOUNT" 2>/dev/null && share_src=$(findmnt -T "$SHARE_MOUNT" -no SOURCE 2>/dev/null)
  lsblk -J -b -p -o NAME,TYPE,TRAN,FSTYPE,SIZE,LABEL 2>/dev/null | python3 -c '
import json, sys
own, share = sys.argv[1], sys.argv[2]
try:
    tree = json.load(sys.stdin).get("blockdevices", [])
except Exception:
    tree = []
SKIP_FS = {"swap", "LVM2_member", "crypto_LUKS", "linux_raid_member", "iso9660"}
def names(node):
    yield node["name"]
    for c in node.get("children") or []:
        yield from names(c)
for disk in tree:
    if disk.get("tran") != "usb" or disk.get("type") != "disk":
        continue
    all_names = set(names(disk))
    if (own and own in all_names) or (share and share in all_names):
        continue
    parts = disk.get("children") or [disk]
    for p in parts:
        fs = p.get("fstype")
        if not fs or fs in SKIP_FS:
            continue
        label = (p.get("label") or "").replace("|", "/")
        print("|".join(str(x) for x in (p["name"], p.get("size") or 0, label, fs)))
' "$own_src" "$share_src"
}

# --------------------------------------------------------- the main flow

# Menu option 3. $1 = "nas" skips the source picker and goes straight to
# the NAS (used right after the NAS settings are changed).
populate_share() {
  local preselect="${1:-}"
  if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
    whiptail --msgbox "Set up the share first (menu option 2) before filling it." 10 60
    return
  fi

  local source_label=""
  if [ "$preselect" = "nas" ]; then
    if ! mount_nas_source; then
      whiptail --msgbox "Couldn't connect to the NAS (${MASTER_IMAGE_SMB_PATH:-not set}):\n\n$(printf '%s' "$MOUNT_ERR" | head -n 2 | fold -s -w 70)\n\nUse 'Change the NAS settings' in the menu to fix the path or login." 16 76
      return
    fi
    source_label="the NAS"
  else
    pick_source || return
  fi
  # pick_source leaves the chosen source mounted on $IMAGE_MOUNT and its
  # description in $PICKED_LABEL.
  [ -n "$source_label" ] || source_label="$PICKED_LABEL"

  copy_files_from_source "$source_label"
  unmount_source
}

# Shows the source picker. Returns 0 with the chosen source mounted on
# $IMAGE_MOUNT (description in PICKED_LABEL), or 1 if cancelled / failed.
pick_source() {
  local -a kinds args menu_items
  local i n line name ip cnt gb conn inames fcnt fgb desc dev size label fs choice
  while true; do
    kinds=(); args=(); menu_items=()
    n=0

    # 1. the upstream NAS (always first)
    n=$((n + 1)); kinds[$n]="nas"
    if [ -n "${MASTER_IMAGE_SMB_PATH:-}" ]; then
      menu_items+=("$n" "NAS: ${MASTER_IMAGE_SMB_PATH}")
    else
      menu_items+=("$n" "NAS: not set up yet - choose this to set it up")
    fi

    # 2. other popups that already have files
    while IFS='|' read -r name ip cnt gb conn inames fcnt fgb; do
      [ -n "$name" ] || continue
      n=$((n + 1)); kinds[$n]="peer"; args[$n]="$ip"
      if [ "${cnt:-0}" -gt 0 ]; then
        desc="${inames:-$cnt image(s)} - ${gb} GB"
        [ "${fcnt:-$cnt}" -gt "$cnt" ] && desc="$desc (+$(( fcnt - cnt )) files)"
      else
        desc="${fcnt:-0} file(s) - ${fgb:-0} GB"
      fi
      menu_items+=("$n" "Popup $name ($ip): $desc, $conn connected")
    done < <(list_peer_sources)

    # 3. USB drives plugged into this box
    while IFS='|' read -r dev size label fs; do
      [ -n "$dev" ] || continue
      n=$((n + 1)); kinds[$n]="usb"; args[$n]="$dev"
      menu_items+=("$n" "USB: $dev - $(fmt_gb "$size")${label:+ \"$label\"} ($fs)")
    done < <(list_usb_sources)

    # 4. a hand-typed path, and a refresh
    n=$((n + 1)); kinds[$n]="typed"
    menu_items+=("$n" "Type a different path (//server/share or a folder)")
    n=$((n + 1)); kinds[$n]="refresh"
    menu_items+=("$n" "Look again (just plugged something in?)")

    choice=$(whiptail --title "Where are the files coming from?" \
      --menu "Pick a source. Other popups and USB drives show up here by themselves." \
      $((n + 8 > 22 ? 22 : n + 8)) 78 "$((n > 14 ? 14 : n))" "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

    case "${kinds[$choice]}" in
      refresh) continue ;;
      nas)
        if [ -z "${MASTER_IMAGE_SMB_PATH:-}" ]; then
          # The editor tests the new settings and itself offers to go
          # on and pick images, so the picker just ends here.
          edit_nas_settings
          return 1
        fi
        whiptail --infobox "Connecting to the NAS..." 7 50
        if ! mount_nas_source; then
          whiptail --msgbox "Couldn't connect to the NAS (${MASTER_IMAGE_SMB_PATH:-not set}):\n\n$(printf '%s' "$MOUNT_ERR" | head -n 2 | fold -s -w 70)\n\nPick another source, or use 'Change the NAS settings' in the menu." 16 76
          continue
        fi
        PICKED_LABEL="the NAS"
        return 0 ;;
      peer)
        whiptail --infobox "Connecting to ${args[$choice]}..." 7 50
        if ! mount_peer_source "${args[$choice]}"; then
          whiptail --msgbox "Couldn't connect to ${args[$choice]}:\n\n$(printf '%s' "$MOUNT_ERR" | head -n 2 | fold -s -w 70)" 12 76
          continue
        fi
        PICKED_LABEL="popup ${args[$choice]}"
        return 0 ;;
      usb)
        if ! mount_device_source "${args[$choice]}"; then
          whiptail --msgbox "Couldn't open ${args[$choice]}:\n\n$(printf '%s' "$MOUNT_ERR" | head -n 3 | fold -s -w 70)" 14 76
          continue
        fi
        PICKED_LABEL="USB drive ${args[$choice]}"
        return 0 ;;
      typed)
        local typed
        typed=$(whiptail --inputbox "Enter the source: an SMB path like //nas-server/masterimages (uses the NAS login from the settings), or a folder on this machine:" 11 76 3>&1 1>&2 2>&3) || continue
        typed=$(trim_spaces "${typed//\\//}")
        [ -n "$typed" ] || continue
        if ! mount_typed_source "$typed"; then
          whiptail --msgbox "Couldn't open $typed:\n\n$(printf '%s' "$MOUNT_ERR" | head -n 2 | fold -s -w 70)" 12 76
          continue
        fi
        PICKED_LABEL="$typed"
        return 0 ;;
    esac
  done
}

# "33 MB/s" from bytes per second.
fmt_speed() {
  awk -v b="${1:-0}" 'BEGIN{ if (b >= 1e9) printf "%.1f GB/s", b/1e9; else printf "%.0f MB/s", b/1e6 }'
}

# "about 18 min" / "about 2 h 40 min" from a number of seconds.
fmt_left() {
  awk -v s="${1:-0}" 'BEGIN{
    if (s < 60) { print "under 1 min"; exit }
    m = int((s + 59) / 60)
    if (m < 60) printf "about %d min", m
    else printf "about %d h %02d min", int(m / 60), m % 60
  }'
}

# Prints (printf style) on the real screen. On the stick's own console and
# in a VM console, this script's normal output goes through a pipe, and a
# progress line that rewrites itself with a carriage return came out as one
# new line every few seconds there (seen on real VMs 2026-10-06). So the copy
# screen writes straight to the terminal device found by badge_tty_dev
# (lib/display.sh), the same way the channel badge does, and falls back to
# plain output if there isn't one.
copy_say() {
  if [ -n "${COPY_DEV:-}" ] && { printf "$@" > "$COPY_DEV"; } 2>/dev/null; then
    return 0
  fi
  printf "$@"
}

# Draws (over the same screen line) how far the copy has got. Called every
# couple of seconds while rsync runs in the background. The speed is worked
# out from the last 30 seconds of real progress, so it follows a network
# that speeds up or slows down. For the first 20 seconds it says it is
# still working the time out, because the very first seconds are not
# typical (connection start-up, caches). Uses these variables, set by
# copy_wims_from_source: COPY_START (epoch seconds), COPY_TOTAL (bytes to
# copy in this run), COPY_DONE_BASE (bytes of earlier files this run) and
# the sample lists COPY_T / COPY_B.
#   $1 = hidden part file being written   $2 = bytes it already held at start
copy_progress_line() {
  local part="$1" have="$2" now cur got pct dt db speed text
  now=$(date +%s)
  cur=$(stat -c %s "$part" 2>/dev/null || echo "$have")
  got=$(( COPY_DONE_BASE + cur - have ))
  [ "$got" -lt 0 ] && got=0
  COPY_T+=("$now"); COPY_B+=("$got")
  while [ "${#COPY_T[@]}" -gt 2 ] && [ $(( now - COPY_T[0] )) -gt 30 ]; do
    COPY_T=("${COPY_T[@]:1}"); COPY_B=("${COPY_B[@]:1}")
  done
  pct=0
  [ "$COPY_TOTAL" -gt 0 ] && pct=$(( got * 100 / COPY_TOTAL ))
  if [ $(( now - COPY_START )) -lt 20 ]; then
    text="working out the time left..."
  else
    dt=$(( now - COPY_T[0] )); db=$(( got - COPY_B[0] ))
    if [ "$dt" -gt 0 ] && [ "$db" -gt 0 ]; then
      speed=$(( db / dt ))
      text="$(fmt_speed "$speed")  $(fmt_left $(( (COPY_TOTAL - got) / speed ))) left"
    else
      text="nothing moving for a while - is the source still reachable?"
    fi
  fi
  copy_say '\r\033[K  %s of %s  (%d%%)  %s' "$(fmt_gb "$got")" "$(fmt_gb "$COPY_TOTAL")" "$pct" "$text"
}

# Waits up to 2 seconds between progress updates. While the copy runs the
# terminal's own Ctrl+C handling is switched off (see copy_wims_from_source),
# because on the stick's console and in a VM console the Ctrl+C signal also
# reaches the program that launched this menu, which then ends and drops the
# operator at a bare root prompt (seen on real VMs 2026-10-06). So Ctrl+C
# arrives here as an ordinary key press instead: Ctrl+C, Q or Esc asks the
# copy to stop (COPY_STOP=1). With no terminal device it just sleeps.
copy_wait_key() {
  local key="" t0=$SECONDS
  if [ -n "${COPY_DEV:-}" ] && [ -r "$COPY_DEV" ]; then
    IFS= read -r -s -n 1 -t 2 key < "$COPY_DEV" 2>/dev/null
    case "$key" in
      $'\003'|q|Q|$'\033') COPY_STOP=1; return 0 ;;
    esac
    # If the read came back at once (nothing to read, or a key we ignore),
    # still wait, so the loop never spins.
    [ $(( SECONDS - t0 )) -ge 1 ] || sleep 1
  else
    sleep 2
  fi
}

# A quick, non-blocking look for the stop key (Ctrl+C, Q or Esc) - used
# BETWEEN files, so a long run of small files, each too quick to ever reach
# copy_wait_key, can still be stopped.
copy_check_stop() {
  local key=""
  { [ -n "${COPY_DEV:-}" ] && [ -r "$COPY_DEV" ]; } || return 0
  IFS= read -r -s -n 1 -t 0.05 key < "$COPY_DEV" 2>/dev/null
  case "$key" in
    $'\003'|q|Q|$'\033') COPY_STOP=1 ;;
  esac
  return 0
}

# Copies source file $1 into the hidden part file $2 with rsync running in
# the background, drawing the progress line while it runs. Ctrl+C (or Q)
# stops the copy cleanly (the part file stays, so it can be continued) and returns
# 130. rsync's own messages go to /tmp/popup-copy.log.
#   $3 = bytes the part file already held (see copy_progress_line)
copy_one_file() {
  local src="$1" part="$2" have="$3" pid rc
  COPY_STOP=0
  rsync --times --append "$src" "$part" 2>>/tmp/popup-copy.log &
  pid=$!
  # Small files are finished within a fraction of a second: look quickly
  # first, so they don't each wait for a whole progress tick (copying a
  # folder of 1000 small files would otherwise take half an hour longer).
  local k
  for k in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$COPY_STOP" -eq 1 ]; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      copy_say '\n'
      return 130
    fi
    copy_progress_line "$part" "$have"
    copy_wait_key
  done
  wait "$pid"; rc=$?
  [ "$rc" -eq 0 ] && copy_progress_line "$part" "$have"
  copy_say '\n'
  return "$rc"
}

# True if file $1 (path relative to the source, $2 = its size) is already on
# the share, finished. $3 = "strict" also compares the modification time:
# rsync --times gives a copy the same time as its source, so a finished copy
# always matches, and a changed source file doesn't. Used by "sync".
file_already_here() {
  local rel="$1" size="$2" strict="${3:-}" dsize
  dsize=$(stat -c %s "$SHARE_MOUNT/$rel" 2>/dev/null) || return 1
  [ "$dsize" = "$size" ] || return 1
  if [ "$strict" = strict ]; then
    [ "$(stat -c %Y "$SHARE_MOUNT/$rel" 2>/dev/null)" = "$(stat -c %Y "$IMAGE_MOUNT/$rel" 2>/dev/null)" ] || return 1
  fi
  return 0
}

# Asks what to copy from a source that holds other files besides .wim
# images. Echoes wim, all or sync; returns 1 if cancelled. Item 1 (the
# images, as before) is pre-selected, so just pressing Enter changes
# nothing; with no .wim files at all, item 2 is.
#   $1 = description of the source   $2 = how many .wim files it has
choose_copy_mode() {
  local label="$1" n_wim="$2" def=1 choice
  [ "$n_wim" -eq 0 ] && def=2
  choice=$(whiptail --title "What to copy from $label?" --default-item "$def" \
    --menu "There are other files here as well as .wim images. What do you want?" 14 78 3 \
    "1" "Pick .wim images (the usual choice)" \
    "2" "Pick any files from a list (every file type)" \
    "3" "Copy EVERYTHING new or changed (sync, deletes nothing)" 3>&1 1>&2 2>&3) || return 1
  case "$choice" in
    2) echo all ;;
    3) echo sync ;;
    *) echo wim ;;
  esac
}

# With a source mounted on $IMAGE_MOUNT: list its files, let the operator
# choose what to take, check there's room, and copy them.
#   wim  = the .wim images, ticked from a list (the original behaviour)
#   all  = files of any type, ticked from a list
#   sync = no list: everything on the source that is missing here or has
#          changed (a different size or time); files already here, and files
#          that only exist on the share, are left alone
# $1 = a short description of the source, for messages.
copy_files_from_source() {
  local label="$1" mode="wim" noun="images" depth=4 strict="" skipped=0
  local -a w_size w_path menu_items sel_idx=()
  local size path shown i count=0 state note avail needed=0 sel n_sel=0 listing n_wim n_all have what

  n_wim=$(list_wims "$IMAGE_MOUNT" | wc -l)
  n_all=$(list_files "$IMAGE_MOUNT" | wc -l)
  case "${COPY_MODE:-}" in
    wim|all|sync) mode="$COPY_MODE" ;;
    *) if [ "$n_all" -gt "$n_wim" ]; then mode=$(choose_copy_mode "$label" "$n_wim") || return; fi ;;
  esac
  case "$mode" in
    all)  noun="files"; strict=strict ;;
    sync) noun="files"; strict=strict; depth=8 ;;
  esac

  while IFS=$'\t' read -r size path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    w_size[$count]="$size"; w_path[$count]="$path"
  done < <(if [ "$mode" = wim ]; then list_wims "$IMAGE_MOUNT"; else list_files "$IMAGE_MOUNT" "$depth"; fi)

  if [ "$count" -eq 0 ]; then
    listing=$(ls -1 "$IMAGE_MOUNT" 2>/dev/null | head -n 8 | tr '\n' ' ')
    if [ "$mode" = wim ]; then
      whiptail --msgbox "No .wim files found on $label (looked up to 4 folders deep).\n\nWhat is there: ${listing:-nothing visible}" 12 76
    else
      whiptail --msgbox "No files found on $label (looked up to $depth folders deep).\n\nWhat is there: ${listing:-nothing visible}" 12 76
    fi
    return
  fi
  if [ "$mode" = all ] && [ "$count" -gt 300 ]; then
    whiptail --msgbox "$count files is too many to tick one by one.\n\nGo back and choose 'Copy EVERYTHING new or changed', or use 'Type a different path' to pick a smaller folder." 12 72
    return
  fi
  if [ "$mode" = sync ] && [ "$count" -gt 5000 ]; then
    whiptail --msgbox "$count files is too many to sync in one go (the limit is 5000).\n\nUse 'Type a different path' to pick a smaller folder, and do it in pieces." 12 72
    return
  fi

  avail=$(df --output=avail -B1 "$SHARE_MOUNT" 2>/dev/null | tail -n1 | tr -d ' ')

  if [ "$mode" = sync ]; then
    # No list to tick: take everything that is missing or changed.
    whiptail --infobox "Comparing $count file(s) with this share..." 7 60
    for i in $(seq 1 "$count"); do
      if file_already_here "${w_path[$i]}" "${w_size[$i]}" strict; then
        skipped=$((skipped + 1))
      else
        sel_idx+=("$i")
      fi
    done
    if [ "${#sel_idx[@]}" -eq 0 ]; then
      whiptail --msgbox "Everything on $label is already on this share and up to date ($count file(s) checked). Nothing to copy." 9 72
      return
    fi
  else
    # Each row reads:  <size>  [already here] <path>. The size comes first and
    # long paths are shortened from the LEFT (the file name is the useful end),
    # so nothing important is ever pushed past the edge of the box.
    for i in $(seq 1 "$count"); do
      state="ON"; note=""; shown="${w_path[$i]}"
      if file_already_here "${w_path[$i]}" "${w_size[$i]}" "$strict"; then
        state="OFF"; note="[already here] "
      fi
      [ "${#shown}" -gt 38 ] && shown="...${shown: -35}"
      menu_items+=("$i" "$(printf '%9s' "$(fmt_gb "${w_size[$i]}")")  $note$shown" "$state")
    done
    sel=$(whiptail --title "Tick the $noun to copy from $label" \
      --checklist "Space bar ticks or unticks. This share has $(fmt_gb "${avail:-0}") free." \
      $((count + 9 > 22 ? 22 : count + 9)) 78 "$((count > 13 ? 13 : count))" "${menu_items[@]}" 3>&1 1>&2 2>&3) || return
    for i in ${sel//\"/}; do
      sel_idx+=("$i")
    done
  fi

  # What is needed: the full size of each chosen file, less any unfinished
  # copy of it already on the share (that part will be continued, not redone).
  for i in "${sel_idx[@]}"; do
    have=$(stat -c %s "$(part_path "${w_path[$i]}")" 2>/dev/null || echo 0)
    needed=$((needed + w_size[i] - have))
    n_sel=$((n_sel + 1))
  done
  if [ "$n_sel" -eq 0 ]; then
    whiptail --msgbox "Nothing was ticked, so nothing was copied." 8 50
    return
  fi

  # Leave 1 GB spare so the share never fills to the brim.
  if [ "$needed" -gt $(( ${avail:-0} - 1000000000 )) ]; then
    whiptail --msgbox "Not enough room.\n\nStill to copy: $(fmt_gb "$needed")\nFree on this share: $(fmt_gb "${avail:-0}")\n\nUntick something, or use menu option 2 to give the share more space." 14 70
    return
  fi

  if [ "$mode" = sync ]; then
    what="Sync: copy $n_sel new or changed file(s), $(fmt_gb "$needed") still to copy ($skipped already up to date), from $label to this share?\n\nNothing on this share is deleted or renamed."
  else
    what="Copy $n_sel file(s), $(fmt_gb "$needed") still to copy, from $label to this share?"
  fi
  whiptail --yesno "$what\n\nThe time left is worked out from the real speed once the copy has been running for about 20 seconds, and shown on the screen as it goes.\n\nPress Ctrl+C (or Q) to stop it. Run it again and it carries on from where it stopped." 17 74 || return

  COPY_DEV=""
  declare -F badge_tty_dev >/dev/null && COPY_DEV=$(badge_tty_dev) || true
  if [ -n "$COPY_DEV" ]; then clear > "$COPY_DEV" 2>/dev/null || clear; else clear; fi
  # Take Ctrl+C away from the terminal for the length of the copy, so it
  # arrives as a key press (see copy_wait_key) and can not end the menu.
  COPY_STTY=""
  if [ -n "$COPY_DEV" ]; then
    COPY_STTY=$(stty -g < "$COPY_DEV" 2>/dev/null) && stty -isig -echo < "$COPY_DEV" 2>/dev/null || COPY_STTY=""
  fi
  copy_say 'Copying from %s to %s ...\n' "$label" "$SHARE_MOUNT"
  copy_say 'Total to copy: %s.  Press Ctrl+C (or Q) to stop - it carries on later.\n' "$(fmt_gb "$needed")"
  : > /tmp/popup-copy.log
  local n_done=0 rel dst part old failed="" stopped="" rc=0 now
  COPY_START=$(date +%s); COPY_TOTAL="$needed"; COPY_DONE_BASE=0
  COPY_T=("$COPY_START"); COPY_B=(0); COPY_STOP=0
  trap 'COPY_STOP=1' INT
  for i in "${sel_idx[@]}"; do
    rel="${w_path[$i]}"
    dst="$SHARE_MOUNT/$rel"
    part=$(part_path "$rel")
    n_done=$((n_done + 1))
    copy_check_stop
    if [ "$COPY_STOP" -eq 1 ]; then stopped="$rel"; break; fi
    copy_say '\n[%s of %s] %s\n' "$n_done" "$n_sel" "$rel"
    mkdir -p "$(dirname "$dst")"
    # Half-copies of an OLDER version of this same file are no use any more.
    for old in "$(dirname "$dst")/.$(basename "$dst")."*.part; do
      [ -e "$old" ] && [ "$old" != "$part" ] && rm -f "$old"
    done
    [ -e "$part" ] && trim_part_tail "$part"
    have=$(stat -c %s "$part" 2>/dev/null || echo 0)
    copy_one_file "$IMAGE_MOUNT/$rel" "$part" "$have"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      mv -f "$part" "$dst" || rc=1
    fi
    if [ "$rc" -eq 130 ]; then stopped="$rel"; break; fi
    if [ "$rc" -ne 0 ]; then failed="$rel"; break; fi
    COPY_DONE_BASE=$(( COPY_DONE_BASE + w_size[i] - have ))
  done
  trap - INT
  [ -n "$COPY_STTY" ] && stty "$COPY_STTY" < "$COPY_DEV" 2>/dev/null
  # What this copy made is owned by root; open it up so people connecting
  # over SMB can add to, edit and delete it.
  if declare -F share_fix_permissions >/dev/null; then share_fix_permissions "$SHARE_MOUNT"; fi

  now=$(date +%s)
  if [ -n "$stopped" ]; then
    whiptail --msgbox "Stopped. Nothing is lost: choose the same source again and it will carry on from where it stopped." 9 70
  elif [ -z "$failed" ]; then
    local secs=$(( now - COPY_START )) avg=0
    [ "$secs" -gt 0 ] && avg=$(( COPY_DONE_BASE / secs ))
    whiptail --msgbox "Copy finished: $n_sel file(s), $(fmt_gb "$COPY_DONE_BASE") in $(( (secs + 59) / 60 )) minute(s), average $(fmt_speed "$avg").\n\nThe other popups on this network will see these files in their list within a few seconds." 12 70
  else
    whiptail --msgbox "The copy stopped at $failed (code $rc). Nothing is lost: choose the same source again and it will carry on from where it stopped.\n\nWhat rsync said:\n$(tail -n 3 /tmp/popup-copy.log | cut -c1-66)" 17 72
  fi
}

# The name older code and the tests use for the same thing.
copy_wims_from_source() { copy_files_from_source "$@"; }

# ------------------------------------------------------- NAS settings

# Sets VAR='value' in the conf file $1, replacing an existing VAR= line
# (any duplicates are dropped) or adding one at the end. Comments and every
# other line are left alone. The value is single-quoted with embedded
# single quotes escaped, because popup-nas.conf is read as a shell script:
# a password containing $ ` " or ' would otherwise break it or run code.
conf_set() {
  local file="$1" var="$2" val="$3" esc tmp line found=0
  esc=${val//\'/\'\\\'\'}
  tmp=$(mktemp) || return 1
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$var="*)
          if [ "$found" -eq 0 ]; then printf "%s='%s'\n" "$var" "$esc"; found=1; fi ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$file" > "$tmp"
  fi
  [ "$found" -eq 1 ] || printf "%s='%s'\n" "$var" "$esc" >> "$tmp"
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# Menu option 10: change the NAS path / user / password, test them, save
# them on the stick, and (if they work) offer to pick images straight away.
# Returns 0 if the new settings work and are in use, 1 otherwise.
edit_nas_settings() {
  local conf="$HERE/popup-nas.conf" new_path new_user new_pass choice
  local cur_path="${MASTER_IMAGE_SMB_PATH:-//nas-server/masterimages}"
  local cur_user="${MASTER_IMAGE_USER:-}"
  local cur_pass="${MASTER_IMAGE_PASS:-}"
  local count gb saved_msg

  while true; do
    new_path=$(whiptail --title "NAS settings (1 of 3)" --inputbox \
      "Where are the master images? Type the NAS path, e.g. //nas-server/masterimages (a Windows path with backslashes also works):" 12 76 "$cur_path" 3>&1 1>&2 2>&3) || return 1
    new_path=$(trim_spaces "${new_path//\\//}")
    if ! [[ "$new_path" =~ ^//[^/]+/.+ ]]; then
      whiptail --msgbox "That doesn't look like a NAS path. It needs to look like //server/share (two slashes, the server, a slash, the share name)." 10 70
      cur_path="$new_path"
      continue
    fi
    new_user=$(whiptail --title "NAS settings (2 of 3)" --inputbox \
      "User name for the NAS. Leave it empty if the NAS needs no login (guest):" 10 70 "$cur_user" 3>&1 1>&2 2>&3) || return 1
    new_user=$(trim_spaces "$new_user")
    new_pass=$(whiptail --title "NAS settings (3 of 3)" --inputbox \
      "Password for the NAS (shown as you type, to make typing it quicker and safer to get right):" 10 70 "$cur_pass" 3>&1 1>&2 2>&3) || return 1

    whiptail --infobox "Testing the connection to $new_path ..." 7 66
    if mount_cifs_source "$new_path" "$new_user" "$new_pass"; then
      count=$(list_wims "$IMAGE_MOUNT" | wc -l)
      gb=$(list_wims "$IMAGE_MOUNT" | awk -F'\t' '{s+=$1} END{printf "%.1f GB", s/1e9}')
      unmount_source
      # Use the new settings from now on, in this session...
      MASTER_IMAGE_SMB_PATH="$new_path"; MASTER_IMAGE_USER="$new_user"; MASTER_IMAGE_PASS="$new_pass"
      # ...and keep them on the stick for next time, if it can be written.
      if ensure_writable "$HERE" 2>/dev/null && [ -w "$HERE" ]; then
        conf_set "$conf" MASTER_IMAGE_SMB_PATH "$new_path"
        conf_set "$conf" MASTER_IMAGE_USER "$new_user"
        conf_set "$conf" MASTER_IMAGE_PASS "$new_pass"
        saved_msg="Saved on the stick."
      else
        saved_msg="NOT saved: the stick can not be written to right now (a built ISO, or the stick is out), so these settings last until you reboot."
      fi
      if [ "$count" -gt 0 ]; then
        whiptail --yesno "Connected. Found $count .wim file(s), $gb. $saved_msg\n\nPick which images to copy to this share now?" 12 72 && populate_share nas
      else
        whiptail --msgbox "Connected, but no .wim files were found there (looked up to 4 folders deep). $saved_msg" 11 72
      fi
      return 0
    fi

    choice=$(whiptail --title "Couldn't connect" --menu "$new_path\n\n$(printf '%s' "$MOUNT_ERR" | head -n 2 | fold -s -w 70)" 18 76 3 \
      "1" "Change the settings and try again" \
      "2" "Keep these settings anyway (e.g. the NAS isn't plugged in yet)" \
      "3" "Cancel - leave everything as it was" 3>&1 1>&2 2>&3) || return 1
    case "$choice" in
      1) cur_path="$new_path"; cur_user="$new_user"; cur_pass="$new_pass" ;;
      2)
        MASTER_IMAGE_SMB_PATH="$new_path"; MASTER_IMAGE_USER="$new_user"; MASTER_IMAGE_PASS="$new_pass"
        if ensure_writable "$HERE" 2>/dev/null && [ -w "$HERE" ]; then
          conf_set "$conf" MASTER_IMAGE_SMB_PATH "$new_path"
          conf_set "$conf" MASTER_IMAGE_USER "$new_user"
          conf_set "$conf" MASTER_IMAGE_PASS "$new_pass"
          whiptail --msgbox "Saved on the stick (not tested)." 8 50
        else
          whiptail --msgbox "Using these until you reboot. NOT saved: the stick can not be written to right now (a built ISO, or the stick is out)." 10 66
        fi
        return 1 ;;
      *) return 1 ;;
    esac
  done
}
