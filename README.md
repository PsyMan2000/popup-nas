# popup-nas: pop-up SMB relief shares

**The problem this solves:** when you image a lot of PCs at once (PXE or USB, into NinjaOne), the one NAS holding the master image becomes the bottleneck. popup-nas turns spare PCs on the same network into temporary, disposable SMB shares ("relief shares") that hold a copy of the image, so the load is spread over several machines instead of hitting one.

**What it is:** a USB stick. You boot a spare PC from it. The PC loads everything into RAM (so you can pull the stick out again within seconds), asks you to name it, sets up one of its disks as a share, copies the master image onto it, and serves it over SMB. Other popup-nas boxes see it in a live "fleet" list, and Windows/WinPE imaging clients can browse to it.

**What it is built on:** [SystemRescue](https://www.system-rescue.org/), a free rescue Linux that already boots to RAM and already has the disk tools we need. We do not make our own Linux. We add three things on top of a normal SystemRescue stick:

1. `autorun/`: our scripts (the menu, partitioning, Samba, fleet list, self-update).
2. `sysrescue.d/`: one small settings file that makes SystemRescue boot to RAM and load our add-on automatically.
3. `popup-nas.srm`: an add-on module that contains Samba and a few other programs (about 33 MB). It is built once and reused.

There is no desktop, no Cockpit and no DHCP/PXE server. It does one job. Honest caveats are in `docs/architecture.md`; read them before you rely on this at a live event. Security is not a goal: the share is open to everyone on the network.

This is the **public** repo. Sticks update themselves from its `stable` branch (see "Updates" below).

---

## Make your first stick (on Windows)

You need a USB stick of 8 GB or more (everything on it will be erased), an internet connection, and about 15 minutes. Do the steps in order. Wherever it says `E:`, use the drive letter your stick actually gets.

### Part A: put SystemRescue on the stick with Rufus

1. **Download the SystemRescue ISO, version 13.02** from <https://www.system-rescue.org/Download/>. (popup-nas is built for 13.02. A different version can still boot but is not what has been tested.)
2. **Download and open Rufus** from <https://rufus.ie/>. It runs without installing.
3. **Plug in the stick.** In Rufus, set these, top to bottom:
   - **Device:** your stick. Check this carefully, because everything on it is erased.
   - **Boot selection:** click SELECT and choose the SystemRescue ISO.
   - **Partition scheme:** MBR.
   - **Target system:** BIOS or UEFI.
   - **File system:** FAT32.
   - **Volume label:** Rufus fills this in from the ISO and it should read `RESCUE1302`. If it shows something else, type `RESCUE1302`. After the stick is written, **never change it**: SystemRescue will not boot if the label is wrong.
4. **Click START.** When Rufus asks which mode to use, choose **ISO Image mode** (not DD Image mode). This matters: ISO mode leaves the stick writable, which is how we get our files onto it. Click OK, confirm the erase, and wait for READY.
5. **Close Rufus, then unplug the stick and plug it back in.** Windows should show a drive with folders such as `sysresccd`, `boot` and `EFI`. If Windows offers to "format" something, click **Cancel**.

### Part B: add popup-nas

6. **Install Git for Windows** if you do not have it: <https://git-scm.com/download/win>. Accept the default options.
7. **Download popup-nas to your PC.** Open Command Prompt (press the Windows key, type `cmd`, press Enter) and run this exactly. It makes a folder `C:\popup-nas`:

   ```
   git clone --branch stable https://github.com/PsyMan2000/popup-nas.git C:\popup-nas
   ```

   Use `git clone`, not "Download ZIP". The clone includes a hidden `.git` folder, and that folder is what lets the stick update itself. A ZIP has no `.git`, so a stick made from a ZIP never self-updates.
8. **Copy it onto the stick.** Still in Command Prompt, run this (change `E:` to your stick's letter):

   ```
   robocopy C:\popup-nas E:\ /E
   ```

   robocopy copies hidden files too, which File Explorer may skip. When it finishes you should see `autorun`, `sysrescue.d` and `.git` at the top level of the stick, **not** inside another folder. robocopy's exit codes 0 to 7 all mean success.
9. **Add `popup-nas.srm`. You do have to do this by hand.** Nothing on the stick can fetch it for you at boot (see the note below). Go to <https://github.com/PsyMan2000/popup-nas/releases/tag/srm-13.02>, click **popup-nas.srm** under Assets, and save it into the **`sysresccd`** folder on the stick (that folder already exists from Part A). The file name must be exactly `popup-nas.srm`. Right-click it, choose Properties, and check the size is **35,020,800 bytes**.
10. **Optional: your NAS details.** In `E:\autorun\`, make a copy of `popup-nas.conf.example` and name the copy `popup-nas.conf`. Open it in Notepad and fill in the NAS path, user name and password. Use a read-only NAS account, because this file is copied onto every stick you make. You can skip this step for a first test and fill it in later (menu option 10 edits it on the stick).
11. **Safely eject the stick** from Windows (the "Safely Remove Hardware" icon, not just pulling it out).

> **Why is step 9 manual?** SystemRescue loads `popup-nas.srm` in the first seconds of boot, before there is any network and before any of our scripts run, so nothing on the stick can download it at that point. The tools that **build** sticks and ISOs (`scripts/make-stick.sh`, `build/make-iso.sh`, and menu option 8 on a running popup-nas) do download it automatically when it is missing, and check it with a checksum. So you only ever do step 9 by hand when you make the very first stick from Windows. After that, use menu option 8 on a running popup-nas to make more sticks and you will not need to touch the `.srm` again.

### Part C: first boot

12. **Plug the stick into a spare PC** (it needs at least 2 GB of RAM, and a network cable plugged in) and switch it on. Tap the one-time boot menu key straight away (usually `F12`, `F11`, `F9`, `Esc` or `Delete`, depending on the maker) and choose the USB stick.
13. **At the SystemRescue screen, just press Enter.** Our settings file makes it boot to RAM and load the add-on automatically. Do not type anything.
14. **Wait a minute or two.** It copies the whole system into RAM first. Then it checks for updates (if it finds one it restarts itself) and asks you to type a name for this box, for example `Room3-Shelf2`. Type a name and press Enter. You now have the menu. You can pull the stick out once the menu is showing; options 1 to 7 keep working without it.

### If it does not work

- **Plain login prompt, no name question:** `autorun` is probably not at the top level of the stick, or is nested inside another folder. Check step 8.
- **`popup-nas: couldn't find its own autorun folder...` plus a list of disks:** take a photo of the screen. It lists exactly what the PC could see.
- **`Mounting '/dev/disk/by-label/RESCUEnnnn'... did not show up` right at the start:** the drive label was changed. Put it back: in an Administrator Command Prompt run `label E: RESCUE1302` (use the label Rufus originally gave it).
- **`Execution of ...-autorun0 failed: No such file or directory`:** the files have Windows line endings. Delete `C:\popup-nas`, clone it again (step 7) and redo step 8.
- **The menu appears but the share or status screen fails:** `popup-nas.srm` is missing or in the wrong place. Check step 9: it must be at `sysresccd\popup-nas.srm` and 35,020,800 bytes.

You never need to redo Rufus. Just fix the files on the stick and boot again.

### On Linux or a Mac, or once you have one working stick

- On a running popup-nas box, menu option **8 "Make more sticks"** can clone the stick onto a new USB drive, or build an ISO file for a VM. It downloads whatever it needs (including the `.srm`) automatically.
- On a Linux PC, `scripts/make-stick.sh /dev/sdX systemrescue.iso` does the whole job in one go and downloads the `.srm` itself.

---

## Using it: the menu

| Option | What it does |
|---|---|
| 1 | Status screen: name, IP address, and the fleet list of other popup-nas boxes. |
| 2 | Set up the share on one of this PC's disks. |
| 3 | Fill the share with files (images). |
| 4 | Reverse option 2: delete the share and put the disk back to blank. |
| 5 | A shell (command line). Type `exit` to come back. |
| 6 / 7 | Reboot / power off. |
| 8 | Make more sticks (needs the stick in). |
| 9 | Update or roll back (needs the stick in). |
| 10 | Change the NAS settings (needs the stick in). |

Options 1 to 7 work with the stick pulled out. Options 8, 9 and 10 sit under a line in the menu because they need it plugged in.

### Setting up the share (option 2)

Pick the disk to use. If the disk is blank you are asked once. If it has anything on it, Windows included, a **red box** lists every partition that will be destroyed and asks whether to **delete everything and use the whole disk**. The answer defaults to No and there is no undo. To keep Windows on a PC, use a different disk. The stick the box booted from can never be chosen. If the box already has a share, setting up again asks first, because it erases what is on it.

After a reboot or a power cut, the box finds its old share on its disk and shares it again by itself.

The share is open to everyone on the network. Anyone can add, edit, move and delete files on it, including whole folders dragged in from a Mac or Windows PC.

**Opening the share from a PC:** type `\\<IP address>\share` in File Explorer, for example `\\192.168.200.41\share`. The IP address is on the status screen (option 1). The name form, `\\<name>\share`, also works on many PCs, because the box announces its name on the network. But some PCs cannot look names up (for example ones running VPN or overlay-network software, which take over name lookups). The IP address always works, so use it if a name does not open.

### Filling the share (option 3)

Pick where the files come from: the NAS, another popup-nas box that already has files, a USB drive plugged into this box, or a path typed by hand. If the source holds files other than `.wim` images, you are asked what to copy:

- **Pick .wim images** (the default; just press Enter): tick images from a list.
- **Pick any files:** tick files of any type from a list (up to 300 files).
- **Copy everything new or changed (sync):** no list; copies whatever is missing here or different in size or time (up to 5000 files). Nothing on the share is ever deleted or renamed.

Setting `COPY_MODE=wim`, `all` or `sync` in `popup-nas.conf` answers that question in advance.

**To stop a copy, press Q on the box's own keyboard.** Do not use Ctrl+C there: on the box's console it kills the whole program and drops you to a bare prompt. A stopped or interrupted copy carries on from where it stopped when you choose the same source again. Each file is copied under a hidden name and renamed only when complete, so a file with its real name on the share is always a finished one.

### A shell, and the desktop (option 5)

Option 5 gives a normal shell. Type `exit` to come back to the menu. Type `startx` to start the SystemRescue desktop (handy for GParted); close the desktop to get back to the shell.

**If the desktop gets stuck** (Log Out shows "Session manager must be in idle state...", a SystemRescue quirk), log in to the box from another PC over SSH as `root` and type `stopx`. It closes the desktop and the box's own screen goes back to its shell. Type `exit` there to reach the menu.

Over SSH, the command `menu` restarts the popup-nas program from the files already on the stick (so a test version, or a version you picked in option 9, stays as it is). `menu fresh` downloads a new copy of `stable` over the stick instead.

---

## Updates

A stick made as above is a real `git` checkout of the `stable` branch, so at **every boot**, before the name question, it checks GitHub and pulls anything new. If it gets an update it restarts itself with the new version first. This is deliberately cautious:

- It only follows `stable`, which is updated only when a change has been tested on real hardware.
- If there is no network, GitHub cannot be reached, or the stick is read-only, it simply carries on with what is already on the stick. A bad connection can never stop a stick working.
- It never touches `popup-nas.srm` (a binary add-on, not source) or your real `autorun/popup-nas.conf` (kept out of git on purpose, so an update can never overwrite your NAS login with the blank example).
- A stick that has no `.git` folder (for example one made from "Download ZIP") never self-updates. Nothing breaks; it just stays as it is.

No passwords or keys ever need to be on a stick to update, because the repo is public.

### Rolling back or turning updates off (option 9)

Option 9 is a version picker. It lists the last 12 releases of `stable` (newest first) and offers:

- **Latest stable:** the normal state. Turns auto-update back on and updates straight away.
- **Stay on THIS version:** turns auto-update off without changing version.
- **A release from the list:** switches to that release and keeps it there with auto-update off.

While a stick is pinned, the menu banner says `PINNED, NO AUTO-UPDATE` in amber. Your NAS settings and the share are never touched. The pin is a file, `autorun/popup-nas.pin`, that git ignores. Pinned sticks are left read-only; to change a file on one by hand over SSH, first run `mount -o remount,rw /mnt/popup-media`.

ISO files cannot update themselves. When a new version comes out, rebuild your ISOs from an up-to-date stick (option 8, then 1).

---

## Repo layout

- `autorun/`: the scripts that run at every boot (`autorun0` is the entry point; `lib/` holds the menu, partitioning, Samba, fleet, copy and update code).
- `sysrescue.d/`: the settings file that makes boot-to-RAM and the add-on the defaults.
- `scripts/make-stick.sh`: writes a complete stick from Linux (clones `stable`, downloads the `.srm` if you do not pass one).
- `build/`: `make-iso.sh` builds a self-contained `popup-nas.iso`; `build/README.md` explains how the `.srm` is made and published.
- `docs/architecture.md`: the full design, decisions and caveats.

## Status

Confirmed working on real hardware: booting to RAM from a Rufus-made stick, the menu, self-update, rollback, setting up the share on a blank or wiped disk and reversing it, re-attaching a share after a reboot, filling it from the NAS or another popup-nas, cloning a stick from the menu, building an ISO (booted in Proxmox), and downloading the `.srm` when it is missing from a build.

Not yet tested on real hardware: the "delete everything" red box on a disk that has Windows on it (the box itself and whole-disk setup have been tested; the routing to it has only been tested with simulated disks).
