"""Pack the existing MNIST INT8 reference vectors into one DMA input frame."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--vectors", type=Path, required=True)
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "data")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)

def read_hex(name, count):
    values = [int(line.strip(), 16) for line in (args.vectors / name).read_text().splitlines() if line.strip()]
    if len(values) != count:
        raise ValueError(f"{name}: expected {count} values, got {len(values)}")
    return values

frame = bytearray()
for name, count, width in [
    ("conv1_weights.hex", 36, 1), ("conv1_bias.hex", 4, 4),
    ("conv2_weights.hex", 288, 1), ("conv2_bias.hex", 8, 4),
    ("fc_weights.hex", 2000, 1), ("fc_bias.hex", 10, 4),
    ("input_0.hex", 784, 1),
]:
    for value in read_hex(name, count):
        frame.extend(value.to_bytes(width, "little", signed=False))
assert len(frame) == 3196
logits = read_hex("logits_0.hex", 10)
(args.output / "frame_0.bin").write_bytes(frame)
(args.output / "frame_0.mem").write_text("".join(f"{v:02x}\n" for v in frame))
(args.output / "expected_logits_0.mem").write_text("".join(f"{v:08x}\n" for v in logits))
print(f"Prepared {len(frame)} input bytes and {len(logits)} reference logits in {args.output}")

