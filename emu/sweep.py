"""Sweep the decision function over its inputs and write the resulting table.

usage: uv run --with unicorn python emu/sweep.py [outfile]
"""

import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from decision_model import run_case

IMAGE = os.environ.get("BUDS_FIRMWARE", os.path.expanduser("~/buds-re/R640XXU0AZD2.bin"))
CLASSES = [0, 1, 2, 4, 5, 7, 31]
MASKS = [0x00, 0x01, 0x10, 0x20, 0x40, 0x30, 0x50, 0x70]
TRANSPORTS = [0xFD, 0xFE, 0xFF]


def collect(rows):
    for cls, mask, transport, auto, audio, call in itertools.product(
            CLASSES, MASKS, TRANSPORTS, [0, 1], [0, 1], [0, 1]):
        state = run_case(IMAGE, mask, cls, auto, audio, call, transport=transport)
        rows.append((cls, mask, transport, auto, audio, call,
                     state['code'], state['applied']))


def write(rows, path):
    with open(path, 'w') as f:
        f.write('class\tmask\ttransport\tautoswitch\taudio\tcall\tcode\tapplied\n')
        for r in rows:
            f.write('%d\t0x%02x\t0x%02x\t%d\t%d\t%d\t%s\t%s\n' % (
                r[0], r[1], r[2], r[3], r[4], r[5],
                r[6], '' if r[7] is None else int(r[7])))


def summarise(rows):
    applied = [r for r in rows if r[7]]
    codes = {}
    for r in rows:
        codes[r[6]] = codes.get(r[6], 0) + 1
    print('cases %d, applied %d' % (len(rows), len(applied)))
    print('exit codes:', sorted(codes.items(), key=lambda kv: -kv[1]))
    print('classes that ever apply:', sorted({r[0] for r in applied}))
    print('classes that never apply:', sorted({r[0] for r in rows} - {r[0] for r in applied}))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/buds-re/emu/results.tsv')
    rows = []
    collect(rows)
    write(rows, out)
    summarise(rows)


if __name__ == '__main__':
    main()
