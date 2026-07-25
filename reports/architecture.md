# FPGA 架构与接口说明

## 1. 总体数据流

```text
AXI4-Lite
   |
   +-- 寄存器/BRAM数据窗口
   |
   +-- 任务调度状态机
          |
          +-- task 0: Tanimoto
          +-- task 1: GNN message passing
          +-- task 2: ADMET predictor
          +-- task 3: Tanimoto -> GNN -> ADMET
```

顶层状态顺序为：

```text
IDLE -> LOAD -> EXECUTE -> OUTPUT -> DONE -> IDLE
```

`start` 只在空闲状态接受。运行中再次提交命令不会覆盖当前任务，并会设置
错误状态位。

## 2. 数值格式

| 数据 | 格式 | 说明 |
|---|---|---|
| Tanimoto 输出 | unsigned Q16.16 | 1.0 = `0x00010000` |
| GNN/FC 特征和权重 | signed Q8.8 | 1.0 = `0x0100` |
| ReLU 输出 | signed Q8.8 非负区间 | 负值归零，正溢出饱和 |
| Sigmoid 输出 | Q8.8 | 0.5 = `0x0080`，1.0 = `0x0100` |

GNN 和 FC 的乘法结果为 Q16.16，累加完成后右移 8 位恢复 Q8.8。

## 3. Tanimoto

计算：

```text
intersection = popcount(query_fp AND db_fp)
union        = popcount(query_fp OR db_fp)
similarity   = (intersection << 16) / union
```

popcount 使用 32 位分组和平衡加法树。除法使用 27 次迭代的无符号恢复除法，
不依赖 Xilinx Divider IP。两个输入均为零时输出零并产生正常 `valid`。

## 4. GNN

每个节点执行：

```text
aggregate[node][feature]
    = sum(features[neighbor][feature]) for adjacency[node][neighbor] == 1

output[node][hidden]
    = ReLU(sum(aggregate[node][feature] * weight[feature][hidden]))
```

生产模式 `PACKED_IO=0` 使用：

- 32 位 feature BRAM 写端口；
- 32 位 adjacency 写端口；
- 16 位权重写端口；
- 32 位同步输出读端口；
- 一个复用乘法器。

默认参数的仿真延迟为：

```text
50 nodes × 11,651 cycles/node = 582,550 cycles
582,550 / 100 MHz = 5.8255 ms
```

因此逻辑周期数满足任务中的 `<10 ms @ 100 MHz` 指标。100 MHz 本身仍需
Vivado 时序报告证明。

## 5. FC 和 ADMET

`fc_network` 的地址布局：

| cfg_layer | 内容 | 地址 |
|---:|---|---|
| 0 | 输入层到隐藏层权重 | `input*HIDDEN_DIM + hidden` |
| 1 | 隐藏层偏置 | `hidden` |
| 2 | 隐藏层到输出层权重 | `hidden*OUTPUT_DIM + output` |
| 3 | 输出层偏置 | `output` |

`admet_predictor` 并行实例化四个 `20 -> 10 -> 1` FC 网络，分别输出
logP、oral bioavailability、hERG IC50 和 BBB permeability。当前硬件输出
是归一化 Sigmoid 值；若训练模型要求物理单位，需要由软件按训练时的缩放
参数执行反归一化。

## 6. AXI4-Lite 地址

| 地址 | 方向 | 内容 |
|---|---|---|
| `0x0000` | W | 控制：bit0 start，bits[2:1] task，bit8 清状态 |
| `0x0004` | R | 状态：bit0 busy，bit1 done，bit2 error，bits[5:4] task |
| `0x0100-0x017C` | R/W | query fingerprint，32 个字 |
| `0x0180-0x01FC` | R/W | database fingerprint，32 个字 |
| `0x0200` | R | Tanimoto Q16.16 结果 |
| `0x0300-0x0324` | R/W | 20 个 Q8.8 descriptors |
| `0x0340-0x034C` | R | 四个 ADMET 结果 |
| `0x0400` | W | GNN 权重数据 |
| `0x0404` | W | GNN 权重提交，bits[12:0] 为地址 |
| `0x0410` | W | ADMET 权重/偏置数据 |
| `0x0414` | W | ADMET 提交：model、layer、address |
| `0x1000-0x1138` | W | 50×50 邻接矩阵 |
| `0x2000-0x38FC` | W | 50×64 个 Q8.8 输入特征 |
| `0x4000-0x71FC` | R | 50×128 个 Q8.8 GNN 输出 |

原任务写的 `0x08-0xFF` 只有 248 字节，连两个 1024 位指纹所需的
256 字节都无法容纳，因此实现使用了扩展地址图。

## 7. 需要 Vivado 确认的指标

- `create_clock -period 10.000` 是否满足；
- Tanimoto LUT `<5000`、FF `<2000`；
- GNN BRAM `<20`、DSP `<50`；
- RAM 是否按预期推断为 Block RAM；
- AXI 顶层实现后的 WNS、TNS 和最大频率；
- 最终 bitstream 是否能在目标板上烧录运行。
