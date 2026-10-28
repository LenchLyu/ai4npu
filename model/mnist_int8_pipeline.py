"""当前三层 MNIST CNN 的整数参考模型、评估与导出工具。

在 Notebook 中导入 run_quantized_evaluation，传入已经得到的浮点模型、
INT8 权重、激活尺度和数据加载器。导入本文件不会执行训练或评估。

权重保存为 INT8，偏置和卷积/全连接累加使用 INT32。参考推理在 CPU
上使用 NumPy 整数运算；浮点运算用于输入编码、参数尺度与偏置转换。
"""

import json
import math
from pathlib import Path

import numpy as np
import torch


_LAYOUT = (
    ("conv1", "0", "input", "pool1", (4, 1, 3, 3)),
    ("conv2", "3", "pool1", "pool2", (8, 4, 3, 3)),
    ("fc", "7", "pool2", None, (10, 200)),
)
_FORMAT = "mnist_int8_reference_v1"


def _scale(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError("量化尺度必须为有限的正数。")
    if math.frexp(value)[0] != 0.5:
        raise ValueError("本参考模型要求量化尺度为 2 的整数次幂。")
    return value


def _check_accumulator(weight, bias):
    # 对输入 0..127，保守检查所有乘加中间值和偏置均不会导致溢出。
    w64 = weight.astype(np.int64).reshape(weight.shape[0], -1)
    bound = 127 * np.abs(w64).sum(axis=1) + np.abs(bias.astype(np.int64))
    maximum = int(bound.max())
    if maximum > np.iinfo(np.int32).max:
        raise OverflowError("该层的保守累加上界超出 INT32 范围。")
    return maximum


def _build_package(model, quantized_weights, activation_scales):
    parameters = dict(model.named_parameters())
    layers = {}
    limits = torch.iinfo(torch.int32)

    for name, prefix, input_key, output_key, shape in _LAYOUT:
        info = quantized_weights[f"{prefix}.weight"]
        weight = info["weight_int8"].detach().cpu().contiguous().clone()
        if weight.dtype != torch.int8 or tuple(weight.shape) != shape:
            raise ValueError(f"{name} 的权重应为 INT8，形状应为 {shape}。")
        if int(weight.min()) < -127:
            raise ValueError("当前对称权重范围为 -127..127。")

        input_scale = _scale(activation_scales[input_key])
        weight_scale = _scale(info["scale"])
        accumulator_scale = _scale(input_scale * weight_scale)
        bias = parameters[f"{prefix}.bias"].detach().cpu().double()
        if tuple(bias.shape) != (shape[0],):
            raise ValueError(f"{name} 的偏置形状不匹配。")
        rounded_bias = torch.round(bias / accumulator_scale)
        if not torch.isfinite(rounded_bias).all().item():
            raise ValueError(f"{name} 的偏置含有非有限数值。")
        if rounded_bias.min().item() < limits.min or rounded_bias.max().item() > limits.max:
            raise OverflowError(f"{name} 的量化偏置超出 INT32 范围。")
        bias_int32 = rounded_bias.to(torch.int32)

        if output_key is None:
            output_scale = accumulator_scale
            output_shift = None
        else:
            output_scale = _scale(activation_scales[output_key])
            output_shift = int(round(math.log2(output_scale / accumulator_scale)))

        bound = _check_accumulator(weight.numpy(), bias_int32.numpy())
        layers[name] = {
            "weight_int8": weight,
            "bias_int32": bias_int32,
            "input_scale": input_scale,
            "weight_scale": weight_scale,
            "accumulator_scale": accumulator_scale,
            "output_scale": output_scale,
            "output_shift": output_shift,
            "accumulator_abs_bound": bound,
        }

    return {
        "format": _FORMAT,
        "architecture": "Conv1-ReLU-Pool2-Conv2-ReLU-Pool2-Flatten-FC",
        "input_shape": [1, 28, 28],
        "input_scale": _scale(activation_scales["input"]),
        "rounding": "nearest_even",
        "activation_range": [0, 127],
        "layers": layers,
    }


def _conv2d_int32(x, weight, bias):
    n, channels, height, width = x.shape
    out_channels, in_channels, kh, kw = weight.shape
    if channels != in_channels:
        raise ValueError("卷积输入通道数不匹配。")
    oh, ow = height - kh + 1, width - kw + 1
    windows = np.lib.stride_tricks.sliding_window_view(x, (kh, kw), axis=(2, 3))
    columns = windows.transpose(0, 2, 3, 1, 4, 5).reshape(n * oh * ow, -1)
    columns = columns.astype(np.int32)
    result = columns @ weight.reshape(out_channels, -1).T
    result += bias
    return result.reshape(n, oh, ow, out_channels).transpose(0, 3, 1, 2)


def _relu_requantize(accumulator, shift):
    # INT64 只用于移位与舍入，避免处理舍入位时溢出；MAC 本身是 INT32。
    x = np.maximum(accumulator.astype(np.int64), 0)
    shift = int(shift)
    if shift >= 32:
        return np.zeros(x.shape, dtype=np.int8)
    if shift <= -7:
        return np.where(x > 0, 127, 0).astype(np.int8)
    if shift < 0:
        result = np.minimum(x, 127) << (-shift)
    elif shift == 0:
        result = x
    else:
        result = x >> shift
        remainder = x & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        increment = (remainder > half) | ((remainder == half) & ((result & 1) == 1))
        result = result + increment.astype(np.int64)
    return np.clip(result, 0, 127).astype(np.int8)


def _maxpool2(x):
    n, channels, height, width = x.shape
    oh, ow = height // 2, width // 2
    cropped = x[:, :, :oh * 2, :ow * 2]
    return cropped.reshape(n, channels, oh, 2, ow, 2).max(axis=(3, 5))


class IntegerMnistCNN:
    """与当前 CNN 对应的 CPU 整数参考推理器，最终返回 INT32 logits。"""

    def __init__(self, package):
        if package.get("format") != _FORMAT:
            raise ValueError("不支持的整数模型文件格式。")
        if package.get("rounding") != "nearest_even" or package.get("activation_range") != [0, 127]:
            raise ValueError("模型文件的舍入规则或激活范围不匹配。")
        self.package = package
        self.input_scale = _scale(package["input_scale"])
        self.layers = {}
        for name, _, _, _, shape in _LAYOUT:
            layer = package["layers"][name]
            weight = layer["weight_int8"].detach().cpu()
            bias = layer["bias_int32"].detach().cpu()
            if weight.dtype != torch.int8 or tuple(weight.shape) != shape:
                raise ValueError(f"{name} 权重的形状或类型不匹配。")
            if bias.dtype != torch.int32 or tuple(bias.shape) != (shape[0],):
                raise ValueError(f"{name} 偏置的形状或类型不匹配。")
            if int(weight.min()) < -127:
                raise ValueError("当前对称权重范围为 -127..127。")
            _check_accumulator(weight.numpy(), bias.numpy())
            shift = layer["output_shift"]
            if (name == "fc") != (shift is None):
                raise ValueError(f"{name} 的输出移位配置不匹配。")
            self.layers[name] = {
                "weight": weight.numpy().astype(np.int32),
                "bias": bias.numpy().copy(),
                "shift": shift,
            }

    @classmethod
    def from_checkpoint(cls, path):
        with Path(path).open("rb") as f:
            package = torch.load(f, map_location="cpu", weights_only=True)
        return cls(package)

    def quantize_input(self, images):
        if isinstance(images, torch.Tensor):
            images = images.detach().cpu().numpy()
        images = np.asarray(images, dtype=np.float64)
        if images.ndim != 4 or tuple(images.shape[1:]) != (1, 28, 28):
            raise ValueError("输入形状必须为 [N, 1, 28, 28]。")
        if not np.isfinite(images).all() or np.any(images < 0) or np.any(images > 1):
            raise ValueError("浮点输入必须为 ToTensor 后位于 0..1 的图片。")
        return np.clip(np.rint(images / self.input_scale), 0, 127).astype(np.int8)

    def forward_quantized(self, input_int8):
        x = np.asarray(input_int8)
        if x.dtype != np.int8 or x.ndim != 4 or tuple(x.shape[1:]) != (1, 28, 28):
            raise ValueError("整数输入必须为 INT8，形状为 [N, 1, 28, 28]。")
        if x.shape[0] == 0 or np.any(x < 0):
            raise ValueError("整数输入需要非空，且位于 0..127。")
        for name in ("conv1", "conv2"):
            layer = self.layers[name]
            acc = _conv2d_int32(x, layer["weight"], layer["bias"])
            x = _maxpool2(_relu_requantize(acc, layer["shift"]))
        fc = self.layers["fc"]
        x = x.reshape(x.shape[0], 200).astype(np.int32)
        return x @ fc["weight"].T + fc["bias"]

    def forward(self, images):
        return self.forward_quantized(self.quantize_input(images))

    def predict(self, images):
        return self.forward(images).argmax(axis=1)


def _accuracy(engine, loader):
    correct = 0
    total = 0
    for images, labels in loader:
        predictions = engine.predict(images)
        if isinstance(labels, torch.Tensor):
            labels = labels.detach().cpu().numpy()
        labels = np.asarray(labels)
        correct += int((predictions == labels).sum())
        total += len(labels)
    if total == 0:
        raise ValueError("评估数据集为空。")
    return correct / total, total


def run_quantized_evaluation(
    model,
    quantized_weights,
    activation_scales,
    val_loader,
    test_loader,
    *,
    fp32_val_acc,
    fp32_test_acc,
    max_drop_pp=1.0,
    min_test_acc=0.96,
    output_path="./quantized/mnist_cnn_int8.pth",
):
    """构建整数模型、评估并保存；验证达标后才运行最终测试集评估。

    fp32_*_acc 以 0..1 表示；max_drop_pp 以百分点表示。
    无论验证是否达标，都会保存模型参数和报告，供后续定位。
    """
    baselines = (float(fp32_val_acc), float(fp32_test_acc))
    if not all(math.isfinite(v) and 0 <= v <= 1 for v in baselines):
        raise ValueError("FP32 准确率应为 0..1 之间的有限数值。")
    max_drop_pp = float(max_drop_pp)
    min_test_acc = float(min_test_acc)
    if not math.isfinite(max_drop_pp) or max_drop_pp < 0:
        raise ValueError("允许的准确率下降必须是非负的有限数值。")
    if not math.isfinite(min_test_acc) or not 0 <= min_test_acc <= 1:
        raise ValueError("最低测试准确率应位于 0..1。")

    package = _build_package(model, quantized_weights, activation_scales)
    engine = IntegerMnistCNN(package)
    print("Evaluating INT8 validation accuracy on CPU...", flush=True)
    val_acc, val_count = _accuracy(engine, val_loader)
    val_drop = (baselines[0] - val_acc) * 100
    val_pass = val_drop <= max_drop_pp + 1e-12
    print(f"FP32 validation accuracy: {baselines[0]:.2%}")
    print(f"INT8 validation accuracy: {val_acc:.2%}")
    print(f"Validation accuracy drop: {val_drop:.2f} percentage points")

    report = {
        "fp32_validation_accuracy": baselines[0],
        "int8_validation_accuracy": val_acc,
        "validation_samples": val_count,
        "validation_drop_pp": val_drop,
        "validation_pass": val_pass,
        "fp32_test_accuracy": baselines[1],
        "int8_test_accuracy": None,
        "test_drop_pp": None,
        "test_pass": None,
        "max_drop_pp": max_drop_pp,
        "min_test_accuracy": min_test_acc,
        "overall_pass": False,
    }
    if val_pass:
        print("Evaluating final INT8 test accuracy on CPU...", flush=True)
        test_acc, test_count = _accuracy(engine, test_loader)
        test_drop = (baselines[1] - test_acc) * 100
        test_pass = test_drop <= max_drop_pp + 1e-12 and test_acc + 1e-12 >= min_test_acc
        report.update({
            "int8_test_accuracy": test_acc,
            "test_samples": test_count,
            "test_drop_pp": test_drop,
            "test_pass": test_pass,
            "overall_pass": test_pass,
        })
        print(f"FP32 test accuracy: {baselines[1]:.2%}")
        print(f"INT8 test accuracy: {test_acc:.2%}")
        print(f"Test accuracy drop: {test_drop:.2f} percentage points")
    else:
        print("Validation below target; use the validation set to diagnose before final testing.")

    weight_count = sum(layer["weight_int8"].numel() for layer in package["layers"].values())
    bias_count = sum(layer["bias_int32"].numel() for layer in package["layers"].values())
    report["weight_count"] = weight_count
    report["bias_count"] = bias_count
    report["raw_parameter_bytes"] = weight_count + bias_count * 4
    report["scales_and_shifts"] = {
        name: {key: value for key, value in layer.items() if not isinstance(value, torch.Tensor)}
        for name, layer in package["layers"].items()
    }

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report_path = output_path.with_suffix(".json")
    report["model_path"] = str(output_path.resolve())
    report["report_path"] = str(report_path.resolve())
    package["metrics"] = report.copy()
    # Python 打开文件后交给 torch.save，兼容当前环境中的中文路径。
    with output_path.open("wb") as f:
        torch.save(package, f)
    report["checkpoint_file_bytes"] = output_path.stat().st_size
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Parameters: {weight_count} INT8 weights + {bias_count} INT32 biases")
    print(f"Raw parameter bytes: {report['raw_parameter_bytes']}")
    print("Result:", "PASS" if report["overall_pass"] else "NEEDS REVIEW")
    print("Saved model:", output_path)
    print("Saved report:", report_path)
    return engine, report
