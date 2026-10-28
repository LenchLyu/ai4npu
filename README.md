# ai4npu：从 MNIST CNN 到 FPGA 推理原型

这是一个围绕学习 FPGA 神经网络加速器搭建的实验项目：将训练好的 MNIST CNN 量化为整数模型，再用 3×3 卷积计算模块、最大池化、全连接和 AXI DMA 实现推理数据通路。目标器件为 ZCU104（`xczu7ev-ffvc1156-2-e`），工程使用 Vivado 2026.1。

> **状态：未经过实板验证。** 核心行为仿真和 Vivado 实现已完成；PS 软件、DMA、DDR 与计算核心的完整链路及实板推理准确率尚未验证。软件参考模型的准确率不能当作 FPGA 实测准确率。

## 系统架构

```text
PS 软件 ──AXI-Lite──► DMA 控制寄存器
                         │
DDR ──AXI──► DMA MM2S ──AXI Stream──► MNIST 计算核心
DDR ◄──AXI── DMA S2MM ◄──AXI Stream── 10 个 INT32 logits
```

Block Design 使用 Zynq UltraScale+ PS、双向 AXI DMA、AXI SmartConnect、100 MHz Clocking Wizard 和复位模块。DMA 采用简单模式，内存和流接口均为 64 bit。PS 控制软件示例只作为后续上板工作的起点，尚未编译或运行验证。

计算核心接收包含权重、偏置和单张图像的数据包，复用一个 3×3 点积模块和一个 2×2 最大池化模块完成两层卷积，再逐项累加完成 FC。模块使用 valid/ready 握手输出结果；计算核心中的点积模块不是数据逐拍在 3×3 PE 间传播的脉动阵列。

## 网络和量化

```text
1×28×28 → Conv(1,4,3×3) → ReLU/量化 → MaxPool(2×2)
          → Conv(4,8,3×3) → ReLU/量化 → MaxPool(2×2)
          → Flatten(200) → FC(200,10) → 10 个 INT32 logits
```

- 输入与权重采用 INT8，偏置和层间累加采用 INT32；卷积输出经过 ReLU、重新量化及饱和。
- Conv1 与 Conv2 的量化右移量分别为 8 和 7，舍入规则为 nearest-even；这些数值只对应当前模型。
- 共 2,324 个权重和 22 个偏置；原始整数参数共 2,412 字节。完整 `.pth` 文件还包含序列化元数据，大小不同属正常情况。
- 保存的 Python 参考报告记录 FP32 与 INT8 测试集准确率均为 98.18%；这是原训练/软件评估结果，不是 FPGA 实测结果。

## DMA 输入和输出

每次输入固定为 3,196 字节，依次包含：

| 内容 | 字节偏移 | 字节数 |
|---|---:|---:|
| Conv1 INT8 权重 | 0 | 36 |
| Conv1 INT32 偏置 | 36 | 16 |
| Conv2 INT8 权重 | 52 | 288 |
| Conv2 INT32 偏置 | 340 | 32 |
| FC INT8 权重 | 372 | 2,000 |
| FC INT32 偏置 | 2,372 | 40 |
| INT8 输入图像 | 2,412 | 784 |

INT32 按小端字节序排列。64 bit 输入流共 400 拍，末拍 4 字节有效；输出为 40 字节、5 拍，含 10 个 INT32 logits。当前每张图像重新发送全部权重，核心接收一拍后按字节处理，因此并非每时钟都能接收一个 64 bit beat。

## 仓库内容

| 路径 | 内容 |
|---|---|
| `rtl/` | 计算核心、3×3 卷积模块、池化模块 |
| `sim/`、`data/` | 自检 testbench、输入包与参考结果 |
| `model/checkpoints/` | 训练得到的 FP32 权重 |
| `model/quantized/` | INT8 模型权重和量化参数及软件评估报告 |
| `model/fpga_vectors/` | 分层权重、偏置、样本图像、参考 logits 和格式元数据 |
| `model/*.ipynb`、`model/mnist_int8_pipeline.py` | 网络、训练和整数参考实现；Notebook 输出已清除 |
| `RevisionControl/` | 可重建的 Block Design Tcl、RTL、仿真文件和工程设置 |
| `software/` | Vitis standalone 单样本示例，**未经编译和实板验证** |
| `docs/TECHNICAL.md` | 实现细节、AI 参与范围与验证记录 |

MNIST 全量数据集不包含在仓库中；Notebook 和脚本需要数据集时，请按 torchvision 的 MNIST 数据集加载流程获取。

## 重建 Vivado 工程

需要 Vivado 2026.1、对应 ZCU104 board files 和器件支持。在仓库根目录启动终端并运行：

```powershell
vivado -mode batch -source RevisionControl/Scripts/build.tcl
```

脚本默认在 `build/vivado/` 下创建工程；若已存在同名工程，会停止而非覆盖。若 `vivado` 不在 PATH，请改用本机 Vivado 的完整路径。重新生成 IP 和工程可能需要较长时间；重建完成后，在 Vivado 打开生成的 `ai4npu.xpr`。

`sim_1` 默认顶层为 `tb_mnist_regression`。在重建工程中运行 **Run Simulation → Run Behavioral Simulation**，成功时应看到：

```text
TEST_PASS: 3 samples, 30 exact logits and output backpressure
```

`RevisionControl/Sources/` 是导出时的源码快照，重建脚本使用该目录。若以后修改 `rtl/`、`sim/` 或 `data/`，需要同步更新对应快照，或重新导出并检查重建脚本；否则重建工程仍会使用旧版本。

也可从仓库根目录用 Python 重建单样本输入包：

```powershell
python tools/pack_mnist_frame.py --vectors model/fpga_vectors --output data
```

`prepare_regression.py` 另需 NumPy、PyTorch、原始 MNIST 测试数据和 `model/` 中的参考模型。测试数据应放在 `model/data/MNIST/raw/`，再使用 `--reference-dir model`。

## 已验证与待完成

- 核心 RTL 行为仿真：3 张图像的 30 个 INT32 logits 与软件整数参考逐项一致，同时检查输出背压。
- 设计综合、布局布线已运行；原工程路由报告 WNS 为 +1.370 ns，所设置的时序约束满足。该结果仅针对当前器件、工具版本和约束。
- 未完成 PS 软件/BSP 编译、真实 DDR/DMA 端到端测试、ZCU104 上板测试及全测试集硬件准确率评估。
- 当前 `frame_error` 未连接到软件可读状态寄存器；无效数据包可能需要复位恢复。缓存被大量展开为寄存器，后续需要优化存储和数据复用。

## 一点碎碎念

这是我学习神经网络和 FPGA 的一个起点。项目里有我训练的模型、我尝试编写的计算模块，也有大量由 AI 协助设计、实现和调试的部分。它能跑通一些仿真，并不意味着我已经理解了每一行代码或掌握了完整的工程设计。

希望以后回头看这个项目时，我已经能自己说清楚每一条数据从哪里来、为什么这样走，也能独立设计、验证并优化这样的系统。现在就从读懂它开始。
