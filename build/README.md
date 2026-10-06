# Building the popup-nas SRM module, and (optionally) a self-contained ISO

SystemRescue supports adding extra packages via an "SRM" module — a squashfs
overlay you build once on a running SystemRescue system, then reuse on every
USB stick. This avoids needing our own live-build pipeline.

## Step 0 (easiest): don't build it - download the published one

The finished module is published as a Release asset on this repo (tag `srm-13.02`, built for SystemRescue 13.02): <https://github.com/PsyMan2000/popup-nas/releases/tag/srm-13.02>. Click `popup-nas.srm` under **Assets** to download it. Keep the file name exactly `popup-nas.srm`.

You don't even need to do that by hand if you use the scripts: `../scripts/make-stick.sh` (leave the `.srm` argument out) and `./make-iso.sh` (write `auto` instead of the `.srm` path) download it for you and check it against its SHA-256 first. The stick's own menu (**Make more sticks**) does the same if the stick it runs on has no `.srm`.

Only continue with Step 1 if the package list changes or SystemRescue is upgraded - see "Publishing a new SRM" at the bottom.

## Step 1: build the SRM module (only needed if the package list or the SystemRescue version changes)

1. Boot SystemRescue (a VM is fine — it doesn't need to be real hardware for this step) with `copytoram`.
2. Install what popup-nas needs. Some of these are probably already on SystemRescue — pacman will just report that and skip them:
   ```
   pacman -Sy --noconfirm samba ntfs-3g figlet python parted gptfdisk git
   ```
3. Package everything pacman just installed into a module:
   ```
   cowpacman2srm popup-nas
   ```
   This produces `popup-nas.srm` (note: it names the file exactly `popup-nas` with no extension - rename it to `popup-nas.srm` before use).
4. Get `popup-nas.srm` off that VM/session (copy it to a USB stick, or upload it somewhere you'll fetch it from) — you only need to build this once and reuse the file for every stick/ISO you make afterwards.

## Step 2 (two options from here)

**Option A — write directly to a stick each time**, using `../scripts/make-stick.sh` with the stock ISO, `autorun/`, and `popup-nas.srm`. Simple, but needs a device plugged in every time you make a new stick.

**Option B — build one self-contained `popup-nas.iso`** with `make-iso.sh`, which already has everything baked in. Better for making several sticks (flash the same file with Rufus/Etcher/dd, no extra copy step needed afterwards) and for booting straight in a VM for testing.

```
./make-iso.sh /path/to/systemrescue.iso /path/to/popup-nas.srm /path/to/popup-nas.iso
```

This wraps SystemRescue's own [`sysrescue-customize`](https://www.system-rescue.org/scripts/sysrescue-customize/) tool, which isn't installed by default outside of SystemRescue itself. To run `make-iso.sh` from Windows, WSL works:

```
sudo apt install xorriso squashfs-tools
```

then download the script itself from SystemRescue's own source repo — currently at:
`https://gitlab.com/systemrescue/systemrescue-sources/-/raw/main/airootfs/usr/share/sysrescue/bin/sysrescue-customize`
— and put it somewhere on your `PATH` (e.g. `/usr/local/bin/`, `chmod +x` it).

**Boot-test the resulting ISO in a VM and confirm it reaches the hostname prompt normally before flashing it to real sticks or trusting it on real hardware** - same caution as everything else in this repo that touches booting.

## Publishing a new SRM (after rebuilding it)

1. On the repo's page: **Releases → Draft a new release**.
2. Tag: `srm-<SystemRescue version>` (e.g. `srm-13.03`), created on publish. Attach the file named exactly `popup-nas.srm`, then publish.
3. Work out its checksum (`sha256sum popup-nas.srm`) and update `DEFAULT_SRM_URL` and `DEFAULT_SRM_SHA256` in `autorun/lib/build.sh`, together with `DEFAULT_SYSRESCUE_ISO_URL` and `DEFAULT_SYSRESCUE_USBWRITER_URL` in the same file (the three must all match one SystemRescue version).
