"""Regression tests for the firmware decision model.

usage: uv run --with unicorn --with pytest python -m pytest emu/test_decision.py -q
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from decision_model import run_case

IMAGE = os.environ.get("BUDS_FIRMWARE", os.path.expanduser("~/buds-re/R640XXU0AZD2.bin"))
MISC, COMPUTER, PHONE, AUDIO, PERIPHERAL, WEARABLE, UNCATEGORISED = 0, 1, 2, 4, 5, 7, 31


def call(cls, mask=0x20, auto=1, audio=1, call_profile=0, transport=0xFD):
    return run_case(IMAGE, mask, cls, auto, audio, call_profile, transport=transport)


@pytest.mark.parametrize('cls', [COMPUTER, PHONE, PERIPHERAL])
def test_some_classes_never_reach_the_sdk_apply(cls):
    assert call(cls)['applied'] is None


@pytest.mark.parametrize('cls', [AUDIO, WEARABLE, MISC, UNCATEGORISED])
def test_other_classes_do_reach_the_apply(cls):
    assert call(cls)['applied'] is not None


def test_apply_true_needs_autoswitch_and_the_transport_bit():
    assert call(AUDIO, mask=0x20, auto=1)['applied'] is True
    assert call(AUDIO, mask=0x00, auto=1)['applied'] is not True
    assert call(AUDIO, mask=0x20, auto=0)['applied'] is not True


def test_no_audio_profile_never_allows_the_disconnect():
    assert call(AUDIO, audio=0)['applied'] is not True


def test_call_profile_takes_a_different_path():
    assert call(AUDIO, call_profile=1)['code'] != call(AUDIO)['code']
