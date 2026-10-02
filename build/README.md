# Building the popup-nas SRM module, and (optionally) a self-contained ISO

SystemRescue supports adding extra packages via an "SRM" module — a squashfs
overlay you build once on a running SystemRescue system, then reuse on every
USB stick. This avoids needing our own live-build pipeline.

## Step 1: build the SRM module (do this once, reuse the result on every stick)

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
