#!/bin/bash
# Sends the frames a Samsung host and the Samsung phone stack send, in order, then
# prints the replies. Set STEP to stop after a given stage while testing.
# Requires BUDS_ADDR to hold the earbuds Bluetooth address.

cd "$(dirname "$0")" || exit 1
: "${BUDS_ADDR:?set BUDS_ADDR to the earbuds Bluetooth address}"
STEP=${STEP:-all}
LISTEN_LONG=3
LISTEN_SHORT=2

stage() { [ "$STEP" = "all" ] || [ "$STEP" = "$1" ]; }
send() { ./gear "$BUDS_ADDR" "$2" "$3"; sleep 1; }

echo "--- 0. bringing the link up ---"
./budsctl switch 2>&1 | tail -2
sleep 3

if stage setting; then
  echo "--- 1. setting info, message 0x73, transport Bluetooth ---"
  send 1 "FE 14 00 73 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0B 44 EE" "$LISTEN_LONG"
fi

echo "--- 2. metadata version 3, message 0x43 field 0x0B ---"
send 2 "FC 0C 00 01 43 43 04 03 04 00 00 0B 03 C4 49 CC" "$LISTEN_SHORT"

echo "--- 3. subscribe to pushes, property 0xC104 = 1 ---"
send 3 "FC 08 00 01 43 04 C1 01 01 3C 42 CC" "$LISTEN_LONG"

echo "--- 4. connection state, property 0xC103 = 2 (connected) ---"
send 4 "FC 08 00 01 43 03 C1 01 02 72 23 CC" "$LISTEN_SHORT"

echo "--- 5. connected with profile, property 0xC106 = 1 ---"
send 5 "FC 08 00 01 43 06 C1 01 01 54 AF CC" "$LISTEN_SHORT"

# 6. The remaining commands the Samsung phone stack sends, in one batch.
echo "--- 6a. subscribe, property 0x0301 = 1 ---"
send 6a "FC 08 00 01 43 01 03 01 01 EE B6 CC" "$LISTEN_SHORT"
echo "--- 6b. twp run, property 0x0309 = 1 ---"
send 6b "FC 08 00 01 43 09 03 01 01 2D 33 CC" "$LISTEN_SHORT"
echo "--- 6c. support sbm, property 0x0303 = 1 ---"
send 6c "FC 08 00 01 43 03 03 01 01 86 5B CC" "$LISTEN_SHORT"
echo "--- 6d. low latency mode off, property 0x030C = 0 ---"
send 6d "FC 08 00 01 43 0C 03 01 00 49 9F CC" "$LISTEN_SHORT"

if [ "${REPAIR_LE:-0}" = "1" ]; then
  echo "--- 6. re-pair for LE Audio, property 0x030A = 1 (drops the bond) ---"
  send 6 "FC 08 00 01 43 0A 03 01 01 F1 A8 CC" "$LISTEN_LONG"
fi

echo "--- 7. take-over request, message 0x71, device class 1 (computer) ---"
send 7 "FC 05 10 01 71 01 79 1C CC" "$LISTEN_LONG"
