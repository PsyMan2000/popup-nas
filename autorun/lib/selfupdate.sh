# Self-updating sticks: pull the latest "stable" version of popup-nas
# straight from its public GitHub repo, right at boot, before anything else
# runs. This is what replaces the old manual "git pull on your PC, then
# re-copy autorun/ and sysrescue.d/ onto the stick by hand" step - the
# stick now does that part itself.
#
# How "stable" works: day-to-day development happens elsewhere. This
# repo's "stable" branch is only updated deliberately, when a change is
# actually trusted - sticks never pull an in-progress or untested change.
# This mirrors a normal CI/CD promotion step, just applied to a USB stick
# instead of a server.
#
# Scope - what this does and doesn't touch:
#   - DOES update: everything tracked in this repo - the autorun/
#     scripts, fleet-broadcast.py, the sysrescue.d yaml, docs, VERSION.
#   - Does NOT touch popup-nas.srm, the compiled package bundle (Samba
#     etc). That's a binary build artifact, not source code - it still
#     needs rebuilding by hand (build/README.md) if the package list ever
#     changes.
#   - Does NOT touch autorun/popup-nas.conf, your real per-site NAS
#     credentials. That file is deliberately excluded from git (see
#     .gitignore) specifically so a pull can never overwrite your real
#     settings with the blank example file.
#
# Only works on a stick that was actually made as a git checkout of this
# repo (see autorun/lib/build.sh and scripts/make-stick.sh) - a stick made
# the old plain-file-copy way has no .git folder, so this quietly does
# nothing on those rather than erroring.

DEFAULT_UPDATE_REPO_URL="https://github.com/PsyMan2000/popup-nas.git"
DEFAULT_UPDATE_BRANCH="stable"

update_repo_url() { echo "${UPDATE_REPO_URL:-$DEFAULT_UPDATE_REPO_URL}"; }
update_repo_branch() { echo "${UPDATE_BRANCH:-$DEFAULT_UPDATE_BRANCH}"; }

# The "channel" this stick follows, in capitals, for the traffic-light
# banner on the menu / status screen and the CHANNEL column of the fleet
# table: the branch it self-updates from (stable, stage, dev, test-...).
# "NO GIT" for a stick that isn't a git checkout, because those never
# self-update whatever popup-nas.conf says.
channel_name() {
  # Answer from the boot-time snapshot if main_menu() took one (see there):
  # asking git again after the stick has been pulled out would wrongly say
  # "NO GIT".
  if [ -n "${CHANNEL_NAME_CACHE:-}" ]; then echo "$CHANNEL_NAME_CACHE"; return 0; fi
  local repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "NO GIT"
    return 0
  fi
  update_repo_branch | tr '[:lower:]' '[:upper:]'
}

# Echoes "LABEL|colour" for the banner. Colour is green (stable), amber
# (stage/staging/beta/rc), red (anything else: dev, test-..., v2, ...) or
# grey (not a git checkout). The same rule is repeated in fleet_table() in
# lib/fleet.sh - change both together. Edits to tracked files push the
# colour from green to amber and are spelled out in the label, because
# they make `git merge --ff-only` refuse, so the stick silently stops
# updating (found on real hardware 2026-10-05).
channel_info() {
  # Same boot-time snapshot rule as channel_name above.
  if [ -n "${CHANNEL_INFO_CACHE:-}" ]; then echo "$CHANNEL_INFO_CACHE"; return 0; fi
  local name colour repo_root label
  name=$(channel_name)
  case "$name" in
    "NO GIT") echo "NO GIT - WON'T SELF-UPDATE|grey"; return 0 ;;
    STABLE) colour=green ;;
    STAGE|STAGING|BETA|RC) colour=amber ;;
    *) colour=red ;;
  esac
  label="$name"
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  if [ -n "$(pinned_commit)" ]; then
    label="$label - PINNED, NO AUTO-UPDATE"
    [ "$colour" = green ] && colour=amber
  fi
  if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    label="$label + LOCAL CHANGES (UPDATES BLOCKED)"
    [ "$colour" = green ] && colour=amber
  fi
  echo "$label|$colour"
}

# This checkout's current git commit, short form ("-" if there isn't one).
# Same boot-time snapshot rule as channel_name above (POPUP_COMMIT_CACHE).
popup_commit() {
  if [ -n "${POPUP_COMMIT_CACHE:-}" ]; then echo "$POPUP_COMMIT_CACHE"; return 0; fi
  local repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "-"
}

# True if the stick this box booted from is still plugged in. Looks at the
# block device behind $HERE's mount rather than reading files from it,
# because a stick that has just been pulled out can still answer "does this
# file exist?" from the kernel's cache, but its device node (/dev/sdX1) is
# gone. Used by the menu to explain, instead of failing confusingly, when
# an option that needs the stick (8 and 9) is chosen after it was removed.
stick_present() {
  local src
  src=$(findmnt -T "$HERE" -no SOURCE 2>/dev/null) || return 1
  [ -b "$src" ]
}

# Remounts $1's filesystem read-write if it's currently read-only (common
# on real hardware - see autorun0's scan_all_partitions, which deliberately
# mounts read-only while it's still just looking for its own folder).
# Works out the actual mountpoint itself via findmnt, rather than assuming
# any particular path, since $HERE can end up under several different
# mountpoints depending on how this machine's autorun scan found it.
ensure_writable() {
  local path="$1" mnt
  [ -w "$path" ] && return 0
  mnt=$(findmnt -T "$path" -no TARGET 2>/dev/null) || return 1
  mount -o remount,rw "$mnt" 2>/dev/null
  [ -w "$path" ]
}

# Clones this repo's update branch into $1 (which must not already exist).
# Used both by self_update() below and by the "Make more sticks" build
# functions in build.sh, so every path that creates or updates a stick
# agrees on exactly where "the latest stable version" comes from. Returns
# non-zero (quietly - caller decides what to tell the operator) if git is
# missing, there's no network, or the clone fails for any other reason.
clone_update_repo() {
  local dest="$1"
  command -v git >/dev/null 2>&1 || return 1
  GIT_TERMINAL_PROMPT=0 timeout 30 git clone --quiet --branch "$(update_repo_branch)" --single-branch "$(update_repo_url)" "$dest" >/tmp/popup-clone.log 2>&1
}

# This checkout's version NUMBER (the VERSION file, e.g. "1.5.1"), or "" if it
# can't be read. Shown after the commit in the status screen's VER column.
# Same boot-time snapshot rule as popup_commit (POPUP_NUMBER_CACHE).
popup_number() {
  if [ -n "${POPUP_NUMBER_CACHE:-}" ]; then echo "$POPUP_NUMBER_CACHE"; return 0; fi
  local repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  [ -f "$repo_root/VERSION" ] && tr -d '[:space:]' < "$repo_root/VERSION"
  return 0
}

# Reads this checkout's VERSION file (a plain X.Y.Z string, bumped by hand
# whenever a change is worth calling out) plus its current git commit
# short-hash, and returns them combined as one display string, e.g.
# "v1.0.0 (2831762)". Used anywhere popup-nas shows its own version to the
# operator (the main menu's title, the status screen). Falls back
# gracefully if either piece is missing - a stick made the old
# plain-file-copy way (no VERSION file, no .git) just shows whichever
# part it has, or "-" if it has neither, rather than failing.
popup_version() {
  # Same boot-time snapshot rule as channel_name above.
  if [ -n "${POPUP_VERSION_CACHE:-}" ]; then echo "$POPUP_VERSION_CACHE"; return 0; fi
  local repo_root ver_file version hash
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  ver_file="$repo_root/VERSION"
  version=""
  [ -f "$ver_file" ] && version=$(tr -d '[:space:]' < "$ver_file")
  hash=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "")
  if [ -n "$version" ] && [ -n "$hash" ]; then
    echo "v$version ($hash)"
  elif [ -n "$version" ]; then
    echo "v$version"
  elif [ -n "$hash" ]; then
    echo "$hash"
  else
    echo "-"
  fi
}

# ---- Version pin: "stay on this version, do not auto-update" ----
# A stick is PINNED when autorun/popup-nas.pin exists and holds a git commit
# that this stick has. While pinned, the boot-time self-update does nothing,
# so a stick that was rolled back to a good version stays there.
#
# Pinning ALSO points the stick's "origin" at a path that does not exist.
# That is what keeps an OLDER version (one from before this pin feature, e.g.
# 1.5.1) from updating itself straight back to the latest at the next boot:
# its own self_update fetches from "origin", fails, and carries on with what
# is on the stick. This code never fetches from "origin", it always uses the
# real address (update_repo_url), so it still works while pinned.
PIN_DEAD_URL="/popup-nas-pinned-auto-update-is-off"

pin_file() { echo "$HERE/popup-nas.pin"; }

# Echoes the pinned commit (full hash) if this stick is pinned to a commit
# it has; echoes nothing otherwise. A pin file naming a commit the stick
# doesn't have is ignored (the stick then updates normally).
pinned_commit() {
  local f repo_root c
  f=$(pin_file)
  [ -s "$f" ] || return 0
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)" || return 0
  c=$(tr -d '[:space:]' < "$f")
  [ -n "$c" ] || return 0
  git -C "$repo_root" cat-file -e "${c}^{commit}" 2>/dev/null || return 0
  git -C "$repo_root" rev-parse "${c}^{commit}" 2>/dev/null
}

# Pins the stick to commit $1: writes the pin file and kills "origin".
pin_set() {
  local repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)" || return 1
  printf '%s\n' "$1" > "$(pin_file)" || return 1
  git -C "$repo_root" remote set-url origin "$PIN_DEAD_URL" 2>/dev/null || true
}

# Turns the pin off: removes the pin file and gives "origin" its real
# address back.
pin_clear() {
  local repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)" || return 1
  rm -f "$(pin_file)"
  git -C "$repo_root" remote set-url origin "$(update_repo_url)" 2>/dev/null || true
}

# Called once per boot, right after the network comes up and before the
# hostname prompt. Best-effort and silent-safe throughout: anything that
# isn't a clean fast-forward just leaves the stick exactly as it already
# was and carries on into the normal menu - a flaky connection or a
# conflicted history can never stop this stick from booting.
self_update() {
  local repo_root before after short_before short_after

  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)" || return 0
  command -v git >/dev/null 2>&1 || { echo "Self-update: git isn't installed on this stick - skipping."; return 0; }
  [ -d "$repo_root/.git" ] || return 0

  before=$(pinned_commit)
  if [ -n "$before" ]; then
    echo "Self-update is OFF: this stick is pinned to $(echo "$before" | cut -c1-7) (menu option 9 changes that)."
    return 0
  fi

  echo -n "Checking for updates..."

  if ! ensure_writable "$repo_root"; then
    echo " this stick's drive is read-only right now - skipping (continuing with what's already on it)."
    return 0
  fi

  # The boot media this repo lives on is normally FAT/exFAT (deliberately
  # - so it works with any PC's BIOS/UEFI and can be written from Windows
  # too), and FAT can't store real Unix file permissions at all. Mounted
  # under Linux, every file's permission bits come out as whatever the
  # mount's own default is, not whatever was actually committed to git -
  # so git sees a permission-only difference on nearly every tracked file
  # and calls it a "local modification", which blocks the fast-forward
  # merge below even though not one byte of real content has changed.
  # Confirmed on real hardware 2026-10-02: this alone silently stopped
  # self-update (and the "Pull latest update now" menu item) from ever
  # applying a real, available update, while still reporting "already up
  # to date" - because that's genuinely what git itself was reporting as
  # the merge's failure reason. Telling git to ignore file mode entirely
  # is the standard fix for a checkout living on FAT/exFAT/NTFS, and is
  # safe and cheap to (re-)apply on every single run.
  git -C "$repo_root" config core.fileMode false

  before=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")
  if ! GIT_TERMINAL_PROMPT=0 timeout 10 git -C "$repo_root" fetch --quiet origin "$(update_repo_branch)" >/tmp/popup-update.log 2>&1; then
    echo " couldn't reach $(update_repo_url) - continuing with what's already on this stick."
    return 0
  fi
  if ! git -C "$repo_root" merge --ff-only --quiet "origin/$(update_repo_branch)" >>/tmp/popup-update.log 2>&1; then
    echo " update didn't apply cleanly - continuing with what's already on this stick (see /tmp/popup-update.log)."
    return 0
  fi
  after=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")

  if [ -n "$after" ] && [ "$before" != "$after" ]; then
    short_before=$(echo "$before" | cut -c1-7)
    short_after=$(echo "$after" | cut -c1-7)
    echo " updated ($short_before -> $short_after). Restarting with the new version..."
    # A brief, non-interactive confirmation - no keypress needed, and it
    # disappears on its own once the next screen draws. Mainly here so an
    # actual update is obvious while deliberately testing self-update,
    # rather than a line of text that scrolls past in under a second.
    whiptail --infobox "Self-update: pulled a new version.\n\n$short_before -> $short_after\n\nRestarting with the new version..." 11 60
    sleep 3
    exec bash "$HERE/autorun0"
  fi
  echo " already up to date."
}

# Restarts the whole popup program (after the stick changed version). A
# function so the tests can replace it.
restart_popup() { exec bash "$HERE/autorun0"; }

# Short description of commit $1 for the picker: "5d6ba76 1.5.1  2026-10-06  subject".
describe_commit() {
  local repo_root="$1" c="$2" v d subj
  v=$(git -C "$repo_root" show "$c:VERSION" 2>/dev/null | tr -d '[:space:]')
  d=$(git -C "$repo_root" log -1 --format=%cs "$c" 2>/dev/null)
  subj=$(git -C "$repo_root" log -1 --format=%s "$c" 2>/dev/null | cut -c1-34)
  printf '%s %-6s %s  %s' "$(echo "$c" | cut -c1-7)" "${v:--}" "$d" "$subj"
}

# Menu option 9: the version picker. Shows the versions this stick can go to
# (the last 12 releases of the update branch, newest first), and:
#   L  = go to the latest and turn auto-update back ON (the normal state)
#   S  = stay on this version and turn auto-update OFF
#   a version = roll back (or forward) to it, and stay there (auto-update OFF)
# Never touches popup-nas.conf (not tracked by git) or the share. If the
# network can't be reached it lists the versions the stick already has.
update_picker() {
  local repo_root branch url pin head tip ok=1 title note="" n=0 choice c
  local -a items hashes

  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)" || return 0
  branch=$(update_repo_branch); url=$(update_repo_url)
  if ! command -v git >/dev/null 2>&1 || [ ! -d "$repo_root/.git" ]; then
    whiptail --msgbox "This stick isn't a git checkout, so it can't pick versions or update itself." 9 70
    return 0
  fi
  if ! ensure_writable "$repo_root"; then
    whiptail --msgbox "This stick's drive is read-only right now, so the version can't be changed." 9 70
    return 0
  fi
  git -C "$repo_root" config core.fileMode false

  whiptail --infobox "Looking for versions..." 6 40
  if ! GIT_TERMINAL_PROMPT=0 timeout 15 git -C "$repo_root" fetch --quiet "$url" "+refs/heads/$branch:refs/remotes/origin/$branch" >/tmp/popup-update.log 2>&1; then
    ok=0; note="No network: showing the versions already on this stick. "
  fi
  tip=$(git -C "$repo_root" rev-parse "refs/remotes/origin/$branch" 2>/dev/null || echo "")
  head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")
  pin=$(pinned_commit)

  items+=("L" "Latest $branch - updates itself at every boot (normal)")
  if [ -z "$pin" ]; then
    items+=("S" "Stay on THIS version - turn auto-update off")
  fi
  if [ -n "$tip" ]; then
    while read -r c; do
      [ -n "$c" ] || continue
      n=$((n + 1)); hashes[$n]="$c"
      items+=("$n" "$(describe_commit "$repo_root" "$c")$([ "$c" = "$head" ] && echo ' <- now')")
    done < <(git -C "$repo_root" log --first-parent -n 12 --format=%H "$tip" 2>/dev/null)
  fi

  if [ -n "$pin" ]; then
    title="PINNED to $(echo "$pin" | cut -c1-7): auto-update is OFF"
  else
    title="On $(echo "$head" | cut -c1-7): auto-update is ON"
  fi
  choice=$(whiptail --title "Update or roll back" --menu "${note}${title}\n\nPick a version:" 24 78 14 "${items[@]}" 3>&1 1>&2 2>&3) || return 0

  case "$choice" in
    L)
      pin_clear
      if [ "$ok" -eq 0 ] || [ -z "$tip" ]; then
        whiptail --msgbox "Auto-update is back ON, but there is no network right now, so it could not fetch the latest. It will check at the next boot, or choose this again once the network is up." 11 70
        return 0
      fi
      if [ "$head" = "$tip" ]; then
        whiptail --msgbox "Auto-update is back ON and this stick is already on the latest version. The share this box is serving, if any, is untouched." 10 70
        return 0
      fi
      # Go to exactly the newest release. A reset (not a fast-forward), so it
      # also works from a stick that is on something else - an older release,
      # or a test version - and the choice was made on purpose.
      if ! git -C "$repo_root" reset --hard --quiet "$tip" >/tmp/popup-update.log 2>&1; then
        whiptail --msgbox "Couldn't switch to the latest (see /tmp/popup-update.log). The stick was left as it was." 9 70
        return 0
      fi
      whiptail --infobox "Auto-update is ON. Switched to the latest ($(echo "$tip" | cut -c1-7)). Restarting..." 7 60
      sleep 2
      restart_popup
      ;;
    S)
      pin_set "$head" || { whiptail --msgbox "Couldn't write the pin file on the stick." 8 60; return 0; }
      whiptail --msgbox "Done. This stick will stay on $(echo "$head" | cut -c1-7) and will NOT update itself. Choose 'Latest' here to turn auto-update back on." 11 70
      ;;
    *)
      c="${hashes[$choice]:-}"
      [ -n "$c" ] || return 0
      if [ "$c" = "$head" ] && [ -z "$pin" ]; then
        pin_set "$c"
        whiptail --msgbox "This stick is already on that version. It is now pinned there: auto-update is OFF." 9 70
        return 0
      fi
      whiptail --defaultno --title "Switch version?" --yesno "Switch this stick to:\n\n  $(describe_commit "$repo_root" "$c")\n\nIt will stay on that version and NOT update itself until you choose 'Latest' here.\n\nThe NAS settings and the share are not touched. The menu restarts." 16 74 || return 0
      if ! git -C "$repo_root" reset --hard --quiet "$c" >/tmp/popup-update.log 2>&1; then
        whiptail --msgbox "Couldn't switch (see /tmp/popup-update.log). The stick was left as it was." 9 70
        return 0
      fi
      if [ "$c" = "$tip" ]; then pin_clear; else pin_set "$c"; fi
      whiptail --infobox "Switched to $(echo "$c" | cut -c1-7). Restarting..." 6 50
      sleep 2
      restart_popup
      ;;
  esac
}

# The name menu option 9 had before the picker (kept so nothing that calls
# it breaks).
pull_update_now() { update_picker; }
