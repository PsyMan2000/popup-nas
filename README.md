# popup-deploy-nas — v2: pop-up SMB relief shares

**The problem this solves:** when imaging a lot of PCs at once over PXE/USB into Ninja One, the central NAS serving the master image can become the bottleneck. This tool turns spare PCs on the same LAN into temporary, disposable "relief" SMB shares, so imaging load can be spread across several source points instead of hammering one NAS.

**What it is:** a USB stick that boots a host machine straight to RAM (the stick can be pulled and reused elsewhere within seconds of boot), asks the operator for a name, sets up one of the host's disks to hold a share, copies the master image (or any other files) onto it, and serves it over SMB — visible both to other popup-nas boxes (a live "fleet" list) and, as far as possible, to Windows/WinPE imaging clients browsing the network.

No desktop GUI, no Cockpit, no DHCP/PXE server this time — this version does exactly one job. See `docs/architecture.md` for the full design and honest caveats (there are a few worth reading before you rely on this at a live event).

This is the **public distribution repo**: self-updating sticks pull from this repo's `stable` branch (see "Self-updating sticks" below). Day-to-day development happens elsewhere; this repo only gets updated deliberately, once a change is trusted.

## TLDR: from an Etcher-flashed stick to a test boot

You've already used balenaEtcher to write the official SystemRescue ISO onto a USB stick. Here's exactly what's left to do a first test boot.

1. **Eject the stick from Etcher, then unplug and replug it** so Windows mounts it fresh.
2. **Open File Explorer and find the stick's drive.** It should show SystemRescue's own files/folders (things like `sysresccd`, `boot`, `EFI`). If a "You need to format this disk" popup appears for some *other* new volume Windows noticed on the same stick, click **Cancel** — don't format anything on it.
   - If you can't find any writable drive letter for it at all (Windows only shows it like a read-only CD), stop here — Etcher's raw write may not have left a writable area the easy way, and you'd need SystemRescue's own USB-writer tool instead.
3. **Get this repo's `stable` branch onto your PC.** Easiest way: on this repo's page, click **Code → Download ZIP**, and unzip it somewhere. (Or `git clone --branch stable` it — see "Self-updating sticks" below for why `stable` specifically.)
4. **Copy the `autorun` folder and the `sysrescue.d` folder** (both from the unzipped repo) into the **root** of the SystemRescue drive, so you end up with, for example, `E:\autorun\autorun0`, `E:\autorun\lib\...`, and `E:\sysrescue.d\200-popup-nas.yaml` — none of them nested inside another folder. You don't need to rename the drive itself — whatever label it already has (SystemRescue ships its own, e.g. `RESCUE1302`) is fine and **must not be changed**, or the stick won't boot at all.
5. **Inside `E:\autorun\`, copy `popup-nas.conf.example` to `popup-nas.conf`.** For a first boot test you can leave the placeholder values as they are — you only need real NAS details once you get to testing "fill the share with the master image".
6. **`popup-nas.srm` is optional for this first test.** If you haven't built it yet (see `build/README.md`), that's fine — the stick will still boot and the menu will still run, but Samba/figlet won't be installed yet, so the share/status-banner steps will error out. This first test is really just about confirming it boots to RAM and the menu appears at all. Once you have built it, create a `sysresccd` folder in the same drive root (if it doesn't already exist) and copy `popup-nas.srm` into it.
7. **Safely eject the stick from Windows** ("Safely Remove Hardware", not just pulling it out), then plug it into the PC you're testing on.
8. **Make sure the test PC isn't a very low-spec one.** `copytoram` needs at least 2GB of RAM to load the whole system into memory.
9. **Power on the test PC and get into its one-time boot menu** — tap the key for it repeatedly right after pressing power (commonly `F12`, `F11`, `F9`, `Esc`, or `Delete` depending on the manufacturer) — and choose the USB stick.
10. **At the SystemRescue boot screen, just press Enter on the default entry.** The `sysrescue.d` folder you copied in step 4 sets `copytoram` and `loadsrm` as defaults automatically — you don't need to press `e`/`Tab` and type boot options by hand.
11. **Give it a minute or two** — it's copying the whole system into RAM before it starts anything. Once it's done, you should land straight at a screen asking you to type a name for this box. That means everything above is wired up right.

**If step 11 doesn't happen:**
- Boots to a plain login/shell prompt with no hostname prompt at all: the `autorun` folder probably isn't exactly at the drive root, or the main script isn't named exactly `autorun0`. Check both.
- Boots, shows a `popup-nas: couldn't find its own autorun folder...` message with some disk info dumped out: something else is going on — that output will tell you exactly what partitions it could see.
- Boot fails right at the very start with a `Mounting '/dev/disk/by-label/RESCUEnnnn' ... device did not show up` error, before the menu ever gets a chance to run: the drive's own label has been changed. It **must** stay whatever SystemRescue set it to (e.g. `RESCUE1302`) — check it with `vol E:` in an admin Command Prompt and set it back with `label E: RESCUE1302` if needed.
- Boot fails with `Execution of ...-autorun0 failed: No such file or directory` before it even tries running the script: the files have Windows (CRLF) line endings instead of Unix (LF) ones — usually from a `git clone` on Windows without picking up this repo's `.gitattributes`. Delete your local clone and re-clone fresh, then copy the files over again.

Either way, you don't need to redo the Etcher write — just fix the files on the stick and reboot.

## Self-updating sticks

A stick made via `scripts/make-stick.sh`, or via the live "Make more sticks" menu option on an already-running popup-nas box, is a real `git` checkout of this repo's `stable` branch — not just a plain copy of the files. That means it checks for updates on every single boot, before the hostname prompt, and pulls in anything new automatically (see `autorun/lib/selfupdate.sh`). If a pull succeeds, the stick quietly restarts itself with the new version before anything else happens.

This is deliberately conservative:

- It only ever fast-forwards from `stable` — never from an in-progress development branch. `stable` only gets updated deliberately, once a change is actually trusted, same as a normal release-promotion step.
- If there's no network yet, this repo can't be reached, the stick's drive is read-only, or anything else isn't a clean fast-forward, it just carries on booting with whatever's already on the stick. A bad connection can never stop a stick from working.
- It never touches `popup-nas.srm` (the compiled Samba/etc. package bundle — that's a binary build artifact, not source, and still needs rebuilding by hand if the package list changes) or your real `autorun/popup-nas.conf` (gitignored on purpose, so a pull can never overwrite your real site credentials with the blank example).
- A stick made the old way (a plain file copy, with no `.git` folder) simply doesn't self-update — nothing breaks, it just behaves exactly as it always has.

No credentials of any kind ever need to live on a stick, since this repo is public.

### Rolling back, and turning auto-update off (menu option 9)

Menu option 9 is a version picker. It lists the last 12 releases of `stable` (newest first, each as a short code, version number, date and title) and offers:

- **Latest stable** - the normal state: the stick updates itself at every boot. Choosing it turns auto-update back on and pulls the newest release straight away.
- **Stay on THIS version** - turns auto-update off without changing version.
- **A release from the list** - switches the stick to that release (a rollback, or going forward) and keeps it there with auto-update off.

While a stick is pinned, the menu banner says `PINNED, NO AUTO-UPDATE` in amber and the boot-time update prints `Self-update is OFF`. Pinning also points the stick's `origin` at a path that does not exist, so even an older version of the program (from before this feature) cannot update a pinned stick by accident. The pin is a file, `autorun/popup-nas.pin`, that git ignores; `autorun/popup-nas.conf` and the share are never touched. With no network the picker still lists and switches between the releases the stick already has.

### Setting up the share (menu option 2)

Pick the disk to use. If it has no Windows (NTFS) partition on it, the whole disk becomes the share. If it does have one, you are offered a choice: shrink the Windows partition and keep Windows (not yet tried on real hardware), or **delete all partitions** on the disk and use it whole. The delete route shows every partition that will be destroyed in a red box, and the answer defaults to No. The stick the box booted from can never be chosen. If the box already has a share, setting up again asks first, because it erases what is on it.

The share is open to everyone on the network: anyone can add, edit, move and delete files on it, including whole folders dragged in from a Mac or Windows PC. Security is not a goal of this tool.

### Filling the share (menu option 3)

Pick where the files come from: the NAS, another popup-nas box that already has files, a USB drive plugged into this box, or a path typed by hand. If the source holds files other than `.wim` images, you are asked what to copy:

- **Pick .wim images** (the default; just press Enter) - tick images from a list.
- **Pick any files** - tick files of any type from a list (up to 300 files).
- **Copy everything new or changed (sync)** - no list; copies whatever is missing here or differs in size or time (up to 5000 files). Nothing on the share is ever deleted or renamed.

`COPY_MODE=wim`, `all` or `sync` in `popup-nas.conf` answers that question in advance.

**To stop a copy, press Q on the box's own keyboard** (do not use Ctrl+C there: on the box's console the SystemRescue launcher treats it as "abort the whole program" and drops you to a bare root prompt). A stopped or interrupted copy carries on from where it stopped when you choose the same source again. Each file is copied under a hidden name and renamed only when complete, so a file with its real name on the share is always a finished one, and the last 16 MiB of any half-finished copy is thrown away and redone before continuing.

### A proper shell, and getting back to the menu

Menu option 5 gives a normal interactive shell (prompt, arrow keys, Del); type `exit` to come back. SSH works too: log in as root and run `menu`, which restarts the program from the files already on the stick, so a test version or a version you picked in option 9 stays as it is. `menu fresh` is the old behaviour: it downloads a new copy of `stable` over the stick.

Note for sticks pinned with option 9: the boot-time update step is skipped, so the stick is left read-only. To change files on it by hand over SSH, first run `mount -o remount,rw /mnt/popup-media`.

## Status

First real-hardware boot confirmed working: it boots straight to RAM with no boot-menu editing needed, finds its own scripts, and reaches the working menu. The wiped-disk share path (no existing NTFS partition) has been confirmed working on a real external SSD, including reversing it back to blank. The NTFS-shrink path (a disk that already has Windows on it) is currently deprioritised — see `docs/architecture.md`.

## How it's built

Rather than building its own live-boot Linux from scratch, this rides on [SystemRescue](https://www.system-rescue.org/) — an actively-maintained rescue-style live distro that already boots to RAM (`copytoram`), has broad hardware support, and already bundles the disk/partition tools this needs (parted, ntfs-3g, gptfdisk). Only three things get added on top:

1. **`autorun/`** — the scripts, using SystemRescue's built-in [autorun mechanism](https://www.system-rescue.org/manual/Run_your_own_scripts_with_autorun/), which run automatically after boot.
2. **An SRM module** (`popup-nas.srm`) — a small add-on package (Samba, ntfs-3g, figlet, python — whichever of these aren't already on SystemRescue) built once and reused on every stick. See `build/README.md`.
3. **`sysrescue.d/`** — a small [config file](https://www.system-rescue.org/manual/Configuring_SystemRescue/) that sets `copytoram`/`loadsrm` as defaults, so nobody has to type boot options by hand at the boot menu.

## Making more sticks

- **`scripts/make-stick.sh`** — writes the stock ISO + `autorun/` + `sysrescue.d/` + the SRM module onto a specific USB stick you've got plugged in, one stick at a time. Clones this repo's `stable` branch onto the stick so it's self-updating from its first boot.
- **`build/make-iso.sh`** — builds a single self-contained `popup-nas.iso` with everything already baked in, using SystemRescue's own [`sysrescue-customize`](https://www.system-rescue.org/scripts/sysrescue-customize/) tool. Flash that one file to as many sticks as you like with Rufus/Etcher/dd — no extra copy step needed afterwards — or boot it directly in a VM for testing. See `build/README.md`.
- A third way exists too: the live "Make more sticks" menu option on an already-running popup-nas box, which builds either of the above directly from its own menu.

## Repo layout

- `docs/architecture.md` — full design write-up, decisions, and caveats.
- `autorun/` — the scripts that run on every boot (hostname prompt, menu, partitioning, Samba, fleet broadcast, status screen, self-update).
- `sysrescue.d/` — the config file that makes `copytoram`/`loadsrm` the default boot options.
- `build/README.md` — how to build the one-time `popup-nas.srm` add-on module, and (optionally) a self-contained ISO.
- `build/make-iso.sh` — builds `popup-nas.iso` with `autorun/`, `sysrescue.d/`, and the SRM module already baked in.
- `scripts/make-stick.sh` — writes a complete, ready-to-boot popup-nas USB stick directly from the stock ISO + the SRM module.

## Boot it

Just pick the stick (or `popup-nas.iso` in a VM) at the boot menu and press Enter — `sysrescue.d/200-popup-nas.yaml` sets `copytoram` (load fully into RAM) and `loadsrm` (load the `popup-nas.srm` add-on module) as defaults automatically, no typing required.
