# MoerEngine 自适应稀疏体积辐射缓存实现报告

日期：2026-08-03  
状态：当前计划范围已完成并通过构建、运行、调试视图和性能验证。

## 1. 目标与定位

本功能在现有视锥 Froxel 体积雾之外增加稳定的世界空间体积辐射缓存。它复用 MoerEngine
动态稀疏 Probe GI 的 Volume、Cell、Brick、Page Table、物理页驻留、Streaming、Dirty
Tracking 与更新预算，同时保存独立的参与介质辐射数据。

这不是把表面 Probe GI 直接乘进雾，而是用表面 DDGI 作为低频边界光源，再执行介质消光、
光源可见性和历史多次散射反馈。这样既保留 Moer 的稀疏世界空间结构，也避免混淆“表面辐照度”
和“介质入射辐射”。

## 2. 已完成的功能

### 2.1 自适应稀疏布局与调度

- 对每个 Probe Cell 采样中心与 8 个角点，估计全局指数高度雾和局部球形雾的平均密度。
- 计算相对密度梯度、屏幕贡献和介质优先级。
- 将介质期望层级与原有几何期望层级合并；高密度、高梯度或高屏幕贡献区域优先细化。
- 稀疏工作集是表面需求与介质需求的并集，继续使用原有 Page Table、物理分配器和 Streaming。
- 更新调度在 mandatory/dirty 优先级之后加入介质优先级和更新年龄，受每帧 Brick 预算约束。
- 运行日志输出 medium active/fine cells、密度、梯度、屏幕贡献、优先级和调度统计。

默认参数：

| 参数 | 默认值 | 作用 |
|---|---:|---|
| Density Threshold | 0.0010 | 判断 Cell 是否需要体积缓存 |
| Gradient Threshold | 0.18 | 密度变化较大时细化 |
| Screen Weight | 1.0 | 屏幕贡献权重 |
| Priority Weight | 2.0 | 更新调度中的介质优先级权重 |
| History Weight | 0.88 | 双缓冲历史融合 |
| Multi Scatter | 0.12 | 受控的近似高阶散射反馈 |
| Transmittance Steps | 6 | 介质光学深度积分步数，可调 2--12 |

### 2.2 独立 L1 方向辐射缓存

- 每个物理 Probe 保存 L0、L1-X/Y/Z、源世界坐标、置信度和调试元数据。
- 最多 2048 个物理 Probe；单份缓存 163,840 字节。
- 采用 history/write 双缓冲，更新前复制未调度记录，随后只覆盖本帧稀疏 Brick，最后交换。
- 双缓冲共 327,680 字节，即 0.3125 MiB；没有新增密集 3D 辐射纹理。
- 世界坐标与物理页验证可阻止页重映射后读取陈旧数据。
- 查询保留自适应层级、驻留验证、粗层回退、层级过渡和多 Volume 混合。

### 2.3 介质感知传输

- 保留表面 DDGI 方向辐照度作为稳定的低频边界辐射。
- 独立计算全局与局部介质消光。
- 沿光线执行 2--12 步光学深度与 Beer-Lambert 透射率积分。
- Ray Query 路径对方向光、点光与聚光灯执行不透明几何可见性测试；无 TLAS 时使用 fallback。
- 第一阶直接光先转换为介质散射源再缓存，避免在 Froxel 注入阶段重复计算一次散射。
- 从上一帧缓存采样 6 个邻居并按透射率衰减，提供受控的近似多次散射反馈。
- 双缓冲消除了原先同一 RWBuffer 内邻居读写的竞争和帧内顺序依赖。

### 2.4 Froxel 注入与调试

- 每个 `4x4x4` Froxel 工作组共享一次世界空间缓存查询，降低查询开销。
- 缓存不可用时保留旧表面 Probe 近似作为兼容回退。
- 编辑器提供 12 种体积雾调试模式，其中缓存相关模式为：
  - Radiance Cache L0/L1
  - Radiance Cache Coverage
  - Radiance Cache Adaptive Level
  - Radiance Cache Update Age
  - Radiance Cache Transport Activity
- 调试元数据通过两张 RGBA16F 二维切片输出，不污染主积分体积。

## 3. 最终运行验证

测试环境：Vulkan，RTX 4060 Laptop GPU，Sponza，1920x1080，Debug 构建。

- Debug 构建成功，退出码 0。
- 所有新增 Shader 编译成功，无 Shader error、access violation、assert 或 fatal。
- 双缓冲句柄为 `(90, 91)`，总缓存显存为 327,680 字节。
- 两个 Probe Volume、12/12 Brick、584/584 Probe 全部驻留。
- 介质分析得到 2/2 active cells、2/2 fine cells。
- 两个 Cell 的介质优先级分别为 1.513 和 1.814。
- 缓存更新预算为每帧 2 个 Brick；日志确认 Ray Query medium-transport update 持续执行。
- 最终覆盖率热图为全蓝，对应当前调试色标中的 coverage=1；该场景两个 Cell 都被几何和介质判定为 fine，因此画面均匀是预期结果。

### 3.1 GPU 性能

稳定后连续 20 个一秒采样的均值：

| 项目 | 均值 | 标准差 | 范围 |
|---|---:|---:|---:|
| VRC 稀疏更新 | 0.0639 ms | 0.0014 ms | 0.062--0.067 ms |
| Fog Injection | 0.4091 ms | 0.0002 ms | 0.409--0.410 ms |
| Fog Total | 1.3102 ms | 0.0006 ms | 1.309--1.311 ms |
| Graphics Exec | 15.4633 ms | 0.1724 ms | 14.970--15.718 ms |

缓存更新开销约占雾总时间的 4.9%，约占整帧 GPU 时间的 0.4%。更新量受每帧 2 Brick 预算限制，
所以不会随整个世界空间体积线性增长。

### 3.2 画面开关消融

同一固定视角、相同曝光下比较缓存开启和关闭：

- RGB 平均绝对差：`(2.445, 2.172, 2.221)` / 255。
- RGB RMS 差：`(4.149, 3.753, 3.654)` / 255。
- 超过 2 级 RGB 差异的像素比例：42.0%。
- 变化主要是遮挡区和有色灯附近的低频间接雾光；效果有统计显著性，但默认强度不会把画面洗白。

## 4. 证据位置

- 最终运行日志：`saved/codex-logs/MoerEditor-VRC-Verified-20260803-014638.stdout.log`
- 最终主画面：`saved/volumetric_fog/vrc/final_verified_main.jpg`
- 最终覆盖率热图：`saved/volumetric_fog/vrc/final_debug_coverage.jpg`
- 缓存开启画面：`saved/volumetric_fog/vrc/final_cache_on.jpg`
- 缓存关闭画面：`saved/volumetric_fog/vrc/final_cache_off.jpg`
- 其余调试图：`debug_adaptive_level.jpg`、`debug_update_age.jpg`、`debug_transport_activity.jpg`

## 5. 完成边界

当前实现已经形成可运行、可调、可测的自适应稀疏体积辐射缓存闭环。它对齐的是 UE
“低分辨率体积场 + 时间复用 + 世界空间低频光照”的工程方向，并利用了 Moer 独有的动态稀疏
Probe 基础设施。

仍可作为后续研究扩展、但不属于本次闭环缺陷的内容包括：透明几何的 Ray Query 透射、辐射方差
驱动的层级选择、真正的多阶路径积分，以及大型开放场景下的 Clipmap 压力测试。当前多次散射是
稳定且受控的历史邻域近似，不应在报告中表述为完整路径追踪解。
