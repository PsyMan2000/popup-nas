wait_for_network() {
  echo -n "Waiting for a network address"
  for _ in $(seq 1 30); do
    if ip -4 -o addr show scope global 2>/dev/null | grep -q .; then
      echo " - got one."
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo ""
  echo "No network address yet after 30s - continuing anyway. Check a cable is connected, or use the menu to retry later."
}

primary_ip() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}
