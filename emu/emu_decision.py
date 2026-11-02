"""Emulate the firmware's auto-switch scoring function on the host, so its decision can be
inspected without hardware.

The function at 0x101f4468 decides whether a connected peer keeps audio. It reads a peer
record and a runtime context, then returns a value that picks the disconnect delay or a
failure code. Everything it calls into the SDK is stubbed, so the inputs are ours to choose.

usage: emu_decision.py <mask-hex> [recordType] [autoswitch] [audioProfile] [callProfile]
"""

import os

import struct
import sys

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import (
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC,
)

BASE = 0x10010000
IMAGE = os.environ.get('BUDS_FIRMWARE', os.path.expanduser('~/buds-re/R640XXU0AZD2.bin'))
RAM = 0x20000000
RAM_SIZE = 0x400000
STACK_TOP = RAM + RAM_SIZE - 0x1000
CTX = 0x200b7614            # runtime context the firmware uses (DAT_101f4724)
RECORD = 0x20002000         # synthetic peer record
FUNC = 0x101f4468
FW_ASSERT = 0x101b9a44

# SDK stubs the target calls, and the values they should return.
STUBS = {
    0x10327bf0: 1,   # stream/type lookup
    0x101a2e54: 0,   # fallback device lookup
    0x101bba40: RECORD,   # device index from record
    0x101bc130: RECORD,   # slot lookup
    0x101f50c4: 0xfd,  # transport selector
    0x101fe740: 0,   # profile presence, first transport
    0x1020cf68: 0,   # profile presence, second transport
    0x1031009c: CTX,   # context pointer getter
    0x101f3ab0: 0,   # address helper
    0x10304c54: 0,   # apply decision
    0x1009a050: 0,   # device comparison helper
    0x101bb684: 0,   # logging
}


def main():
    mask = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0
    record_type = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    autoswitch = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    audio_profile = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    call_profile = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    image = open(IMAGE, 'rb').read()

    uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
    uc.mem_map(BASE, 0x1000000)
    uc.mem_write(BASE, image)
    uc.mem_map(RAM, RAM_SIZE)

    # peer record: field 0x3f carries the device class, 0x6b the auto-switch flag
    rec = bytearray(0x800)
    rec[0x3f] = record_type
    rec[0x6b] = autoswitch
    uc.mem_write(RECORD, bytes(rec))

    # runtime context: 0x26 is a mode the firmware compares against 1 and 2
    ctx = bytearray(0x1000)
    ctx[0x26] = 1
    ctx[0x6b] = autoswitch
    ctx[0x6d] = autoswitch
    ctx[0x6e] = autoswitch
    uc.mem_write(CTX, bytes(ctx))

    # stub the two profile probes so their return values follow the arguments
    def hook_profile(uc_, address, size, user):
        uc_.reg_write(UC_ARM_REG_R0, audio_profile)

    def hook_profile2(uc_, address, size, user):
        uc_.reg_write(UC_ARM_REG_R0, call_profile)

    state = {'assert': None, 'applied': None}

    def hook_code(uc_, address, size, user):
        if address in STUBS:
            if address == 0x101fe740:
                which = uc_.reg_read(UC_ARM_REG_R1)
                uc_.reg_write(UC_ARM_REG_R0, call_profile if which == 2 else audio_profile)
            elif address == 0x1020cf68:
                which = uc_.reg_read(UC_ARM_REG_R1)
                uc_.reg_write(UC_ARM_REG_R0, call_profile if which == 0xc else audio_profile)
            elif address == 0x101bb684:
                pass
            else:
                uc_.reg_write(UC_ARM_REG_R0, STUBS[address])
            uc_.reg_write(UC_ARM_REG_PC, uc_.reg_read(UC_ARM_REG_LR) | 1)
            return
        if address == FW_ASSERT:
            state['assert'] = uc_.reg_read(UC_ARM_REG_R0)
            uc_.emu_stop()
            return
        if address == 0x10304c54:
            state['applied'] = uc_.reg_read(UC_ARM_REG_R0)
            uc_.reg_write(UC_ARM_REG_PC, uc_.reg_read(UC_ARM_REG_LR) | 1)
            return

    uc.hook_add(UC_HOOK_CODE, hook_code)

    uc.reg_write(UC_ARM_REG_SP, STACK_TOP)
    uc.reg_write(UC_ARM_REG_R0, mask)
    uc.reg_write(UC_ARM_REG_LR, 0xFFFFFFF9)
    try:
        uc.emu_start(FUNC | 1, 0xFFFFFFF9, count=200000)
    except Exception as exc:  # emulation stops at the no-return assert
        pass

    print('mask=0x%02x recordType=%d autoswitch=%d audio=%d call=%d -> assert=%s applied=%s'
          % (mask, record_type, autoswitch, audio_profile, call_profile,
             state['assert'], state['applied']))


if __name__ == '__main__':
    main()
