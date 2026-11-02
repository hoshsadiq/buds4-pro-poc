# Firmware decision emulator

Runs single functions from the Buds4 Pro firmware image on the host, with hardware calls
stubbed, so the earbuds' own decisions can be inspected without the earbuds.

Needs the firmware file. It defaults to `~/buds-re/R640XXU0AZD2.bin`, or point `BUDS_FIRMWARE`
at it.

    uv run --with unicorn python emu/emu_decision.py 0x20 4 1 1 0
    uv run --with unicorn python emu/sweep.py
    uv run --with unicorn --with pytest python -m pytest emu/test_decision.py -q

Arguments for `emu_decision.py`: transport mask, device class, auto-switch flag, audio
profile present, call profile present.

`results.tsv` covers 1,344 combinations: classes 0/1/2/4/5/7/31, eight masks, three transport
selectors, and every combination of the three flags.

## What it shows

Only classes 0, 4, 7 and 31 ever reach the SDK's disconnect call. Classes 1 (computer),
2 (phone) and 5 (peripheral) exit before it, whatever the flags say. So the cut a Mac
experiences does not come from this function. It happens earlier, in admission.

Admission lives at `0x102d9a08`. It walks the device list, reads a per-device flag, and
compares a four-byte value from the firmware's settings table, read through the SDK's own
API. When the check fails it logs "not allowed. disconnecting" and calls the SDK disconnect.
