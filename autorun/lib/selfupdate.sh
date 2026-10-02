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
#     scripts, fleet-broadcast.py, the sysrescue.d yaml, docs.
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

  echo -n "Checking for updates..."

  if ! ensure_writable "$repo_root"; then
    echo " this stick's drive is read-only right now - skipping (continuing with what's already on it)."
    return 0
  fi

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
