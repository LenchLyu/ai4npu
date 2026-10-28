"""Copy model artifacts for publication while clearing notebook output paths."""
import argparse
import json
from pathlib import Path
import re
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path, help='Original MNIST project directory')
args = parser.parse_args()
dest = Path(__file__).resolve().parents[1] / 'model'
dest.mkdir(exist_ok=True)
for subdir in ('checkpoints', 'quantized', 'fpga_vectors'):
    (dest / subdir).mkdir(exist_ok=True)
for rel in ('checkpoints/mnist_cnn_best.pth', 'quantized/mnist_cnn_int8.pth',
            'mnist_int8_pipeline.py', 'network_spec.md'):
    shutil.copy2(args.source / rel, dest / rel)
for file in (args.source / 'fpga_vectors').iterdir():
    if file.is_file():
        shutil.copy2(file, dest / 'fpga_vectors' / file.name)
report = json.loads((args.source / 'quantized/mnist_cnn_int8.json').read_text(encoding='utf-8'))
report.pop('model_path', None)
report.pop('report_path', None)
(dest / 'quantized/mnist_cnn_int8.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
for name in ('mnist_cnn_train.ipynb', 'network_architecture.ipynb',
             'network_data_structure.ipynb'):
    notebook = json.loads((args.source / name).read_text(encoding='utf-8'))
    for cell in notebook.get('cells', []):
        if cell.get('cell_type') == 'code':
            cell['outputs'] = []
            cell['execution_count'] = None
            cell['source'] = [re.sub(
                r'r"[^"\n]*[\\/]+checkpoints[\\/]+mnist_cnn_best\.pth"',
                '"./checkpoints/mnist_cnn_best.pth"', line)
                for line in cell.get('source', [])]
    (dest / name).write_text(json.dumps(notebook, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
print('Imported reference model, weight files, vectors and cleaned notebooks to', dest)
