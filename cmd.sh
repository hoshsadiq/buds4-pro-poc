#!/bin/bash
# Sends the handshake frames and the feature flags that matter, then prints replies.
# Requires BUDS_ADDR to hold the earbuds Bluetooth address.

cd "$(dirname "$0")" || exit 1
: "${BUDS_ADDR:?set BUDS_ADDR to the earbuds Bluetooth address}"

LISTEN_LONG=3
LISTEN_SHORT=2

# 1. Setting info. Message 0x73. Announces this host as a Samsung peer and which
#    transport it uses: 01 is ordinary Bluetooth, 02 is LE Audio.
echo "--- 1. setting info, message 0x73, transport Bluetooth ---"
./gear "$BUDS_ADDR" "FE 14 00 73 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0B 44 EE" "$LISTEN_LONG"

# 2. Metadata version. Message 0x43, version byte at offset 0x0B. Three means
#    auto-switch is enabled, zero means generic.
echo "--- 2. metadata version, message 0x43, value 3 (auto-switch) ---"
./gear "$BUDS_ADDR" "FC 0C 00 01 43 43 04 03 04 00 00 0B 03 C4 49 CC" "$LISTEN_SHORT"

# 3. Take-over request. Message 0x71, one payload byte: the host device class,
#    1 meaning computer. This is the frame that actually moves audio.
echo "--- 3. take-over request, message 0x71, device class 1 (computer) ---"
./gear "$BUDS_ADDR" "FC 05 10 01 71 01 79 1C CC" "$LISTEN_LONG"

# 4. Feature flags this host claims, written to the vendor channel. 0x011C is
#    FEATURE_LE_AUDIO and 0x010E is FEATURE_AUTO_SWITCH.
echo "--- 4. feature LE audio, property 0x011C = 1 ---"
./gear "$BUDS_ADDR" "FC 08 00 01 43 1C 01 01 01 AF FA CC" "$LISTEN_SHORT"

echo "--- 5. feature auto switch, property 0x010E = 1 ---"
./gear "$BUDS_ADDR" "FC 08 00 01 43 0E 01 01 01 60 0C CC" "$LISTEN_SHORT"
