FLEET_PORT=47500
FLEET_STATE=/tmp/popup-fleet.json

# Above this many concurrent SMB connections, a box's CONN column shows red
# in the fleet table (1 up to this many shows yellow, 0 shows green). Just
# a display threshold - doesn't affect anything else. Tune once real
# imaging-day load patterns are known.
FLEET_CONN_BUSY_THRESHOLD=3

start_fleet_broadcast() {
  local hostname_value="$1" repo_root
  repo_root="$(cd "$HERE/.." 2>/dev/null && pwd)"
  # Stop any fleet-broadcast.py this exact machine may already have
  # running before starting a new one. Several things relaunch the
  # foreground autorun0 script on the same box without ever touching this
  # backgrounded process - self_update()'s restart after pulling a new
  # version, `menu` relaunching fresh over a new SSH login, or just
  # opening a second session (SSH alongside the console) and running the
  # manual refresh sequence by hand. Each one used to leave yet another
  # copy broadcasting under its own hostname, showing up as a "ghost"
  # duplicate row in the fleet table for what's really just one machine.
  # Confirmed on real hardware 2026-10-02.
  pkill -f "fleet-broadcast\.py" 2>/dev/null || true
  python3 "$HERE/fleet-broadcast.py" "$hostname_value" "$FLEET_PORT" "$SHARE_MOUNT" "$FLEET_STATE" "$repo_root" "$(channel_name)" >/tmp/popup-fleet.log 2>&1 &
}

# Prints a boxed table of every popup-nas box seen on the network,
# INCLUDING this one - marked "(you)" - since this box never receives its
# own UDP broadcast (fleet-broadcast.py deliberately ignores messages from
# itself). The CONN column is colour-coded green/yellow/red by load (see
# FLEET_CONN_BUSY_THRESHOLD above) so a busy box stands out at a glance.
#
# $1 = this box's own hostname, $2 = this box's own primary IP (or "?" if
# unknown), $3 = this box's own free space as a ready-to-print string (e.g.
# "420.3 GB", or "-" if no share is set up yet), $4 = this box's own
# current SMB connection count, $5 = this box's own current git commit
# short-hash (or "-" if this isn't a self-updating git checkout), $6 = this
# box's own update channel name (from channel_name; shown in the CHANNEL
# column - boxes still running older code don't report one, shown as "-"),
# $7 = this box's own image summary (share_image_summary in lib/populate.sh,
# e.g. "Win11-Pr,Win10-Ed (45.3 GB)"; shown in the IMAGES column - other boxes report theirs
# in their broadcast, and an older box that doesn't is shown as "?").
fleet_table() {
  local self_name="$1" self_ip="$2" self_free="$3" self_conn="$4" self_version="$5" self_channel="${6:--}" self_images="${7:--}"
  python3 - "$FLEET_STATE" "$self_name" "$self_ip" "$self_free" "$self_conn" "$self_version" "$FLEET_CONN_BUSY_THRESHOLD" "$self_channel" "$self_images" <<'PYEOF'
import json, sys, time

state_path, self_name, self_ip, self_free, self_conn, self_version, busy_threshold, self_channel, self_images = sys.argv[1:10]
busy_threshold = int(busy_threshold)
try:
    data = json.load(open(state_path))
except Exception:
    data = {}

now = time.time()
rows = [{"label": f"{self_name} (you)", "ip": self_ip, "free": self_free, "conn": self_conn, "ver": self_version, "chan": self_channel, "img": self_images}]
for name, info in sorted(data.items()):
    if now - info.get("seen", 0) >= 30:
        continue
    free = info.get("free_gb")
    free = f"{free} GB" if free is not None else "-"
    # IMAGES: finished .wim files on that box's share. A box running an
    # older popup-nas doesn't report this at all, shown as "?".
    n_img = info.get("images")
    if n_img is None:
        img = "?"
    elif n_img == 0:
        img = "none"
    else:
        # First few characters of each image's name, then the total size -
        # the same text share_image_summary (lib/populate.sh) makes for
        # this box's own row. More than 3 images: the first 3, then "+N".
        names = list(info.get("image_names") or [])
        if names:
            shown = names[:3]
            if n_img > 3:
                shown.append(f"+{n_img - 3}")
            img = f"{','.join(shown)} ({info.get('images_gb', 0)} GB)"
        else:
            img = f"{n_img} / {info.get('images_gb', 0)} GB"
    rows.append({
        "label": name,
        "ip": info.get("ip", ""),
        "free": free,
        "conn": info.get("connections", "-"),
        "ver": info.get("version", "-"),
        "chan": info.get("channel", "-"),
        "img": img,
    })

headers = {"label": "NAME", "ip": "IP", "free": "FREE", "conn": "CONN", "ver": "VER", "chan": "CHANNEL", "img": "IMAGES"}
cols = ("label", "ip", "free", "conn", "ver", "chan", "img")
widths = {k: max(len(str(r[k])) for r in rows + [headers]) for k in cols}

RESET, GREEN, YELLOW, RED = "\033[0m", "\033[32m", "\033[33m", "\033[31m"

def conn_color(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    if n == 0:
        return GREEN
    if n <= busy_threshold:
        return YELLOW
    return RED

def chan_color(value):
    # Same rule as channel_info in lib/selfupdate.sh - change both together.
    v = str(value).upper()
    if v in ("-", "NO GIT", ""):
        return None
    if v == "STABLE":
        return GREEN
    if v in ("STAGE", "STAGING", "BETA", "RC"):
        return YELLOW
    return RED

def border(l, m, r):
    return l + m.join("-" * (widths[k] + 2) for k in cols) + r

def line(r, colorize=True):
    cells = []
    for k in cols:
        text = f"{str(r[k]):<{widths[k]}}"
        if colorize and k in ("conn", "chan"):
            color = conn_color(r[k]) if k == "conn" else chan_color(r[k])
            if color:
                text = f"{color}{text}{RESET}"
        cells.append(text)
    return "| " + " | ".join(cells) + " |"

print(border("+", "+", "+"))
print(line(headers, colorize=False))
print(border("+", "+", "+"))
for r in rows:
    print(line(r))
print(border("+", "+", "+"))
PYEOF
}
