#!/usr/bin/env python3
"""Tiny UDP broadcast + listener so every popup-nas box on the same LAN
segment can see the others (the "fleet"). Broadcast traffic doesn't cross a
router/VLAN boundary - this only shows peers on the same physical network
segment, which is the normal case for a single-site imaging event.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

hostname, port, share_mount, state_path, repo_root = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
# Which update channel (git branch) this box follows - optional 6th argument,
# so an older autorun/fleet.sh that doesn't pass it still works.
CHANNEL = sys.argv[6] if len(sys.argv) > 6 else "-"


def my_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "0.0.0.0"
    finally:
        s.close()


def free_gb():
    try:
        return round(shutil.disk_usage(share_mount).free / 1e9, 1)
    except OSError:
        return None


def connection_count():
    # Established TCP connections where WE are listening on port 445 (the
    # SMB port) - i.e. how many machines currently have this box's share
    # open. Matches the bash-side smb_connection_count() helper.
    try:
        out = subprocess.run(
            ["ss", "-tn", "state", "established", "( sport = :445 )"],
            capture_output=True, text=True, timeout=2,
        ).stdout.splitlines()
        return max(len(out) - 1, 0)  # first line is ss's own header
    except Exception:
        return 0


def my_version():
    # This box's current git commit, short form - lets the fleet table show
    # at a glance which boxes have self-updated and which haven't. Computed
    # once at startup (not per-broadcast) since it only changes when
    # self_update() restarts this whole process anyway. "-" for a stick
    # made the old plain-file-copy way (no .git folder) or if git itself
    # isn't available.
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        v = out.stdout.strip()
        return v if out.returncode == 0 and v else "-"
    except Exception:
        return "-"


VERSION = my_version()


def my_version_number():
    # The version NUMBER from the VERSION file in the repo root (e.g.
    # "1.5.1"), announced next to the commit so the status screen can show
    # both. "" if the file can't be read.
    try:
        with open(os.path.join(repo_root, "VERSION")) as f:
            return f.read().strip()[:16]
    except OSError:
        return ""


VERSION_NUMBER = my_version_number()


# How many characters of each image's name are announced (shown in the
# IMAGES column of the status screen). lib/populate.sh has its own copy of
# this number (IMAGE_NAME_CHARS) - change both. At most this many names are
# sent, so the broadcast always stays small.
IMAGE_NAME_CHARS = 8
IMAGE_NAMES_MAX = 6


def image_summary():
    # The finished .wim files on this box's share: how many, their total
    # size in GB, and the first few characters of each name (without
    # ".wim"), so other boxes can offer "copy from this popup". Same rule as
    # list_wims() in lib/populate.sh: up to 4 levels deep, and names
    # starting with "." are skipped - rsync keeps half-finished copies under
    # hidden names, so an unfinished file is never announced.
    found, total = [], 0
    try:
        for dirpath, dirnames, filenames in os.walk(share_mount):
            depth = os.path.relpath(dirpath, share_mount).count(os.sep) + 1 if dirpath != share_mount else 0
            dirnames[:] = [d for d in dirnames if not d.startswith(".")] if depth < 3 else []
            for f in filenames:
                if f.startswith(".") or not f.lower().endswith(".wim"):
                    continue
                try:
                    total += os.path.getsize(os.path.join(dirpath, f))
                    found.append((os.path.relpath(os.path.join(dirpath, f), share_mount), f[:-4][:IMAGE_NAME_CHARS]))
                except OSError:
                    pass
    except OSError:
        pass
    found.sort()
    return len(found), round(total / 1e9, 1), [name for _, name in found[:IMAGE_NAMES_MAX]]


def broadcaster():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        images, images_gb, image_names = image_summary()
        msg = json.dumps({
            "name": hostname,
            "ip": my_ip(),
            "free_gb": free_gb(),
            "connections": connection_count(),
            "version": VERSION,
            "version_number": VERSION_NUMBER,
            "channel": CHANNEL,
            "images": images,
            "images_gb": images_gb,
            "image_names": image_names,
            "ts": time.time(),
        })
        try:
            sock.sendto(msg.encode(), ("255.255.255.255", port))
        except OSError:
            pass
        time.sleep(5)


def listener():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", port))
    peers = {}
    while True:
        try:
            data, addr = sock.recvfrom(2048)
            msg = json.loads(data.decode())
        except (OSError, ValueError, KeyError):
            continue
        name = msg.get("name")
        if not name or name == hostname:
            continue
        peers[name] = {
            "ip": msg.get("ip", addr[0]),
            "free_gb": msg.get("free_gb"),
            "connections": msg.get("connections", 0),
            "version": msg.get("version", "-"),
            "version_number": msg.get("version_number") or "",
            "channel": msg.get("channel", "-"),
            "images": msg.get("images"),
            "images_gb": msg.get("images_gb", 0),
            "image_names": msg.get("image_names") or [],
            "seen": time.time(),
        }
        peers = {k: v for k, v in peers.items() if time.time() - v["seen"] < 60}
        tmp = state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(peers, f)
        os.replace(tmp, state_path)


threading.Thread(target=broadcaster, daemon=True).start()
listener()
