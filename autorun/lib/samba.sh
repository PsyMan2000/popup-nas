# Makes everything already on the share (copied in by this popup's own copy,
# which runs as root, or left by an older version) readable, writable and
# deletable for everyone who connects, to match the masks in smb.conf.
# $1 = the share folder (default: $SHARE_MOUNT). Quick: no file is read.
share_fix_permissions() {
  local p="${1:-${SHARE_MOUNT:-}}"
  [ -n "$p" ] && [ -d "$p" ] || return 0
  chown -R nobody:nobody "$p" 2>/dev/null || true
  chmod -R a+rwX "$p" 2>/dev/null || true
}

configure_and_start_samba() {
  local share_path="$1"
  local netbios_name
  netbios_name=$(hostname | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9-' | cut -c1-15)

  cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   netbios name = $netbios_name
   server string = popup-nas
   security = user
   map to guest = Bad User
   guest account = nobody
   server role = standalone server
   # A client (a Mac, Windows, Linux) can not change the Unix permissions
   # of what it copies in, so nothing dragged onto the share ends up
   # locked against the next person.
   unix extensions = no
   nt acl support = no

[share]
   path = $share_path
   browseable = yes
   guest ok = yes
   read only = no
   force user = nobody
   force group = nobody
   # Everything on the share is open to everyone: every file and folder
   # made through Samba is read-write for all, whatever the client sent.
   create mask = 0666
   force create mode = 0666
   directory mask = 0777
   force directory mode = 0777
   inherit permissions = no
EOF
  share_fix_permissions "$share_path"

  if ! systemctl restart smb nmb 2>/dev/null; then
    pkill -x smbd nmbd 2>/dev/null || true
    smbd
    nmbd
  fi
}

# Number of machines currently connected to this box over SMB. Counts
# established TCP connections where this box is listening on port 445
# (the SMB port), rather than parsing smbstatus's output - smbstatus's
# exact text format has changed between Samba versions, whereas counting
# connections on the port itself is simple and version-proof.
smb_connection_count() {
  ss -tn state established "( sport = :445 )" 2>/dev/null | tail -n +2 | wc -l
}
