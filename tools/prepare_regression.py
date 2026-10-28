"""Create regression packets using the saved integer model and MNIST test images."""
from pathlib import Path
import argparse
import sys
import numpy as np

p = argparse.ArgumentParser()
p.add_argument("--reference-dir", type=Path, required=True)
p.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "data")
p.add_argument("--count", type=int, default=3)
args = p.parse_args()
sys.path.insert(0, str(args.reference_dir))
from mnist_int8_pipeline import IntegerMnistCNN

engine = IntegerMnistCNN.from_checkpoint(args.reference_dir / "quantized" / "mnist_cnn_int8.pth")
raw = (args.reference_dir / "data" / "MNIST" / "raw" / "t10k-images-idx3-ubyte").read_bytes()
labels = (args.reference_dir / "data" / "MNIST" / "raw" / "t10k-labels-idx1-ubyte").read_bytes()
base = (args.output / "frame_0.bin").read_bytes()
frames = bytearray()
expected = []
for idx in range(args.count):
    pixels = np.frombuffer(raw, dtype=np.uint8, count=784, offset=16+idx*784)
    image = pixels.astype(np.float32).reshape(1,1,28,28) / np.float32(255.0)
    q = engine.quantize_input(image)
    scores = engine.forward_quantized(q)[0]
    frame = base[:2412] + q.tobytes()
    if idx == 0 and frame != base:
        raise ValueError("The first dataset sample differs from the exported golden image")
    frames.extend(frame)
    expected.extend(int(x) & 0xffffffff for x in scores)
    print(f"sample {idx}: label={labels[8+idx]}, prediction={int(scores.argmax())}")
(args.output / "frames_regression.mem").write_text("".join(f"{x:02x}\n" for x in frames))
(args.output / "logits_regression.mem").write_text("".join(f"{x:08x}\n" for x in expected))
print(f"Prepared {args.count} frames and {len(expected)} logits.")

