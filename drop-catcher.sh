#!/bin/bash
# Watches for the earbuds link dropping and saves the Bluetooth log around the event,
# so the reason code and the seconds before it are captured without babysitting.
# Requires BUDS_ADDR in the form AA:BB:CC:DD:EE:FF.
set -u
: "${BUDS_ADDR:?set BUDS_ADDR to the earbuds Bluetooth address}"
OUT="${DROP_OUT:-$HOME/buds-re/poc/drops}"
mkdir -p "$OUT"

seen=""
while true; do
  recent=$(log show --last 8s --predicate 'process == "bluetoothd"' --style compact 2>/dev/null \
           | grep "$BUDS_ADDR" | grep -c "ACL disconnected")
  if [ "$recent" -gt 0 ]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    if [ "$recent" != "$seen" ]; then
      log show --last 90s --predicate 'process == "bluetoothd"' --style compact 2>/dev/null \
        | grep -E "$BUDS_ADDR|BE|A2DP|HFP|SCO|HID" > "$OUT/drop-$stamp.log"
      echo "$stamp captured ($recent events)" >> "$OUT/index.txt"
      seen="$recent"
    fi
  else
    seen=""
  fi
  sleep 3
done
