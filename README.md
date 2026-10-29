# PHP110 901 源码实验适配

用户选择以 PHP110 15.0.0.901 官方源码为基线，给当前 1301 设备制作实验适配。此目录独立于既有 5.15/6.6 源码和已测 KO。

当前交付是源码与构建入口，尚未完成 C 编译；没有预编译 PHP110 KO。不要把源码 ZIP 作为手机安装模块。

## 目标与基线

- 运行设备：OnePlus PHP110 / MT6983 / Android 15，固件 `PHP110_15.0.0.1301(CN01)`。
- 目标 release：`5.10.226-android12-9-o-g104a939c0e3e`。
- 官方源码：[OnePlusOSS Android 15 Ace 2V](https://github.com/OnePlusOSS/android_kernel_5.10_oneplus_mt6983/tree/cd19560616750906a568aa271d8b49ac17f13914)。固定提交 `cd19560616750906a568aa271d8b49ac17f13914`；提交说明对应 901。
- 配置：原始手机采集的完整配置，SHA256 `0fd19e2ba9114e47b80b3cd35792d8245deffb50887eba7c65e2a56b231fca70`。
- Revision：`qilin-php510-901-exp1`。

目标 release 字符串由实验构建显式设置，以通过模块版本字符串核对；这不表示源码提交是 `104a939c0e3e`，也不证明 901 与 1301 私有 ABI 一致。原厂源码身份和实验源码身份始终分开记录。

## 实现

- CPUINFO 使用 r5 PDE 操作表方案：复制原 proc_ops、仅替换 proc_open，保留原 read/read_iter/lseek/release/flags，静态 seq_operations 对应 seq_open。
- private layout 直接由固定 901 源码的 `fs/proc/internal.h` 中真实类型编译计算；不复制 5.15 的 inode/device 偏移，不声称有 1301 BTF。
- CPUINFO open 保留 901 源码中的 arch_freq_prepare_all 副作用。
- 保留 CPU 根 online/possible/present 显示、现有 CPU 的 core/package/die 显示、available frequencies 显示与 UTS release。
- boost 关闭：PHP110 采集的三个策略都未暴露对应节点。组合预期 8 个指针修改与 1 个 UTS 更新，共 9 项。
- 显示预设沿用项目 Kirin9020 / 12 核模板；频率字符串仅为显示模板，不改真实频率。
- 无挂载、无 inline hook、无代码页或页表权限修改；nproc/affinity、真实 CPU 数量、CPU8–11 目录、完整 topology mask 与 GPU 驱动均不扩展。
- 失败前置检查不发布回调；发布后持有模块引用，冲突保留状态，重启清理，不执行 rmmod。

## 构建

本机是 Windows，当前没有 Linux 编译器、Docker 或可用 Linux 构建环境，因而本次没有 C 编译日志与成功 KO。

源码包已包含 GitHub Actions 手动入口，也可在具备依赖的 Linux x86_64 主机执行 `bash build.sh`。它应固定下载 901 源码与 clang-r416183b，从捕获配置执行 olddefconfig，保留 Full LTO/Clang CFI/MODVERSIONS，完成 vmlinux/modules 构建产生真实 Module.symvers 后再构建外部模块。不会仅运行 modules_prepare 后伪称 CRC 完整。

构建资源可通过 QILIN_KERNEL_DIR / QILIN_CLANG_DIR 复用，但脚本会核对基线与版本；源码配置和厂商构建依赖仍可能出现真实编译错误。脚本按首个错误停止，不通过关闭 CFI、关闭 MODVERSIONS 或删 CRC 处理错误。

使用 Actions 时，上传源码包全部内容，保留隐藏的 .github 目录，运行 `PHP110 901 experimental module` 工作流。入口支持源码放仓库根目录或工作区同名子目录。工作流尚未远程触发。

## 验证与产物

verify_module.py 检查真实产物：AArch64 ELF、revision、目标 vermagic、901 source metadata、VFS namespace、8 个回调 DWARF、CFI symbol、编译所得 layout 数值、导入 CRC 与本次生成 Module.symvers 的一致性，以及与 1301 两个样本提供的 CRC 交集无冲突。

若样本的 module_layout 或其他交集 CRC 与构建不符，验证会失败；不会修改 CRC 冒充匹配。即使交集通过，报告仍明确 1301 完整 CRC 和 private layout 未获证明。

构建并验证成功后，手机用三个配套文件：cpuinfo_spoof.ko、build_report.json、run.sh；放同目录 ROOT 执行 run.sh 一次，输出一个日志包。源码阶段直接运行 run.sh 会提示缺少 KO/报告。已有旧版驻留时按提示重启，不强制卸载。

## 已完成检查

- 手机 run.sh 已通过真实 BusyBox ash -n 语法检查（Windows 移植版 ash，仅语法，不代表 Android 运行通过）。
- verify_module.py Python 编译检查与 5 个负例门禁已通过：旧 5.15 KO、2 个无关厂商 KO、空符号版本表、关闭 CFI。
- 36 个 feature 显示预设均存在于捕获 CPUINFO feature 集合。
- C 编译、完整构建、实际产物正例验证和手机加载尚未完成。详细状态见 LOCAL_CHECKS.json。

## 文件使用

手机端只使用生成产物中的 run.sh；build.sh 和 verify_module.py 用于构建主机。所有旧资料与证据保留。
