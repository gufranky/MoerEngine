# 体积雾基准参数冻结记录（2026-08-02）

此文件冻结“提高体积雾横向分辨率”之前的可复现实验状态。后续轨迹和画质优化不得覆盖此记录。

## Snapshot A：Sponza Sunshaft

- 输出分辨率：1920×1080，Vulkan Raster，Debug 构建
- 场景：`asset/scenes/sponza/Sponza.gltf`
- 相机：位置 `(-7.0, 2.2, 0.0)`，Yaw `5°`，Pitch `6°`，FOV `45°`
- 后处理：自动曝光开启，曝光补偿 `-3.2 EV`，Reinhard 开启，SMAA 1X
- 预热/轨迹：120/90 帧；第 0、22、45、67、89 帧截图
- 旧轨迹：前进 1.5 m，横向正弦摆动 0.45 m，Yaw 正弦摆动 2°，Pitch 正弦摆动 1.25°
- 旧 froxel 网格：屏幕 tile 12×12 像素，即 1920×1080 下约 160×90×64

## 默认 Halton 参数

- Density `0.006`
- Height Falloff `0.12`，Height Offset `0`
- Extinction Scale `1.0`
- Albedo `(0.90, 0.92, 1.00)`
- Ambient Color `(0.48, 0.62, 0.95)`，Ambient Intensity `0.25`
- Scattering Intensity `0.75`
- Start / Near Fade / Max Distance：`0 / 3 / 60 m`
- Directional Intensity `0.50`，Phase G `0.20`
- CSM Shadow 开启，PCF Radius `1`，Bias `0.0005`
- Temporal 开启，Halton jitter
- History Weight `0.94`，Motion Scale `0.15`，Clamp Expansion `0.10`
- History Reset：距离 `2 m`，角度 `20°`
- Local Volume 关闭；雾中 Probe GI 关闭（表面 Probe GI 保持开启）

## Showcase 参数（只用于观感展示）

Showcase 继承上述参数，并覆盖：

- Density `0.010`
- Ambient Intensity `0.12`
- Scattering Intensity `0.90`
- Directional Intensity `0.75`，Phase G `0.45`
- FAST XYZ Offset jitter
- Local Volume 开启：Center `(0, 2, 0)`，Radius `6 m`，Density `0.008`，Edge Falloff `2.5`

该组不参与“默认配置性能”结论，只用于展示散射、消光和局部雾层。

## 冻结样本

- Fog Off：`saved/volumetric_fog_capture/sunshaft/off/frame_045.png`
- 默认 Halton：`saved/volumetric_fog_capture/sunshaft/halton/frame_045.png`
- Showcase：`saved/volumetric_fog_capture/sunshaft/showcase/frame_045.png`
- 日志：`saved/volumetric_fog_capture/logs/sunshaft_*_final.stdout.log`

## Snapshot A 已知问题

- Sponza 的 Sun 强度为 34150，另有白色点光强度 54351；左上入射光区域仍存在局部饱和。
- 12×12 像素/froxel 在高反差体积阴影斜边处产生可见台阶，是下一阶段首要画质问题。
- 基准自动关闭时会触发既有 Probe GI/mimalloc 析构异常；截图和 GPU profile 在异常前已经完整写出。

## Snapshot B：首轮边缘优化候选

Snapshot B 在 Snapshot A 基础上修改：

- 轨迹改为严格直线：沿初始镜头 Front 前进 `2.5 m`，无横移、无 Yaw 摆动。
- 抬头轨迹：Pitch 由 `6°` 平滑增加到 `18°`。
- 横向 froxel tile 从 `12×12` 改为 `8×8` 像素；1920×1080 下网格为 `240×135×64`。
- froxel 相关显存由约 `29.88 MiB` 增至约 `67.24 MiB`。
- 基准最终抗锯齿从 SMAA 1X 改为 FXAA Quality；引擎交互模式的全局默认 AA 未被修改。
- CSM PCF 保持半径 `1`。

烟测结果：

- Showcase FogTotal 约 `0.954 ms`：Inject `0.518`、Temporal `0.196`、Integrate `0.070`、Composite `0.148 ms`。
- 相对同镜头 SMAA 1X，FXAA Quality 的全图二阶高频能量均值下降约 `19.7%`，P99 下降约 `23.2%`。
- PCF Radius 2 仅让约 `0.05%` 像素产生大于 4/255 的变化，却把 Inject 提高到约 `0.872 ms`，已否决。
- SMAA T2X 静态边缘较好，但移动帧出现明显双影，已否决并完整撤回相关相机接口试改。

Snapshot B 烟测目录：`saved/volumetric_fog_capture_grid8_fxaa/sunshaft/showcase/`。
完整 Off/Halton/FAST/Showcase A/B 矩阵尚未运行。

## Snapshot C：6×6 High 候选与低分辨率重建

Snapshot C 保持 Snapshot B 的场景、Showcase 参数、固定轨迹和 FXAA Quality，只修改体积场质量链路：

- 横向 froxel tile 从 `8×8` 提高到 `6×6` 像素；1920×1080 下网格为 `320×180×64`。
- froxel 数量由 `2,073,600` 增至 `3,686,400`（`1.78×`）。
- froxel 相关显存由 `67.24 MiB` 增至 `119.53 MiB`；包含半分辨率调试纹理的 pass 自有显存为 `121.62 MiB`。
- 保留已有的 FAST XYZ 子像素抖动、时间重投影、邻域钳制和运动响应。
- Composite 新增可关闭的全分辨率 5-tap tent 重建，默认强度 `0.55`。每个 tap 继续使用几何深度权重，避免跨前景/背景轮廓串雾。
- 编辑器 Volumetric Fog 面板新增 `Enable Depth-Aware Reconstruction` 与 `Reconstruction Strength`，可独立进行画质/性能 A/B。
- 自动基准现在固定 `EShadowMapMode::CSM`，不再继承编辑器持久化的阴影模式。第一轮误继承 `NONE` 的样本目录不作为有效结果。

Showcase 稳态 GPU 时间约 `1.70 ms`：Inject `0.68`、Temporal `0.34`、Integrate `0.08`、Debug `0.02`、Composite `0.59 ms`。相对 Snapshot B 的 `0.954 ms`，High 候选增加约 `0.75 ms`（约 `79%`）；其中全分辨率多 tap 重建是主要新增成本。

同机位有效样本与 Snapshot B 保持高度一致，frame 000 的全图平均绝对差为 `0.286/255`、PSNR 为 `47.25 dB`。这说明改动没有改变雾的整体浓度和调色；变化集中在高反差体积阴影过渡及运动连续性。静态截图差异较细微，最终结论仍应以固定轨迹视频和 RenderDoc GPU 时间为准。

Snapshot C 有效烟测目录：`saved/volumetric_fog_capture_grid6_reconstruct_csm/sunshaft/showcase/`。
运行日志：`saved/codex-logs/MoerEditor-FogGrid6ReconstructCSM-20260802-224253.stdout.log`。

## Snapshot D：方向感知空间重建与时间反应遮罩

Snapshot D 在 6×6 High 候选上继续修改：

- 固定的各向同性 5-tap tent 改为边缘自适应方向重建。
- 基础的 4 点深度感知双线性同时估计积分散射/透射率梯度；平坦区域不再追加采样。
- 只在检测到体积光照边缘时，沿边缘切线方向追加正负两组采样；不会沿法线方向扩大光柱。
- 每个 tap 继续进行几何深度拒绝，避免跨场景轮廓串雾。
- 重建强度由 `0.55` 调整为 `0.75`，边缘触发区间为 `0.03～0.22`，切线采样半径为 `0.95 froxel`。
- 时间重投影新增 Reactive Mask：仅当重投影历史明显越过当前 7 点邻域钳制范围时降低历史权重；稳定阴影边缘继续保持高历史权重。当前候选强度固定为 `0.75`。

Reactive 参数最初被插入 `RasterConfig` 中间，运行日志随即显示 Reset Distance/Angle 错读为 `20/0`，证明该结构跨编辑器/渲染 DLL 的字段偏移不能直接改变。该试改已撤销，Reactive 强度改由 pass 内部写入 push constant；无效样本不参与结论。有效重跑确认 Reset Distance/Angle 为 `2 m / 20°`。

最终 Showcase 稳态 GPU 时间约 `1.32～1.37 ms`：Inject `0.68～0.71`、Temporal `0.33～0.34`、Integrate `0.08～0.09`、Debug `0.02`、Composite `0.20～0.22 ms`。相对 Snapshot C：

- Composite 由约 `0.59 ms` 降低约 `63%～66%`。
- FogTotal 由约 `1.70 ms` 降低约 `20%～23%`。
- 没有新增纹理或显存；froxel 显存仍为 `119.53 MiB`。
- 固定轨迹截图未出现整体雾浓度、色调或几何边缘串雾回归。frame 000 相对 Snapshot C 的全图平均绝对差约 `0.061/255`，大于 `1/255` 的像素约 `3.17%`，变化主要局限于体积光照边缘。

Snapshot D 有效烟测目录：`saved/volumetric_fog_capture_grid6_directional_final/sunshaft/showcase/`。
运行日志：`saved/codex-logs/MoerEditor-FogDirectionalFinal-20260802-230210.stdout.log`。

## Snapshot E：低样本旋转 CSM、独立阴影历史与时域带宽优化

Snapshot E 保持 Snapshot D 的 6×6 High 网格、Showcase 参数、固定轨迹和方向感知重建，修改阴影与时间滤波链路：

- 将原来介质注入内的固定 `3×3` PCF（9 次 CSM 深度查询）拆为独立阴影 pass；PCF1/PCF2 均使用每 froxel 4 个 Poisson 样本，PCF2 只扩大滤波半径。
- Poisson 样本由 FAST 纹理按 froxel 和帧旋转；接收位置仍使用稳定 froxel 中心，不随密度抖动移动。
- 新增 `2×R16F` 阴影历史体积。阴影先完成自身的世界空间重投影与硬件三线性采样，再参与方向光散射，避免阴影噪声直接污染 RGBA 介质历史。
- 主介质时域重投影的历史采样由 8 次显式 `Load` 改为 1 次硬件三线性采样。
- 7 点当前帧邻域钳制使用 4×4×4 工作组中心缓存；内部邻居读取 LDS，仅六个工作组边界回退纹理读取。完整工作组的当前体积读取由 448 次降至 160 次，LDS 占用为 1 KiB。
- froxel 自有显存由 `119.53 MiB` 增至 `133.59 MiB`，增量约 `14.06 MiB`；包含半分辨率调试纹理后为 `135.68 MiB`。

RTX 4060 Laptop GPU、1920×1080 Debug 稳态结果：

- Rotated 4-tap CSM：约 `0.209～0.210 ms`。
- 独立阴影历史：约 `0.116～0.118 ms`。
- 介质 Inject：由 Snapshot D 的 `0.68～0.71 ms` 降至 `0.301～0.303 ms`。
- 主介质 Temporal：由 `0.33～0.34 ms` 降至 `0.297～0.303 ms`；第一版 6×6×6 halo 缓存曾测得 `0.35～0.37 ms`，因同步与 LDS 成本更高而被替换。
- 完整 FogTotal：约 `1.22～1.29 ms`，相对 Snapshot D 的 `1.32～1.37 ms` 约降低 `6%～9%`，同时增加了独立阴影稳定步骤。

五个固定轨迹截图均成功生成，未发现整体浓度、色调或几何轮廓串雾回归。相对 Snapshot D，同轨迹 PSNR 为：frame 000 `55.49 dB`、022 `46.55 dB`、045 `39.07 dB`、067 `39.27 dB`、089 `40.95 dB`；差异随运动增大，符合阴影采样序列及独立历史改变的预期，仍需以连续视频/ROI 时间方差最终判定闪烁改善幅度。

Snapshot E 有效烟测目录：`saved/volumetric_fog_capture_grid6_shadow_history_cache64/sunshaft/showcase/`。
运行日志：`saved/codex-logs/MoerEditor-FogShadowHistory-Cache64-20260802.stdout.log`。
