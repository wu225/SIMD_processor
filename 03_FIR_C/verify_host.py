"""Build host emulation and independently verify dumps, including short frames."""
import math
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def verify(output, taps, samples, frames):
    assert 'PASS all FIR comparisons' in output
    h = []
    for k in range(taps):
        z = 0.2 * (k - (taps - 1) / 2)
        h.append(0.2 * math.sin(math.pi * z) / (math.pi * z)
                 * (0.54 - 0.46 * math.cos(2 * math.pi * k / (taps - 1))))
    total = sum(h)
    q31 = [round(v / total * (1 << 31)) for v in h]
    data = {}
    hashes = {}
    for line in output.splitlines():
        cells = line.split(',')
        if cells[0] == 'DATA':
            _, kind, width, frame, n, source, actual = cells
            key = kind, int(width)
            values = data.setdefault(key, [])
            assert int(frame) * samples + int(n) == len(values)
            values.append((int(source), int(actual)))
        elif cells[0] == 'ROW' and cells[1] != 'input':
            assert cells[4:8] == ['0'] * 4  # Host timing must stay explicitly unavailable.
            hashes[(cells[1], int(cells[2]), int(cells[3]))] = int(cells[8], 16)
    assert len(data) == 6
    for (kind, width), values in data.items():
        assert len(values) == samples * frames
        fx, fh = {8: (3, 6), 16: (7, 10), 32: (15, 15)}[width]
        qh = [v // (1 << (31 - fh)) for v in q31]
        qx = [v[0] // (1 << (15 - fx)) for v in values]
        expected = [sum(qh[k] * qx[n - k] for k in range(min(taps, n + 1)))
                    for n in range(len(qx))]
        assert expected == [v[1] for v in values], (kind, width, samples)
        for frame in range(frames):
            hashed = 2166136261
            for v in expected[frame * samples:(frame + 1) * samples]:
                hashed = ((hashed ^ (v & 0xffffffff)) * 16777619) & 0xffffffff
            assert hashes[kind, width, frame] == hashed
    for kind in ('random', 'two_tone'):
        assert [v[0] for v in data[kind, 8]] == [v[0] for v in data[kind, 16]]
        assert [v[0] for v in data[kind, 8]] == [v[0] for v in data[kind, 32]]


def main():
    gcc = shutil.which('gcc')
    if gcc is None:
        raise SystemExit('gcc is required for host-only functional verification')
    fixture = (ROOT / 'fir_fixture.h').read_text(encoding='utf-8')
    taps = int(re.search(r'#define FIR_TAPS (\d+)', fixture).group(1))
    with tempfile.TemporaryDirectory(prefix='fir_mulp_') as temp:
        exe = Path(temp) / 'fir_host.exe'
        for samples, frames in ((1, 3), (3, 3), (17, 3), (1024, 10)):
            subprocess.run([gcc, '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-DFIR_HOST', '-DFIR_DUMP=1', f'-DFIR_SAMPLES={samples}',
                            f'-DFIR_FRAMES={frames}', str(ROOT / 'fir_bench.c'),
                            str(ROOT / 'fir_kernels.c'), str(ROOT / 'fir_model_check.c'),
                            '-o', str(exe)], check=True)
            result = subprocess.run([str(exe)], capture_output=True, text=True, check=True)
            verify(result.stdout, taps, samples, frames)
            print(f'PASS independent Python convolution: taps={taps}, samples={samples}, frames={frames}, all modes/inputs')
    print('Host emulation verifies functionality only. ASIP compilation and CA timing must be run in ASIP Designer.')


if __name__ == '__main__':
    main()
