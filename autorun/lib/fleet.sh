FLEET_PORT=47500
FLEET_STATE=/tmp/popup-fleet.json

start_fleet_broadcast() {
  local hostname_value="$1"
  python3 "$HERE/fleet-broadcast.py" "$hostname_value" "$FLEET_PORT" "$SHARE_MOUNT" "$FLEET_STATE" >/tmp/popup-fleet.log 2>&1 &
}

# Prints a boxed table of every popup-nas box seen on the network,
# INCLUDING this one - marked "(you)" - since this box never receives its
# own UDP broadcast (fleet-broadcast.py deliberately ignores messages from
# itself).
#
# $1 = this box's own hostname, $2 = this box's own primary IP (or "?" if
# unknown), $3 = this box's own free space as a ready-to-print string (e.g.
# "420.3 GB", or "-" if no share is set up yet), $4 = this box's own
# current SMB connection count.
fleet_table() {
  local self_name="$1" self_ip="$2" self_free="$3" self_conn="$4"
  python3 - "$FLEET_STATE" "$self_name" "$self_ip" "$self_free" "$self_conn" <<'PYEOF'
import json, sys, time

state_path, self_name, self_ip, self_free, self_conn = sys.argv[1:6]
try:
    data = json.load(open(state_path))
except Exception:
    data = {}

now = time.time()
rows = [{"label": f"{self_name} (you)", "ip": self_ip, "free": self_free, "conn": self_conn}]
for name, info in sorted(data.items()):
    if now - info.get("seen", 0) >= 30:
        continue
    free = info.get("free_gb")
    free = f"{free} GB" if free is not None else "-"
    rows.append({"label": name, "ip": info.get("ip", ""), "free": free, "conn": info.get("connections", "-")})

headers = {"label": "NAME", "ip": "IP", "free": "FREE", "conn": "CONN"}
widths = {k: max(len(str(r[k])) for r in rows + [headers]) for k in headers}

def border(l, m, r):
    return l + m.join("-" * (widths[k] + 2) for k in ("label", "ip", "free", "conn")) + r

def line(r):
    return "| " + " | ".join(f"{str(r[k]):<{widths[k]}}" for k in ("label", "ip", "free", "conn")) + " |"

print(border("+", "+", "+"))
print(line(headers))
print(border("+", "+", "+"))
for r in rows:
    print(line(r))
print(border("+", "+", "+"))
PYEOF
}
