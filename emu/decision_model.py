"""Run the firmware's auto-switch decision function under emulation.

The function lives at 0x101f4468 in the Buds4 Pro image. It takes a transport mask, reads a
peer record and a runtime context, and either exits with a code or calls the SDK's apply
routine. Everything it calls is stubbed so the inputs are ours to choose.
"""

import struct

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE
from unicorn.arm_const import (
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC,
)

BASE = 0x10010000
RAM = 0x20000000
RAM_SIZE = 0x400000
STACK_TOP = RAM + RAM_SIZE - 0x1000
CTX = 0x200b7614
RECORD = 0x20002000
FUNC = 0x101f4468
FW_ASSERT = 0x101b9a44
APPLY = 0x10304c54
TRANSPORT_GETTER = 0x101f50c4
DEVICE_FROM_RECORD = 0x101bba40
SLOT_LOOKUP = 0x101bc130
CTX_GETTER = 0x1031009c
PROFILE_A = 0x101fe740
PROFILE_B = 0x1020cf68
LOGGER = 0x101bb684


def _stub_value(address, r1, audio_profile, call_profile, transport):
    if address == DEVICE_FROM_RECORD or address == SLOT_LOOKUP:
        return RECORD
    if address == CTX_GETTER:
        return CTX
    if address == TRANSPORT_GETTER:
        return transport
    if address == PROFILE_A:
        return call_profile if r1 == 2 else audio_profile
    if address == PROFILE_B:
        return call_profile if r1 == 0xC else audio_profile
    if address == LOGGER:
        return 0
    return 0


def run_case(image_path, mask, device_class, autoswitch, audio_profile, call_profile,
             mode=1, transport=0xFD, flag_6d=None, flag_6e=None):
    image = open(image_path, 'rb').read()
    uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
    uc.mem_map(BASE, 0x1000000)
    uc.mem_write(BASE, image)
    uc.mem_map(RAM, RAM_SIZE)

    record = bytearray(0x800)
    record[0x3F] = device_class
    record[0x6B] = autoswitch
    uc.mem_write(RECORD, bytes(record))

    ctx = bytearray(0x1000)
    ctx[0x26] = mode
    ctx[0x6B] = autoswitch
    ctx[0x6D] = autoswitch if flag_6d is None else flag_6d
    ctx[0x6E] = autoswitch if flag_6e is None else flag_6e
    uc.mem_write(CTX, bytes(ctx))

    state = {'code': None, 'applied': None}

    def hook(uc_, address, size, user):
        if address == FW_ASSERT:
            state['code'] = uc_.reg_read(UC_ARM_REG_R0)
            uc_.emu_stop()
            return
        if address == APPLY:
            state['applied'] = bool(uc_.reg_read(UC_ARM_REG_R0))
            uc_.reg_write(UC_ARM_REG_PC, uc_.reg_read(UC_ARM_REG_LR) | 1)
            return
        uc_.reg_write(UC_ARM_REG_R0,
                      _stub_value(address, uc_.reg_read(UC_ARM_REG_R1),
                                  audio_profile, call_profile, transport))
        uc_.reg_write(UC_ARM_REG_PC, uc_.reg_read(UC_ARM_REG_LR) | 1)

    # Only intercept the known call targets; everything else executes.
    known = {FW_ASSERT, APPLY, DEVICE_FROM_RECORD, SLOT_LOOKUP, CTX_GETTER,
             TRANSPORT_GETTER, PROFILE_A, PROFILE_B, LOGGER}

    def selective_hook(uc_, address, size, user):
        if address in known:
            hook(uc_, address, size, user)

    uc.hook_add(UC_HOOK_CODE, selective_hook)

    uc.reg_write(UC_ARM_REG_SP, STACK_TOP)
    uc.reg_write(UC_ARM_REG_R0, mask)
    uc.reg_write(UC_ARM_REG_LR, 0xFFFFFFF9)
    try:
        uc.emu_start(FUNC | 1, 0xFFFFFFF9, count=400000)
    except Exception:
        pass
    return state
