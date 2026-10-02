# Architecture — pop-up SMB relief shares

Status: 2026-10-02. Real-hardware boot confirmed working end-to-end, including after the CRLF/git-clone fix. The wiped-disk share path (no existing NTFS partition) is confirmed working on a real external SSD, including reversing it back to blank. The NTFS-shrink path (a disk that already has Windows on it) hasn't been proven out yet — see "Next steps". A built `popup-nas.iso` has since booted correctly from Proxmox on real Linux machines, confirming the self-contained ISO path works. Sticks are now self-updating against this repo's `stable` branch — see "Self-updating sticks" below — not yet tested on real hardware.

This is the public distribution repo. Development happens on a separate private repo; this repo's `stable` branch is only updated deliberately, once a change is trusted (see "Self-updating sticks" below for why).

## The scenario

A lot of PCs get imaged at once over PXE or USB into Ninja One's imaging tool, pulling the master image from a central NAS over SMB. Under heavy load that NAS can become the bottleneck. This tool turns spare PCs on the same LAN into temporary "relief" SMB share points carrying a copy of the master image, so imaging traffic can be spread across several sources.

## Decisions locked in

- **Base:** [SystemRescue](https://www.system-rescue.org/) (Arch-based rescue live distro), booted with `copytoram` so it runs fully from RAM — the USB stick is free to reuse within seconds of boot completing. Chosen over building a custom Debian/Ubuntu live-boot pipeline because SystemRescue already solves toram booting, broad hardware/driver support, and ships the partition tools (`parted`, `ntfs-3g`, `gptfdisk`) this needs, out of the box.
- **Customisation mechanism:** SystemRescue's own [autorun](https://www.system-rescue.org/manual/Run_your_own_scripts_with_autorun/) folder for the scripts, plus one [SRM module](https://www.system-rescue.org/Modules/) (`popup-nas.srm`) built once for anything not already on the stock image (Samba, git, at minimum). No custom ISO build, no live-build pipeline to maintain — the stock SystemRescue ISO is never modified directly; see "Building a self-contained ISO" below for an optional way to bake everything into one file instead.
- **Default boot options via `sysrescue.d/`, not a hand-edited boot menu.** SystemRescue reads `.yaml` files in a `sysrescue.d` folder on the boot device and applies them as default boot options for both BIOS and UEFI boot ([docs](https://www.system-rescue.org/manual/Configuring_SystemRescue/)). `sysrescue.d/200-popup-nas.yaml` sets `copytoram: true` and `loadsrm: true`, so staff imaging PCs just pick the stick and press Enter — no editing a GRUB/isolinux line by hand every single boot, which would have been a real trip hazard for anyone not comfortable with boot menus.
- **No persistence between boots, by design.** Every boot is a clean session: hostname is asked fresh each time, nothing about identity is baked in or needs regenerating from a previous run.
- **No DHCP/PXE server, no Cockpit.** Out of scope for this version on purpose — this tool does one job (temporary SMB relief share) and nothing else.
- **Reversibility is partition-table-driven, not state-file-driven.** The new share partition is labelled `POPUP-SHARE`. To reverse, the tool finds that label and either grows the NTFS partition it was shrunk from back to fill the space, or — if it was set up on a wiped disk with no NTFS partition — wipes the disk's partition table back to blank. **Confirmed working** on a real external SSD (whole-disk setup, then reversal back to blank).
- **The stick's own data partition needs no special preparation or custom label — and its stock SystemRescue label (e.g. `RESCUE1302`) must NOT be changed.** `autorun0` finds its own files by content, not by name; SystemRescue's own boot process depends on finding that stock label, so changing it breaks the boot entirely.
- **Share setup handles both NTFS and wiped/blank disks.** If the chosen disk has an NTFS partition, it's shrunk. If it has none at all, the tool offers to use the *whole* disk as the share instead — no NTFS involved at all. As of 2026-10-02, real target PCs for this project are confirmed to always arrive wiped, so proving out the NTFS-shrink path has been deprioritised — the whole-disk path is the one actually in use.
- **All text files in the repo are forced to Unix (LF) line endings via `.gitattributes`.**
- **Two ways to build a stick: write directly to a device, or build one self-contained ISO first.** `scripts/make-stick.sh` writes straight to a plugged-in device. `build/make-iso.sh` bakes `autorun/`, `sysrescue.d/`, and the SRM module directly into a rebuilt `popup-nas.iso`. A third way exists too: building live, from the menu of an already-running popup-nas box.
- **Sticks are self-updating against this public repo's `stable` branch.** See "Self-updating sticks" below for the full design and why it's a separate repo/branch from day-to-day development.

## What happens on boot

1. Wait briefly for a network address.
2. Check for updates against `stable`, and restart with the new version if one was found (see "Self-updating sticks").
3. Ask for a name for this box (shown on screen and used as its Samba/NetBIOS name).
4. Start the fleet broadcast/listener.
5. Drop into a menu: show status screen / set up the share / fill the share with the master image / reverse partitioning / shell / reboot / power off / make more sticks.

## Self-updating sticks

Rather than a manual workflow (`git pull` on a separate PC, then re-copy `autorun/`/`sysrescue.d/` onto every stick by hand), a stick can pull its own updates directly. Two design decisions make this safe:

**A public repo, separate from development.** Development happens on a private repo. This repo is public, holds nothing but source and docs (no credentials of any kind), and is what sticks actually pull from — a stick running unattended in the field has no business holding a token/deploy-key for a private repo, and GitHub serves a public repo's contents over plain HTTPS with no authentication needed at all.

**A `stable` branch, not the live development branch.** A stick fetching from whatever's currently being worked on would risk picking up a half-tested change mid-imaging-event, with no warning. This repo's `stable` branch only gets updated deliberately — a normal CI/CD-style promotion step, just applied to a USB stick instead of a server.

**How it actually works, mechanically** (see `autorun/lib/selfupdate.sh`):

- A stick made via `scripts/make-stick.sh`, or via the live "Make more sticks" menu option, is a real `git clone` of this repo's `stable` branch — not a plain file copy. `.git` ends up sitting at the root of the stick's data partition, alongside `autorun/` and `sysrescue.d/` as tracked folders.
- Right after `wait_for_network` and before the hostname prompt, `autorun0` calls `self_update()`. It fetches `origin/stable` and does a `git merge --ff-only` — deliberately never anything that could produce a merge conflict or rewrite history, just a plain fast-forward or nothing at all.
- If the fast-forward actually moved `HEAD`, the stick restarts itself (`exec bash "$HERE/autorun0"`) so the just-pulled code takes over cleanly.
- **A gotcha specific to this feature:** the partition `$HERE` lives on is very often mounted **read-only** by this point (SystemRescue typically doesn't leave it mounted read-write once it's been found by the fallback partition scan). A `git fetch`/`merge` needs to write to `.git`, so `self_update()` first checks writability and, if needed, remounts the specific mountpoint `$HERE` is under (found via `findmnt`, not assumed) read-write with `mount -o remount,rw`. If even that fails, self-update is skipped for that boot rather than erroring.
- Everything about this is best-effort and silently safe: no git installed, no `.git` folder (an old-style plain-copy stick), no network reachable, a read-only drive that won't remount, or a history that won't fast-forward cleanly — any of these just leaves the stick exactly as it already was and it boots normally. Nothing about self-update can ever block or brick a boot.
- Scope: this only ever updates what's tracked in the repo (the scripts, the yaml, the docs) — never `popup-nas.srm` (a compiled binary artifact, rebuilt by hand when the package list changes) and never `autorun/popup-nas.conf` (real per-site NAS credentials, deliberately gitignored so a pull can never overwrite it with the blank example).
- Both "make more sticks" build functions clone fresh from `stable` rather than copying whatever's running on the current box — so a new stick always carries the officially-promoted version and starts out already wired up to self-update. If the clone can't reach the network, they fall back to copying the current box's own files, just without self-update on the result. Either way, the current box's real `popup-nas.conf` is carried over onto the new stick.
- **Note:** `git` needs to be part of the `popup-nas.srm` package bundle for self-update to work at all (see `build/README.md`) — on a stick whose SRM module predates this feature, self-update just quietly skips itself with a one-line message rather than erroring.

**Not yet tested on real hardware** — next thing to check is specifically the read-only-remount path above, since that's the one part of this with no direct precedent elsewhere in the project.

## Setting up the share (the risky part — be honest about it)

- **Disk has an NTFS partition:** pick it, `ntfsresize --info` to check what's actually safe to free up, confirm with the operator, `ntfsresize --size` to shrink the filesystem, `parted resizepart` to match the partition table, `parted mkpart` to create the new partition in the freed space, format it ext4 labelled `POPUP-SHARE`, mount it, and point Samba at it. **Not yet tested on real hardware or in a VM, and currently deprioritised.**
- **Disk has no NTFS partition (wiped/blank, or never Windows):** after a clear confirmation, wipe any existing partition table, create a single partition spanning the whole disk, format it ext4 labelled `POPUP-SHARE`, mount it, and point Samba at it. **Confirmed working**, including reversal, on a real external SSD, and is the path actually used in production.

## Building a self-contained ISO

`build/make-iso.sh` wraps SystemRescue's own `sysrescue-customize` tool to produce `popup-nas.iso` — a rebuilt copy of the stock ISO with `autorun/`, `sysrescue.d/`, and the SRM module already baked in. **Confirmed boot-tested** as of 2026-10-02 — an ISO built this way has booted correctly from Proxmox on real Linux machines. This script always builds from the local checkout it's run from (the developer-focused build path, for testing a change before promoting it); the live in-menu "Make more sticks" option is the one that pulls from `stable`.

## Filling the share

- **Default:** pull from a NAS path configured in `autorun/popup-nas.conf` (baked onto the stick, editable per site).
- **Manual:** enter a different source path on the spot if the default doesn't apply.

Use a dedicated, read-only NAS account for this, not an admin credential.

## Making the share discoverable

- **Other popup-nas boxes** ("the fleet"): a UDP broadcast (every ~5s, port 47500) every box sends and listens for, showing a live list of the others (name, IP, free space, current SMB connection count), alongside its own row. Broadcast traffic doesn't cross routed subnets/VLANs — single-site/classroom network only.
- **Windows/WinPE imaging clients**: Samba's `nmbd` (NetBIOS naming + browsing). NetBIOS/SMB1-style browsing is disabled by default on many modern Windows/WinPE builds, so the fallback that always works is typing `\\<ip-address>\share` directly — which is why the status display puts the IP address front and centre.

## What's built so far

- `autorun/autorun0` + `autorun/lib/*.sh` — network wait, self-update check, hostname prompt, menu, partition setup/reverse, Samba config, fleet broadcast, status screen.
- `autorun/lib/selfupdate.sh` — pulls `stable` at every boot; see "Self-updating sticks" above.
- `autorun/fleet-broadcast.py` — the UDP broadcast/listen daemon.
- `autorun/popup-nas.conf.example` — per-site defaults, copied to `popup-nas.conf` and edited before duplicating sticks.
- `sysrescue.d/200-popup-nas.yaml` — sets `copytoram`/`loadsrm` as default boot options.
- `.gitattributes` / `.gitignore` — LF line endings, and real credentials/build artifacts kept out of git.
- `build/README.md` — how to build `popup-nas.srm`, and (optionally) a self-contained ISO.
- `build/make-iso.sh` — builds `popup-nas.iso` with everything baked in.
- `scripts/make-stick.sh` — writes a complete, ready-to-boot stick.

## Open items

- Exact default share size / whether to always ask, or offer quick presets.
- Whether `figlet` is worth the extra SRM package weight.
- No auto-balancing between relief shares — staff decide manually, using the fleet view.
- Custom boot-loader splash screen/background — parked for now.

## Next steps

1. Test self-update on real hardware — specifically the read-only-remount path above.
2. Test the "Make more sticks" submenu producing a self-updating stick/ISO end to end.
3. If an NTFS-shrink test is ever needed later: test in a disposable VM with an NTFS virtual disk, then once on real disposable NTFS hardware.
4. Test the fleet broadcast with two or more sticks on the same network segment.
5. Test visibility from an actual Ninja One WinPE boot image.
