# 技术报告代码

本包仅包含四类代码及本说明，使用最终实物板测试对应的设计版本。

## 01_ASIP_Verilog

ASIP Designer 生成的 trv32p5 处理器 Verilog，来自最后上板工程使用的 core 目录。包含顶层、控制器、寄存器、运算逻辑及 primitives.v 头文件，多精度乘法功能已在处理器内部实现。

## 02_MATLAB

- fir_multiplier_demo.m：原始 MATLAB FIR 多精度数值验证程序。
- fir_snr_eval.m：技术报告中六个 SNR 值对应的计算代码，使用与实际 FIR C 程序一致的定点输出进行分析。
- prepare_snr.py：调用 GCC 编译 03_FIR_C 中的程序，校验并生成 SNR 计算需要的 fir_snr/fir_outputs.csv。先运行本脚本，再在 MATLAB 中运行 fir_snr_eval.m。数据在运行时生成，未随本包提交。

原 MATLAB 示例和报告 SNR 计算的量化设置不同；报告六个数值以 fir_snr_eval.m 为准。

## 03_FIR_C

实际在 trv32p5_ca 周期模拟器上运行的 optimized_v1 FIR C 程序，包括主测试程序、FIR 内核、参考校验、头文件及 fir.prx。generate_fixture.py 用于生成输入/系数头文件，verify_host.py 用于主机功能校验，也供 MATLAB 数据导出脚本使用。

ASIP 环境采用 Release 配置。使用 fir.prx 时，将本目录内容放入已有 trv32p5 模型的 examples/fir_mulp 目录，保持工程中 ../../lib 路径有效。预期最终校验和为 DA689FDC。

## 04_Vivado_Board

最终 FACE-VUP-PRO 实物板实验使用的板级代码：

- rtl：处理器与程序/数据存储器连接、BRAM 实现、时钟与复位、ILA/VIO 接口。
- mem：最后一次上板程序的 BRAM 初始化映像，属于工程运行所需输入文件。程序完成 24 组多精度乘法及相关数据依赖、存储访问测试。
- board_pending.xdc：保留最终工程文件名，其中时钟引脚和电气标准已经确认并通过上板验证。
- create_project.tcl：使用相邻 01_ASIP_Verilog 中的处理器代码创建 Vivado 工程，并生成 ILA/VIO IP。
- build_bitstream.tcl：运行综合、布局布线、检查并生成 bit/ltx 文件。

Vivado 版本为 2021.2，器件为 xcvu13p-fhgb2104-2-i。建议解压到无空格英文路径。在 Vivado 命令环境依次运行：

```text
vivado -mode batch -source 04_Vivado_Board/create_project.tcl
vivado -mode batch -source 04_Vivado_Board/build_bitstream.tcl
```

板载 200 MHz 差分时钟采用 P=AE31、N=AE32、DIFF_SSTL12，经 MMCM 生成 100 MHz。程序与数据存储器各 4 KiB；初始化程序随比特流加载。下载后先布防 ILA，再通过 VIO 将复位请求从 1 置 0。通过状态为 status=600D600D、failure_id=0、fault=0。

本板级程序对应报告中的实物指令测试；FIR 应用性能对应 03_FIR_C 的周期模拟器实验。create_project.tcl 仅调整了处理器目录引用并省去仿真文件导入，设计 RTL、约束和程序映像保持最终上板版本。
