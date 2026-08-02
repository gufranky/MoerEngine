# 近期体积雾研究与 MoerEngine 功能适配方案

> 调研日期：2026-08-01  
> 本地代码基线：`1227f31 feat(raster): inject dynamic Probe GI into volumetric fog`  
> 调研范围：2023—2026 年近期工作，必要时回溯 2021—2022 年直接相关的基础方法  
> 当前阶段：只确定方案和实验方法，不修改体积雾功能代码

## 1. 结论摘要

本轮建议适配的功能是：

> **面向 Moer 体积雾时序滤波器的 FAST Froxel Jitter（Filter-Adapted Spatio-Temporal Froxel Sampling）**

它基于 EA SEED / Frostbite 研究人员在 I3D 2024 发表的 FAST。FAST 不只是把白噪声换成蓝噪声，而是根据渲染器实际使用的空间和时间滤波器，离线优化采样序列，使最终滤波结果的均方误差更低。论文直接包含体积 Ray Marching 实验，并公开了 BSD-3-Clause 许可的 DX12 生成器和预生成纹理。

该方法与 Moer 当前架构高度吻合：

- Moer 已经使用每帧一个 Halton 2/3/5 三维子 Froxel 样本；
- Moer 已经具有稳定网格语义的三维历史重投影，默认历史权重为 `0.94`；
- 当前已知画质问题正是低采样密度下的层带、细节走样和时间闪烁之间的取舍；
- Moer RHI 已支持 `Texture3D`、纹理上传和 Compute Shader，接入只需要一张小型采样纹理，不需要新 Pass、Ray Query 或神经网络运行时；
- 可以保留已经验证过的稳定 CSM、光照和 Probe GI 查询位置，只对连续介质密度取样使用 FAST，风险可控。

建议暂不把以下方法作为第一次适配：

1. **Volumetric ReSTIR**：研究价值很高，也能利用 Moer 的 ReSTIR 经验，但论文针对逐像素随机体积路径追踪，而当前 Moer 是确定性的 Froxel 单次散射管线。直接移植不是小功能，而是重写光照估计器。
2. **神经体积多次散射/神经去噪**：能补足单次散射的物理差距，但需要训练数据、推理运行时和稳定的特征缓冲，现阶段会把重点从“体积雾算法优化”转为“网络工程”。
3. **Path Graph、体积路径引导等离线方法**：解决的是高阶多次散射的收敛问题，计算与存储预算远超当前实时 Froxel 管线。
4. **2026 年的逆渲染、Gaussian Splatting、科学体绘制工作**：虽然标题中也有“volumetric”，但研究对象是体数据重建、可视化或逆问题，不等价于游戏引擎的参与介质体积雾。

因此，本次适配的价值不是增加一个新的效果开关，而是做一项可以量化的渲染采样研究：在相同 Froxel 数量、相同每帧样本数和近似相同 GPU 成本下，比较 Halton、白噪声、STBN 与 FAST 的空间误差、时间稳定性和历史收敛速度。

## 2. MoerEngine 当前体积雾基线

### 2.1 已有完整链路

当前实现已经包含：

```text
指数高度雾 / 解析局部雾体积
  -> Froxel 密度、消光、方向光、CSM、Probe GI 注入
  -> 三维历史重投影、邻域 Clamp、运动响应
  -> Beer–Lambert 沿视线积分
  -> 深度感知的 HDR 合成
```

1080p 下 Medium 档使用 `160×90×64` 的视锥 Froxel 网格，即 XY 每 `12×12` 像素一个 Froxel、Z 方向 64 个指数分布切片。关键代码位置：

- [`VolumetricFogPass.cpp`](../Source/runtime/render/renderer/raster/VolumetricFogPass.cpp)：资源、Halton Jitter、注入和历史调度；
- [`InjectDensity.hlsl`](../Shaders/pipelines/raster/volumetric_fog/InjectDensity.hlsl)：介质、光照、CSM 和 Probe GI 注入；
- [`TemporalReprojection.hlsl`](../Shaders/pipelines/raster/volumetric_fog/TemporalReprojection.hlsl)：稳定 Froxel 网格重投影、7 Tap Clamp 和历史融合；
- [`RasterConfig.h`](../Source/runtime/render/renderer/raster/RasterConfig.h)：默认历史权重 `0.94`、运动响应 `0.15` 和 Clamp Expansion `0.10`；
- [`RHICommandList.cpp`](../Source/runtime/render/rhi/RHICommandList.cpp)：CPU 数据直接上传 3D 纹理的现有接口。

### 2.2 现有 Halton 的作用和局限

当前 CPU 每帧生成同一个全局三维 Jitter：

```text
x = Halton(frame, 2) - 0.5
y = Halton(frame, 3) - 0.5
z = Halton(frame, 5) - 0.5
```

优点是实现简单、单点时间序列低差异、没有采样纹理开销。局限是：

- 同一帧所有 Froxel 使用相同偏移，空间上高度相关；
- 它没有针对 Moer 的历史 EMA、邻域 Clamp 和历史失效策略优化；
- 在局部雾体积边界、程序化密度、高频噪声等不连续或高梯度区域，会形成相干的轮廓移动；
- 增大历史权重能压住噪声，但会增加响应滞后与拖影风险；减小历史权重又会重新暴露时间闪烁。

这正是 FAST 针对的问题：不是盲目追求单帧采样均匀，而是让采样误差与后续滤波器互补。

### 2.3 必须保留的稳定性约束

此前调试已经确认：

1. 历史纹理代表稳定、未抖动 Froxel 单元上的时间平均，不能随相邻两帧 Jitter 差值整体平移；
2. CSM 是不连续的二值/PCF 可见性查询，若使用逐帧变化的世界位置，会在阴影边缘形成明显闪烁；
3. Probe GI 和方向光也属于低频光照项，不需要跟随介质密度 Jitter。

因此 FAST 只能替换当前 `world_position` 的介质密度、局部体积和未来程序化噪声采样；以下位置继续使用稳定 Froxel 中心：

- CSM 级联选择与阴影深度比较；
- Henyey–Greenstein 相函数的视线方向；
- Probe GI 工作组中心查询；
- 历史重投影和历史纹理坐标。

如果不遵守这一点，新的采样方法会重新引入已经修复的光柱边缘随机游走。

## 3. 近期研究脉络

### 3.1 方向 A：时空采样与误差整形

#### Spatiotemporal Blue Noise Masks，2022

STBN 同时维持每一帧的空间蓝噪声性质和单像素随时间变化的良好分布。作者在体积渲染、环境光遮蔽和随机卷积中展示了更好的感知噪声、时间收敛与稳定性，并公开了可用 Mask 和 SDK。

对 Moer 的意义：它是比“全屏统一 Halton”更合理的基线，说明不同 Froxel 应获得空间去相关的样本。但 STBN 主要优化蓝噪声频谱，并不知道 Moer 实际使用的是 `0.94` 历史权重、7 Tap 非线性 Clamp 和动态历史拒绝。

来源：[NVIDIA Research：Spatiotemporal Blue Noise Masks](https://research.nvidia.com/publication/2022-07_spatiotemporal-blue-noise-masks)

#### Perceptual Error Optimization for Monte Carlo Animation Rendering，2023

该工作把感知误差优化从静态图像扩展到时空域，强调动画显示中的误差分布不能只看单帧。它为“根据时间观察和滤波过程设计样本”提供了更一般的理论依据，但不是面向现有游戏 Froxel 管线的即插即用实现。

来源：[SIGGRAPH Asia 2023 论文 PDF](https://sampling.mpi-inf.mpg.de/publications/2023-korac-perceptual/2023-korac-perceptual.pdf)

#### FAST，2024

FAST 的核心是针对指定的空间/时间滤波核最小化滤波后的期望均方误差。其模型覆盖：

- 任意维度的标量或向量样本；
- 均匀或非均匀目标分布；
- 空间有限脉冲滤波和时间指数移动平均；
- 用随机 Heaviside 函数近似渲染中常见的可见性和介质边界不连续。

论文用环境光遮蔽、体积 Ray Marching 和抖色三个任务验证。它明确指出，真实时序管线存在历史拒绝和边缘感知行为，因此离线优化时应使用比实际去噪器略小的有效滤波核，而不是把理想 EMA 生硬套到所有像素上。

公开生成器支持 `Vector3` 和 `128×128×N` 时空纹理，可配置空间滤波器与 EMA 参数。一张 `128×128×64×RGBA8` 纹理只占 4 MiB，适合实时引擎。

来源：

- [FAST 论文（I3D 2024）](https://media.contentapi.ea.com/content/dam/ea/seed/presentations/seed-id3-2024-spatio-temporal-sampling-paper.pdf)
- [EA FAST 开源生成器（BSD-3-Clause）](https://github.com/electronicarts/fastnoise)
- [ACM DOI](https://doi.org/10.1145/3651283)

#### Importance-Sampled FAST，2025

2025 年的扩展允许从一般的目标分布中得到具有 FAST 时空性质的样本。公开示例使用 `128×128×32` 的二维向量纹理，并通过周期索引和低差异全局偏移把有限纹理扩展为更长序列。

它对未来的面积光、相函数方向重要性采样或非均匀自由程采样很有价值。但 Moer 当前只是对 Froxel 单元内部位置做均匀抖动，因此第一版不需要 IS-FAST；直接使用均匀 `Vector3` FAST 更简单，也更容易进行无偏 A/B。

来源：

- [JCGT 2025：Importance-Sampled Filter-Adapted Spatio-Temporal Sampling](https://jcgt.org/published/0014/01/08/)
- [EA 公开实现与预生成纹理](https://github.com/electronicarts/importance-sampled-FAST-noise)

### 3.2 方向 B：Reservoir 复用与体积路径追踪

#### Fast Volume Rendering with Spatiotemporal Reservoir Resampling，2021

该工作把 ReSTIR 扩展到多维体积路径空间。它在每像素只完整求值一个路径样本的条件下，用时间和空间 Reservoir 重采样复用候选路径；候选阶段允许使用便宜、有偏的透射率近似，但最终样本使用无偏求值，因此能在复杂动态光照和高分辨率体数据中得到低噪声结果。

它和 Moer 的硬件 Ray Query、ReSTIR DI 代码资产非常契合，研究含金量也是所有候选中最高的。但存在关键架构差异：

- 论文的估计对象是每像素体积路径，Moer 当前估计对象是每 Froxel 的局部单次散射；
- 需要介质自由程/散射点采样、路径 Reservoir、候选与最终透射率求值、可见性、时空重投影和权重修正；
- 当前表面 ReSTIR DI 的 Reservoir 不能直接拿来存体积路径；
- 只做“每 Froxel Reservoir 选局部灯”虽然可行，但已不是原论文的直接复现，需要重新分析偏差和空间相关性。

结论：适合作为后续高级课题，不适合作为本轮单功能适配。

来源：[NVIDIA Research：Fast Volume Rendering with Spatiotemporal Reservoir Resampling](https://research.nvidia.com/publication/2021-11_fast-volume-rendering-spatiotemporal-reservoir-resampling)

#### 2025 年 Reservoir Splatting 趋势

Reservoir Splatting 继续改善运动、亚像素几何和高频内容下的时间路径复用，说明 ReSTIR 研究正在从简单反投影走向更健壮的样本覆盖建模。不过该工作不是体积雾方法，不能直接视为 Volumetric ReSTIR 的更新版。

来源：[NVIDIA Research：Reservoir Splatting for Temporal Path Resampling and Motion Blur](https://research.nvidia.com/labs/rtr/publication/liu2025splatting/)

### 3.3 方向 C：神经多次散射与联合去噪

#### Joint Neural Denoising of Surfaces and Volumes，2023

该方法对低采样数体积路径追踪进行表面/体积信号分层，使用时空神经去噪器、学习得到的合成权重和透射率，在 4 spp 下实现交互式、时间稳定的表面与体积联合结果。

对 Moer 的启发是：如果将来引入硬件光追体积路径，体积与表面应分层去噪，透射率也应作为独立信号处理。但当前 Moer 既没有 4 spp 的体积路径输入，也没有网络要求的引导特征，不能只接一个模型得到相同能力。

来源：[NVIDIA Research：Joint Neural Denoising of Surfaces and Volumes](https://research.nvidia.com/publication/2023-03_joint-neural-denoising-surfaces-and-volumes)

#### 高反照率各向异性介质的神经多次散射，2024

该工作用 3D-CNN、透射率特征、相位特征和注意力网络近似求解辐射传输方程的迭代积分，目标是高反照率、各向异性介质中的多次散射。它针对的是当前 Moer 单次散射 + Probe GI 近似无法准确覆盖的物理现象。

主要问题是论文与工程资产成熟度不足：没有与 Moer 数据布局一致的公开训练集和产品级推理实现；部署还要解决动态密度、动态灯光、尺度泛化、网络误差和跨 GPU 性能。即使 Moer 仓库存在 CUDA/TensorRT 实验路径，也不能据此把它判断为低成本适配。

来源：[arXiv 2401.14051](https://arxiv.org/abs/2401.14051)

### 3.4 方向 D：离线多次散射与新光输运理论

2024 年的 Path Graph 体积渲染通过复用多次散射路径信息，加快高反照率、致密、前向散射介质下的离线路径追踪收敛；同年的随机几何统一理论则试图在同一模型中描述微表面、参与介质与两者之间的连续形态。这些工作具有很高理论价值，但论文自身仍把实时采样算法留作后续问题，不能直接转化为当前每帧约毫秒级的 Froxel Pass。

来源：

- [Rendering Participating Media Using Path Graphs](https://arxiv.org/abs/2404.11894)
- [NVIDIA Research：From Microfacets to Participating Media](https://research.nvidia.com/publication/2024-07_microfacets-participating-media-unified-theory-light-transport-stochastic)

### 3.5 2025—2026 年“最新”结果的适用性判断

截至 2026-08-01，检索到的新工作主要集中于：

- 科学体数据的路径追踪、神经去噪和可视化；
- 逆渲染、体数据重建与 3D Gaussian/Radiance Field；
- 稀疏 VDB/体积视频的压缩和播放；
- 离线或交互式而非游戏帧预算的多次散射求解。

例如 2025 年的实时神经体绘制去噪针对医学/科学 VPT，2026 年 7 月的 Volumetric Inverse Rendering 研究从图像反推介质光学属性。它们都不是当前 Moer 游戏体积雾的直接升级路径。

来源：

- [Eurographics 2025：Real-Time Neural Denoising for Volume Rendering](https://diglib.eg.org/items/ca1a11be-81e7-4b2d-b25a-1df86f20143b)
- [arXiv 2607.13695：Volumetric Inverse Rendering via Neural Radiative Transfer](https://arxiv.org/abs/2607.13695)

因此“最新”不能只按发表日期排序。对当前任务更合理的标准是：论文是否处理参与介质、是否面向低样本实时渲染、是否支持动态场景、是否有可复用实现，以及是否能嵌入现有 Froxel + Temporal 架构。按这个标准，2024 FAST 加 2025 IS-FAST 扩展是本轮最合适的近期成果。

## 4. 与 Unreal Engine 当前方法的关系

UE 5.8 官方文档仍说明其 Volumetric Fog 使用每帧不同的子体素 Jitter 和较重的时序重投影滤波器来平滑走样；画质与成本主要受体积纹理分辨率、Z Slice 数量、局部体积重叠和带阴影灯光数量影响。

Moer 与 UE 的共同基础是：

- 视锥对齐的低分辨率体积网格；
- 指数/非线性 Z 分布；
- 子体素 Jitter；
- 历史重投影；
- 全局高度雾、局部密度、方向光与阴影注入；
- 沿视线积分后与表面颜色合成。

UE 的产品能力仍明显领先：任意数量的点光/聚光、体积阴影、Volume Material/粒子、本地雾体积管理、半透明体积雾、Volumetric Lightmap、质量分级和多平台验证都更成熟。UE 还提供实验性的 Heterogeneous Volumes 与 Sparse Volume Textures，面向 VDB 烟火等内容。

FAST 适配不是“复刻 UE 已有面板功能”，而是在相同的基础 Froxel/Temporal 方法上研究更优采样。公开 UE 文档只说明不同子体素 Jitter，并未说明使用按实际滤波器优化的 FAST。因此报告中应表述为：

> 在对齐 UE 的 Froxel + 重时域重投影路线基础上，利用 Moer 算法透明、易替换采样器的特点，引入近期 FAST 研究，对相同每帧采样预算下的误差和稳定性进行优化与量化。

UE 参考：

- [UE 5.8 Volumetric Fog](https://dev.epicgames.com/documentation/unreal-engine/volumetric-fog-in-unreal-engine)
- [UE 5.8 Local Fog Volumes](https://dev.epicgames.com/documentation/en-us/unreal-engine/local-fog-volumes-in-unreal-engine)
- [UE 5.8 Heterogeneous Volumes](https://dev.epicgames.com/documentation/en-us/unreal-engine/heterogeneous-volumes-in-unreal-engine)
- [UE Volumetric Lightmaps](https://dev.epicgames.com/documentation/unreal-engine/volumetric-lightmaps-in-unreal-engine)

## 5. 候选方案评分

评分 1—5，5 代表最高。难度和风险分数越高越难。

| 候选 | 近期性 | 与 Moer 契合度 | 预期画质收益 | 研究含金量 | 难度 | 风险 | 建议 |
|---|---:|---:|---:|---:|---:|---:|---|
| FAST Froxel Jitter | 5 | 5 | 4 | 4 | 2 | 2 | **本轮实施** |
| STBN Froxel Jitter | 3 | 5 | 3 | 3 | 2 | 2 | 作为 A/B 基线 |
| 每 Froxel/Tile 的局部灯 ReSTIR | 3 | 4 | 4 | 5 | 5 | 5 | 后续研究 |
| 完整体积 ReSTIR 路径追踪 | 2 | 3 | 5 | 5 | 5 | 5 | 独立长期课题 |
| 神经多次散射 | 4 | 2 | 5 | 5 | 5 | 5 | 当前不实施 |
| 表面/体积联合神经去噪 | 3 | 2 | 4 | 5 | 5 | 5 | 等体积 RT 路径成熟后 |
| Sparse VDB/Heterogeneous Volume | 4 | 3 | 5 | 4 | 5 | 4 | 偏内容系统，不是当前画质小步优化 |

## 6. 确定方案：FAST Froxel Jitter

### 6.1 研究问题

本次功能回答一个明确问题：

> 在每个 Froxel 每帧仍只计算一个介质样本、不提高网格分辨率的条件下，针对 Moer 的时间滤波器优化三维子体素样本，能否比全局 Halton 更快收敛、更少闪烁，并保留相机运动时的响应速度？

### 6.2 数据形式

第一版采用离线生成的均匀 `Vector3` FAST 纹理：

```text
空间尺寸：128 × 128
时间帧数：64
通道：RGB = 单元内 XYZ 样本，A 保留
格式：RGBA8_UNORM
显存：128 × 128 × 64 × 4 = 4 MiB
寻址：Point Load + 整数环绕，不使用线性过滤
```

三个通道读取 `[0, 1]` 后减去 `0.5`，得到当前 `[-0.5, 0.5]` 的 Jitter 约定。纹理由 FAST 官方生成器离线生成，不在 Moer 启动时运行优化器。

选择 `Vector3` 而不是三张独立标量纹理，是为了让 XYZ 联合样本空间也参与优化；选择 RGBA8 而不是浮点格式，是因为 Jitter 的量化误差远小于 Froxel 尺寸，且 4 MiB 成本可控。

### 6.3 空间和时间索引

FAST 纹理的前两个轴代表屏幕/Froxel 空间，第三轴代表帧。建议第一版索引：

```text
noiseXY = (froxelXY + layerPermutation(z) + cycleOffset(frame / 64)) mod 128
noiseZ  = frame mod 64
jitter  = FAST.Load(int4(noiseXY, noiseZ, 0)).rgb - 0.5
```

其中：

- `layerPermutation(z)` 使用固定、双射或近似双射的整数偏移，让相同 XY 的不同深度层访问不同空间位置；
- `cycleOffset` 只在 64 帧周期结束时改变全局纹理偏移，避免明显的 64 帧循环；
- 偏移必须是纯整数环绕，不能对样本值再做任意 Hash，否则会破坏离线优化得到的时空相关性；
- 首版先固定相机分辨率无关的 Froxel 索引，不用全分辨率像素坐标，保证同一 Froxel 的样本定义稳定。

这里存在一个需要通过实验决定的设计点：Z 层去相关会改变原 FAST 在 XY 邻域上的频谱。报告建议准备两种实现做消融：

1. **FAST-XY**：所有 Z 层共享同一 XY 索引，只改变样本值的三个通道；频谱最忠实，但深度层间相关；
2. **FAST-XYZ-Offset**：每个 Z 层使用确定性 XY 偏移；深度去相关更好，但可能略微损伤 XY 局部结构。

最终默认项由结果决定，不在实现前凭直觉指定。

### 6.4 与 Moer 时间滤波器匹配

当前历史写法为：

```text
output = lerp(current, history, historyWeight)
historyWeight 默认 0.94
```

因此当前帧新样本系数约为 `0.06`。FAST 生成器的 Exponential 参数含义必须按照其文档和源码校准，不能直接把 Moer 的 `0.94` 原样填入 `alpha`。计划生成至少三组候选：

- 针对约 `0.06` 当前帧贡献的长历史版本；
- 针对约 `0.10` 当前帧贡献的中等历史版本；
- 针对更短有效历史的版本，用来补偿邻域 Clamp、相机运动和历史失效。

论文指出真实历史拒绝会缩小有效滤波器，因此最匹配的纹理不一定是数学上等于 `0.94` EMA 的那一张。必须以运动场景和历史权重热力图实测选择。

空间滤波方面，当前时间 Pass 只用 7 Tap 邻域计算 Clamp 边界，并没有线性地平均当前样本；最终 Composite 会做深度感知插值。因此第一轮生成器配置应以“无/极小空间低通 + EMA”为主，同时保留一张针对小型 Gaussian/Box 空间核的候选纹理，检验最终合成插值是否足以产生论文所说的滤波匹配收益。

### 6.5 代码落点

计划修改范围控制在：

| 文件 | 计划修改 |
|---|---|
| `RasterConfig.h` | 增加 Jitter 模式：Off / Halton / White / STBN / FAST，以及调试 Cycle 选项 |
| `RasterUI.cpp` | 增加采样模式下拉框和纹理/帧索引状态 |
| `VolumetricFogPass.h/.cpp` | 创建并上传 3D FAST 纹理，传递帧索引；保留 Halton 回退 |
| `ShaderParameters.h` | 增加 Jitter 模式、帧索引和纹理尺寸等共享参数 |
| `InjectDensity.hlsl` | 按 Froxel XY/Z/Frame 读取 FAST，且只应用到介质密度位置 |
| `docs/260714-VolumetricFogImplementationPlan.md` | 实现与实验完成后补充记录，不在本轮调研阶段修改 |

实现不增加新的 Render Pass、全分辨率纹理或 Ray Query。FAST 纹理可以作为 Injection Pass 的一个普通 `Texture3D` 绑定，优先使用显式绑定，避免为了一个固定资产扩大 Bindless 生命周期管理范围。

### 6.6 许可证和资产策略

EA `fastnoise` 仓库标注 BSD-3-Clause。正式引入前仍需：

1. 在第三方声明中记录 FAST 生成器来源、论文和许可证；
2. 区分“使用官方预生成纹理”和“用官方生成器产生 Moer 专用纹理”；
3. 推荐提交 Moer 自己生成的最终纹理、生成命令和参数，不提交论文 PDF；
4. 若修改生成器源码，则保留原版权和许可证文本；若只使用生成结果，也保留来源说明以保证研究可复现。

## 7. 实验设计与量化验收

### 7.1 对照组

必须同时保留：

1. Jitter Off：稳定但有层带/空间走样的下界；
2. 当前全局 Halton 2/3/5：项目基线；
3. 独立白噪声/Hash：验证“任何空间去相关都行”是否成立；
4. STBN：近期常用蓝噪声基线；
5. FAST：推荐方案；
6. 4× 或 8× 时间累积参考，必要时使用更高 Froxel 分辨率生成近似参考图。

### 7.2 固定场景

至少准备四类镜头：

| 场景 | 主要观察问题 |
|---|---|
| Sponza 静止镜头 + 强 CSM 光柱 | 时间噪声、阴影边缘稳定性、周期纹理 |
| 缓慢平移和旋转 | 重投影收敛、拖影、历史失效后的恢复速度 |
| 解析局部雾球边界 | 密度不连续处的轮廓爬动和层带 |
| 程序化高频 3D Density（第二阶段） | 空间相关性、细节保留和摩尔纹 |

自动曝光必须锁定，灯光、相机轨迹、分辨率和所有雾参数必须固定。所有方法使用相同帧序列长度和预热帧数。

### 7.3 指标

#### 画质

- 相对高质量参考图的 RGB RMSE / PSNR；
- 静止镜头逐像素时间方差；
- 相邻帧绝对差的平均值、P95 和最大值；
- 局部雾边缘/光柱边缘 ROI 的时间方差；
- 1、2、4、8、16、32 帧后的收敛曲线；
- 历史重置后恢复到稳态误差 110% 以内所需帧数；
- 人工观察：低频块状噪声、固定图案、64 帧周期、拖影和响应迟滞。

#### 性能与资源

- `Volumetric Fog Light And Probe GI Injection` GPU Scope 的平均值、P95；
- Temporal、Integration、Composite 各自 GPU Scope；
- Shader 冷编译与磁盘缓存命中后的启动时间；
- 新增显存、Descriptor 数和 Dispatch 数；
- RTX 4060 Laptop 当前环境下至少记录 300 个预热后帧。

### 7.4 验收门槛

以下是项目目标，不是论文保证值：

- 在相同每帧样本数下，至少一个高频/边界测试镜头的 32 帧 RMSE 或 ROI 时间方差相对 Halton 降低 **20%**；
- 静止镜头相邻帧差 P95 不高于 Halton；
- 相机缓慢运动时不出现新的阴影轮廓闪烁、固定纹理游走或明显拖影；
- Injection Pass 的预热后 P95 回退不超过 **0.10 ms**；
- 新增显存不超过 **4 MiB**，不新增全分辨率中间纹理；
- 关闭 FAST 或资源加载失败时可靠回退到 Halton；
- 运行时切换采样模式时正确清空历史，不能混合两个分布的旧历史。

若只改善主观噪声形态、数值误差没有下降，应把结论写成“感知质量改善”而不是“收敛更快”。若静态画质改善但运动拖影明显，则不设为默认项。

## 8. 实施顺序

### 阶段 1：可回退的采样框架，约 0.5 天

- 把当前 Bool Jitter 开关扩展成枚举；
- 保留 Halton 原实现；
- 增加白噪声和 FAST 路径；
- 切换模式自动使历史失效；
- 在日志中输出模式、纹理尺寸、时间周期和当前帧索引。

### 阶段 2：FAST 资产与 Shader 接入，约 0.5—1 天

- 用官方工具生成三组 EMA 参数候选的 `Vector3 Uniform` 纹理；
- 转成 Moer 可直接上传的 RGBA8 3D 数据；
- 验证 Vulkan 3D Texture 上传、整数 Load、环绕索引和资源生命周期；
- 确认 CSM、Probe GI、相函数方向与历史网格仍使用稳定位置。

### 阶段 3：A/B 与自动指标，约 1 天

- 固定相机脚本或录制相机轨迹；
- 保存连续帧并计算 RMSE、时间方差和边缘 ROI；
- 比较 FAST-XY 与 FAST-XYZ-Offset；
- 选择最匹配的 EMA 候选，并检查 64 帧周期。

### 阶段 4：调优与结论，约 0.5—1 天

- 调整周期全局偏移、Z 层去相关和有效 EMA；
- 完成 300 帧 GPU Scope 统计；
- 更新实现计划和最终报告；
- 若未达到验收门槛，默认仍保持 Halton，保留实验模式与失败原因。

总计约 **2.5—3.5 个开发日**。这段时间包含实现、视觉调试和性能测量，不把“Shader 编译通过”视为完成。

## 9. 风险与应对

| 风险 | 表现 | 应对 |
|---|---|---|
| FAST 与实际非线性 Clamp 不匹配 | 静止改善、运动恶化 | 同时生成长/中/短三种 EMA 候选，以实测选择 |
| Z 层索引破坏空间频谱 | 深度方向出现条纹或相关层 | 比较共享 XY 与分层整数偏移两种消融 |
| 64 帧周期可见 | 静止镜头周期性呼吸 | 周期结束后使用低差异全局整数偏移，检查频谱和长序列 |
| 把 Jitter 错用于光照查询 | CSM/Probe 边缘重新闪烁 | Shader 明确拆分 `density_world_position` 和 `stable_world_position` |
| 历史权重掩盖差异 | 所有方法看起来都相似 | 同时测试 0、0.8、0.9、0.94 历史权重并画收敛曲线 |
| 资产加载失败 | 黑雾、越界或崩溃 | 校验大小/格式，失败回退 Halton，日志明确报告 |
| 只看截图得出错误结论 | 静态好看但运动闪烁 | 强制连续帧、固定轨迹、数值指标和人工观察一起验收 |

## 10. 后续研究路线

完成 FAST 后，可以按以下顺序继续：

1. **程序化 3D 密度/噪声局部雾体积**：FAST 的收益在高频异质密度中更容易显现，也能补足当前只有一个解析雾球的内容限制；
2. **Clustered Point/Spot Light 注入**：先完成确定性灯光列表和无阴影版本，再评估每 Tile/Froxel 的 Reservoir 选灯；
3. **基于 ReSTIR DI 资产的体积直接光 Reservoir 原型**：只研究多灯选择，不冒充完整 Volumetric ReSTIR；
4. **动态 Probe GI 的方向/空间采样联合优化**：研究 FAST 或 IS-FAST 是否能替代当前四面体方向轮换；这会同时涉及 Probe 查询偏差，需独立立项；
5. **硬件光追体积参考路径**：用低帧率参考实现评估当前单次散射 + Probe GI 近似与真实多次散射的差距；
6. **神经去噪/多次散射**：只有在参考路径、训练数据和特征缓冲都具备后再进入。

## 11. 最终建议

本轮先实施 FAST Froxel Jitter，原因不是它最复杂，而是它同时满足：

- 是 2024 年正式发表、2025 年继续扩展的近期实时渲染研究；
- 论文直接包含体积渲染验证；
- 有开源生成器、预生成纹理和明确许可证；
- 准确命中 Moer 当前的低样本 + 重时域滤波架构；
- 不破坏已有动态 Probe GI、CSM 和稳定历史成果；
- 成本小、可回退、可以建立严格 A/B；
- 结果可以用收敛曲线、时间方差和 GPU Scope 证明，而不是只靠主观截图。

建议的研究贡献表述为：

> 本文针对视锥 Froxel 体积雾中全局低差异 Jitter 空间相关、且未与实际历史滤波器匹配的问题，将 Filter-Adapted Spatio-Temporal Sampling 适配到 MoerEngine 的三维子 Froxel 介质采样。实现保持光照、CSM、Probe GI 与历史重投影使用稳定单元中心，只对连续介质密度位置进行时空优化采样，并通过 Halton、白噪声、STBN 和 FAST 的同预算对照，量化边界稳定性、时间收敛、运动响应与 GPU 开销。

这比“换成蓝噪声减少闪烁”更准确，也避免夸大为新的体积光输运算法。真正的创新点是把论文方法按 Moer 的具体滤波器、稳定网格语义、三维 Froxel 和动态 Probe GI 光照约束完成工程化适配，并用可复现实验说明何时有效、何时无效。
