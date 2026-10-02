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

[share]
   path = $share_path
   browseable = yes
   guest ok = yes
   read only = no
   force user = nobody
   force group = nobody
EOF

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
