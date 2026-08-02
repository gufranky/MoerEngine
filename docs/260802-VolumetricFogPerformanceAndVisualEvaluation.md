# MoerEngine 体积雾性能对比与效果测试报告

> 测试日期：2026-08-02  
> 测试场景：`asset/scenes/sponza/Sponza.gltf`  
> 代码基线：`1227f319a7f2d86d844e3caa47781e140d60ec58` + 当前未提交 FAST 适配与性能日志补丁  
> 本报告性质：最终报告可直接引用的第一轮实机 A/B；绝对性能仍建议在 Release 构建补测一次

## 1. 结论摘要

1. **Sponza 是当前仓库最适合展示体积雾的场景。** `Camera.001` 位于约 `(-7, 1.5, 0)`，沿长廊观察连续拱门、帘布、立柱和顶部开口。同一画面同时包含强方向光、遮挡暗区、近中远层次和细长几何边界，比只有单个人偶且使用 Unlit 材质的 Mizuki 更有代表性。
2. 1920×1080、`160×90×64` Froxel、默认 PCF1 + Temporal + Probe GI 时，体积雾 GPU Scope 总耗时约 **0.56 ms**；热态整帧 GPU 时间由约 **14.04 ms** 增至 **14.64 ms**。
3. 最大开销来自 Injection。完整 Halton 配置中 Injection 为 **0.283 ms，占 FogTotal 50.4%**；其次是全分辨率 Composite 的 **0.143 ms，占 25.5%**，Temporal 为 **0.081 ms，占 14.4%**。
4. 阴影质量是最重要的性能旋钮。关闭阴影、PCF0、PCF1、PCF2 的 FogTotal 分别约为 **0.259 / 0.321 / 0.456 / 0.647 ms**。PCF2 相比 PCF1 增加约 0.19 ms，但静止画面的提升小于从“无阴影”切到“有阴影”的提升。
5. **体积 CSM 阴影是当前观感成立的核心。** 关闭它后，顶部强光几乎均匀灌入整条走廊，拱门、帘布和柱体的遮挡层次明显丢失，画面变成大面积白雾。默认 PCF1 已能显著恢复空间结构。
6. Probe GI 注入的实测增量约 **0.03–0.05 ms**。默认 Sponza 中它的视觉变化较克制，因为画面由强方向光主导、全局 Probe GI 强度也仅为 0.16；它更适合用室内阴影区 ROI 展示，而不是用整屏明亮长廊证明。
7. FAST XY / FAST XYZ Offset 与 Halton 的静止收敛画面接近，FogTotal 分别为 **0.571 / 0.574 / 0.561 ms**，即 FAST 当前增加约 0.01 ms。是否值得采用应由固定相机轨迹下的时间方差和边缘闪烁结果决定，不能只凭静态截图下结论。
8. 当前没有真正的 Low / Medium / High 质量档。Froxel 固定为 12×12 像素一格、Z=64；因此现在最有效的质量档变量是 PCF 半径、Temporal、Probe GI 和采样序列，而不是网格分辨率。

## 2. 场景选择

仓库内可直接加载的场景只有 Sponza 与 Mizuki。

| 场景 | 内容 | 对体积雾的价值 | 结论 |
|---|---|---|---|
| Sponza | 约 30 m 长、12 m 高；连续拱门、柱体、帘布；方向光与多盏彩色点光；两个相机 | 能同时检查体积光柱、遮挡泄漏、空气透视、近远层次和边缘稳定性 | 采用 |
| Mizuki | 单个人偶、单材质、Unlit，无自带灯光和相机 | 缺少纵深、遮挡阵列和室内外过渡 | 不采用 |

本轮不修改 glTF 源文件，直接使用 Sponza 的首个相机 `Camera.001`。这样可以保证所有配置共享同一场景、机位、曝光和后处理链，避免场景编辑带来的额外变量。若最终答辩需要更强的光柱镜头，建议在 State Cache 中只调整 Sun 方向，让光线斜穿拱门，并把该缓存作为单独的“展示场景”，不要覆盖标准性能场景。

## 3. 测试环境

| 项目 | 值 |
|---|---|
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU，8188 MiB |
| 驱动 | 592.00 |
| CPU | Intel Core i7-13700H，14C/20T |
| 内存 | 32 GiB |
| 电源计划 | Turbo |
| 测后 GPU 温度 | 52°C |
| RHI | Vulkan，API 1.4.325；引擎目标 Vulkan 1.3 |
| 构建 | Debug，MSVC 19.44，Ninja |
| 输出分辨率 | 1920×1080 |
| VSync / FPS Limit | Off / Off |
| 后处理 | 保持 Sponza 默认：RTAO、SMAA 1x、Bloom 等均不变 |
| Froxel | 160×90×64，共 921,600 个 |
| 体积雾显存 | 自有资源 31.89 MiB + FAST 噪声 0.50 MiB = 32.39 MiB |

UI 平滑值在标准场景约为 44–46 FPS、22 ms 左右；它包含编辑器、CPU 和呈现开销，仅作辅助观察。下面的性能结论以 Vulkan GPU Timestamp 为准。

## 4. 测量方法

为避免 RenderDoc 捕获导致卡顿，本轮直接启用引擎已有的 GPU Timestamp Scope，并在 `RasterTool` 中每秒记录：

- `GraphicsExec`；
- `Volumetric Fog Light And Probe GI Injection`；
- `Volumetric Fog Day6 Temporal Reprojection Clamp`；
- `Volumetric Fog Day4 Beer-Lambert Integration`；
- `Volumetric Fog Debug Visualize`；
- `Volumetric Fog Day6 Trilinear HDR Composite`；
- 上述五项之和 `FogTotal`；
- 当前 Fog/Temporal/Jitter/Shadow/PCF/Probe GI/Local 配置标签。

每次切换配置后等待历史和 13 帧 GPU profiler 滑动窗口稳定；统计时丢弃每个连续配置段的前 3 条记录，再取末尾最多 30 条。表中的 Mean/P50/P95 都来自同一固定机位。

原始日志：`saved/volumetric_fog_benchmark/MoerEditor-benchmark.stdout.log`  
结构化数据：`saved/volumetric_fog_benchmark/summary.csv`

完整运行期间 FAST 纹理成功加载，Probe GI 达到 12/12 Resident Brick、584/584 Resident Probe；未发现 Shader 编译、Vulkan 资源、NaN 或 Device Lost 错误。stderr 仅有一条无关的 PNG iCCP profile 警告。

## 5. 性能结果

### 5.1 配置对比

| ID | 配置 | N | Graphics Mean / P95 (ms) | FogTotal Mean / P95 (ms) | 相对热态 P0 的整帧增量 |
|---|---|---:|---:|---:|---:|
| P0 | Fog Off，热态基线 | 30 | 14.043 / 14.179 | 0.000 / 0.000 | 0.000 |
| P1 | Fog On；无阴影；Temporal Off；GI Off | 30 | 14.328 / 14.506 | 0.259 / 0.260 | +0.285 |
| P2 | P1 + CSM PCF0 | 25 | 14.353 / 14.485 | 0.321 / 0.321 | +0.310 |
| P3 | P1 + CSM PCF1 | 30 | 14.506 / 14.698 | 0.456 / 0.456 | +0.463 |
| P4 | P1 + CSM PCF2 | 30 | 14.687 / 14.866 | 0.647 / 0.648 | +0.644 |
| P5 | PCF1 + Probe GI；Temporal Off | 27 | 14.626 / 14.768 | 0.482 / 0.483 | +0.583 |
| P6 | 完整功能，Halton | 30 | 14.639 / 14.734 | 0.561 / 0.561 | +0.596 |
| P7 | 完整功能，FAST XY | 30 | 14.721 / 14.800 | 0.571 / 0.572 | +0.678 |
| P8 | 完整功能，FAST XYZ Offset | 24 | 14.712 / 14.806 | 0.574 / 0.575 | +0.669 |
| P9 | P8 + 默认局部雾体 | 30 | 14.682 / 14.763 | 0.574 / 0.575 | +0.639 |

`GraphicsExec(Pn)-GraphicsExec(P0)` 会受 GPU 频率和其它 Pass 波动影响，因此 FogTotal 是分析算法内部开销的主口径，整帧增量用于交叉验证。两者数量级一致。

### 5.2 完整 Halton 配置的阶段分解

| 阶段 | GPU 时间 | FogTotal 占比 |
|---|---:|---:|
| Light / CSM / Probe GI Injection | 0.283 ms | 50.4% |
| Temporal Reprojection | 0.081 ms | 14.4% |
| Beer-Lambert Integration | 0.034 ms | 6.1% |
| Debug Visualize | 0.021 ms | 3.7% |
| Depth-Aware Composite | 0.143 ms | 25.5% |
| 合计 | 0.561 ms | 100% |

### 5.3 成本解释

- 基础 Fog 即使不做阴影/GI/Temporal，也有约 0.20 ms 的 Integration + Debug + Composite 固定成本；加上基础 Injection 后为 0.259 ms。
- PCF0/1/2 的 Injection 分别为 0.125/0.258/0.450 ms，符合每 Froxel 1/9/25 次阴影采样的增长趋势。
- Temporal 的独立增量约 0.08 ms，与单独 Scope 一致。
- Probe GI 采用每 4×4×4 工作组查询一次、64 个 Froxel 共享的方案，额外成本约 0.03–0.05 ms；若逐 Froxel 查询，成本不会处在这个量级。
- 默认 Local Fog Volume 仅增加约 0.001–0.003 ms，说明解析球形密度计算不是当前瓶颈。
- FAST 纹理采样使完整配置比 Halton 增加约 0.01 ms。它的价值必须来自更好的时间稳定性，而不是性能更低。

## 6. 观感测试

| 对照 | 观察结果 | 判断 |
|---|---|---|
| Fog Off | 纹理和轮廓最清晰，但长廊前后景分离主要依赖明暗，缺少空气透视 | 只作为基线 |
| 默认完整雾（Base Density 0.006） | 近景帘布和石柱仍清晰，中远处有柔和深度衰减，顶部光线获得连续介质感 | 当前最平衡的展示基线 |
| 关闭体积 CSM 阴影 | 整条长廊迅速变成均匀灰白雾幕；拱门、帘布和柱体的遮挡关系显著消失 | 不可用于最终效果；也证明阴影 Pass 不是占位 |
| PCF0 → PCF1 | PCF1 的遮挡边界更柔和，静止画面中光束连续性更好 | 默认采用 PCF1 |
| PCF1 → PCF2 | 只有局部高对比边界略柔和，整体提升不如成本增长明显 | 作为 High/截图档，不建议默认 |
| Temporal Off | 静止收敛图与开启时接近，但失去历史滤波与四帧 Probe GI 方向重建 | 仅用于单帧/排错对照 |
| Halton / FAST XY / FAST XYZ | 静止收敛后总体亮度、层次和边缘接近；未观察到新的固定图案或明显层带 | 静态合格，但不足以证明 FAST 优于 Halton |
| Probe GI Off / On | 整屏变化克制，暗拱和远端阴影区略有环境填充；强直射区域几乎不变 | 需要阴影区 ROI 或动态灯光场景突出优势 |
| 默认 Local Fog Volume | 标准机位下存在感较弱；提高局部密度后仍不适合作为主展示点 | 最终展示应调整中心、半径和灯光，而不是只提高全局密度 |
| 较高全局密度 | 光源附近散射更强，但亮部更容易饱和，不能替代正确的阴影和相位函数 | 保持 0.006，局部浓雾用 Local Volume |

## 7. 运动稳定性说明

测试时首次发送 WASD 被中文输入法拦截，画面出现候选栏；随后已切换到英文输入。Moer 相机只有在鼠标拖拽期间才消费 WASD，当前桌面自动化只能发送离散按键和快速拖拽，无法形成严格恒速、逐帧一致的轨迹。因此本轮完成了静止收敛、参数切换、历史重置和边缘主观观察，但**没有伪造相邻帧方差、停止后恢复帧数或 10 秒固定轨迹数据**。

这不影响上述 GPU 性能结论；但 FAST 是否改善运动闪烁仍应在最终论文图表前补一轮可重复相机轨迹。建议在引擎内加入只用于测试的相机轨迹（沿长廊前进 2 m + 左右偏航 5°，10 秒），同时导出每帧输出或 ROI 统计：

- 全图与光柱边缘 ROI 的相邻帧绝对差 Mean/P95；
- 64 帧时间方差；
- 相机停止后恢复稳定所需帧数；
- Halton、White Noise、FAST XY、FAST XYZ Offset 四组同预算对比。

## 8. 推荐最终配置与质量档

当前代码没有显式档位，可以在报告中先按下表定义实验档，之后再落到 UI：

| 档位 | CSM | Temporal / Jitter | Probe GI | 预期 FogTotal | 用途 |
|---|---|---|---|---:|---|
| Low | PCF0 | On / Halton | Off | 约 0.40 ms（依据实测项组合估算） | 性能优先 |
| Medium | PCF1 | On / Halton | On | 0.56 ms | 当前推荐默认 |
| High | PCF2 | On / 通过运动测试后的最佳 FAST 模式 | On | 约 0.75 ms（依据 PCF2 + Temporal/GI 估算） | 截图与高质量平台 |

估算项必须在档位真正实现后复测，不能当作实测值引用。

## 9. 可立即进行的优化

1. **按需执行 Debug Visualize。** 当前即使没有显示 `volumetric_fog_debug`，仍每帧 Dispatch，固定浪费约 0.021 ms。生产路径应只在选择调试输出时执行。
2. **把 PCF1 作为默认、PCF2 作为 High。** PCF2 比 PCF1 多约 0.19 ms，标准机位的静止收益有限。
3. **优化 Composite。** 0.143 ms 占完整成本约四分之一，可评估更紧凑的深度引导上采样、与后处理合并或减少全分辨率读写。
4. **继续保持 Probe GI 工作组摊销。** 0.03–0.05 ms 的动态间接雾光增量是合理的研究型开销；下一步应提升可见性与实验设计，而不是先牺牲这一差异化能力。
5. **为 Froxel 网格增加真正的质量档。** 当前固定 12×12×64，无法完成分辨率/深度切片的伸缩曲线。建议至少支持 16×16×48、12×12×64、8×8×96 三档，再测 720p/1080p/1440p。
6. **补 Release 数据。** 本轮 Debug 适合做同构 A/B；提交论文或答辩前应在 Release、固定功耗/温度下重复三次，报告三次中位数和跨轮 P95。

## 10. 报告可用表述

> 在 1920×1080 的 Sponza 场景中，MoerEngine 体积雾使用 160×90×64 的视锥 Froxel 网格。RTX 4060 Laptop GPU 上，默认 PCF1、时域重投影和动态 Probe GI 全部启用时，体积雾 GPU 开销为 0.56 ms，其中光照/阴影/GI 注入占 50.4%。基于工作组共享的 Probe GI 注入只增加约 0.03–0.05 ms。体积阴影对画质影响最大：关闭阴影会导致明显的均匀白雾和遮挡层次丢失；PCF1 在画质与性能之间表现最好。FAST 采样当前比 Halton 增加约 0.01 ms，静止画面质量相近，其最终取舍应由固定相机轨迹下的时间方差实验决定。
