"""Turn the already verified example packet into a bare-metal C header."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
frame = (root / 'data' / 'frame_0.bin').read_bytes()
assert len(frame) == 3196
out = root / 'software' / 'frame_0.h'
out.parent.mkdir(parents=True, exist_ok=True)
rows = ['    ' + ', '.join(f'0x{b:02x}' for b in frame[i:i + 16]) + ','
        for i in range(0, len(frame), 16)]
out.write_text('#ifndef MNIST_FRAME_0_H\n#define MNIST_FRAME_0_H\n'
               '#define MNIST_FRAME_BYTES 3196\n'
               'static const unsigned char mnist_frame_0[MNIST_FRAME_BYTES] = {\n'
               + '\n'.join(rows) + '\n};\n#endif\n', encoding='utf-8')
print(f'Wrote {out} ({len(frame)} bytes)')
