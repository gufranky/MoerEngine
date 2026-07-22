# MoerEngine 体积雾两周实现计划

> 计划周期：2 周（10 个工作日，单人）
> 目标平台：Windows 11 / Vulkan / RTX 4060 Laptop GPU
> 目标分支：基于当前 `main` 分支
> 目标：参考 Unreal Engine 的核心体积雾方法，在 MoerEngine 光栅化渲染器中实现可交互、可调参、具有体积阴影和时域稳定性的 Froxel 体积雾，并预留至少 3 个工作日用于性能和观感调优。

## 1. 目标与范围

### 1.1 两周内必须完成（P0）

- 与相机视锥对齐的 Froxel 三维网格；
- 指数高度雾密度模型；
- Beer-Lambert 透射率与单次散射积分；
- Henyey-Greenstein 相函数；
- 方向光注入；
- 使用现有 CSM 对方向光体积阴影采样；
- 体积光照沿视线积分；
- 与 HDR 场景颜色正确合成；
- 历史体积纹理重投影、逐帧 Jitter 和历史失效；
- 编辑器开关、质量档位及主要艺术参数；
- GPU Pass 计时、显存占用统计和对比截图；
- 1080p 下可用的实时性能和相机运动时可接受的稳定性。

### 1.2 尽力完成（P1）

- 点光源注入，先支持无体积阴影；
- 基于深度的双边上采样或边缘感知合成；
- 简单球形/盒形局部雾体；
- 3D Noise 调制局部密度；
- 相机静止/运动时使用不同历史权重；
- 雾质量 Low / Medium / High 三档。

### 1.3 本轮明确不做（P2）

- 完整复刻 UE 的 Volume Material 与粒子体积材质系统；
- 体积光照贴图和预计算静态光照；
- 阴影点光源、聚光灯和任意数量局部灯的完整集群剔除；
- 多次散射的物理精确求解；
- 透明物体逐像素体积雾；
- 云、天空大气和体积雾的统一参与介质系统；
- D3D12 后端专项适配；
- 重启当前被注释的 RenderGraph。

这些内容可以作为后续扩展，不应挤占本轮性能和观感调优时间。

## 2. UE 对齐基线

参考 Unreal Engine 官方体积雾实现公开描述，本轮对齐以下核心方法：

1. 在相机视锥中构建低分辨率体积纹理；
2. 在每个体素/Froxel 中计算介质密度和入射光；
3. 支持指数高度分布和方向光体积阴影；
4. 使用低分辨率体积纹理控制性能；
5. 使用逐帧子体素 Jitter 和较强的时域重投影抑制低分辨率闪烁；
6. 沿视线累积散射与透射，随后与场景颜色合成；
7. 提供全局参数，并为局部密度扩展保留接口。

UE 官方参考：

- [Volumetric Fog in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/volumetric-fog-in-unreal-engine)
- [Exponential Height Fog in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/exponential-height-fog-in-unreal-engine)
- [Local Fog Volumes in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/local-fog-volumes-in-unreal-engine)

这里的“对齐 UE 效果”定义为：在相同测试场景和相近参数下，对齐雾的高度衰减、光柱方向、阴影遮挡、远景透射、各向异性观感和相机运动稳定性；不要求两周内复刻 UE 的全部灯光、材质与预计算生态。

## 3. 技术方案

### 3.1 总体数据流

```text
相机 / 深度 / 灯光 / CSM / 雾参数
                  │
                  ▼
        1. Froxel 参数与密度初始化
                  │
                  ▼
        2. 方向光 + 体积阴影注入
                  │
                  ▼
        3. 历史重投影与时域融合
                  │
                  ▼
        4. 沿 Z 切片积分散射/透射
                  │
                  ▼
           SSR（仍在无雾 HDR 上计算）
                  │
                  ▼
        5. 深度感知采样并合成 HDR
                  │
                  ▼
              AA / Bloom / Tonemap
```

体积雾在 HDR 阶段统一合成，位于 AO/Lighting/Skybox/SSR 之后、AA/Bloom/Tonemapping 之前。Day 6 对比确认“先雾后 SSR”会让反射覆盖空气透视，因此最终固定为“先 SSR，后体积雾”。这能让反射面按相机到表面的路径接受与非反射表面一致的雾透射与入射散射。

### 3.2 Froxel 网格

默认质量档建议：

| 档位 | XY Tile | Z Slice | 1080p 约尺寸 | 用途 |
|---|---:|---:|---:|---|
| Low | 16×16 | 48 | 120×68×48 | 性能回退 |
| Medium | 12×12 | 64 | 160×90×64 | 默认目标 |
| High | 8×8 | 96 | 240×135×96 | 效果对比 |

Z 方向使用近处密、远处疏的指数/对数分布。最大雾距离独立于相机 Far Plane，避免无意义地覆盖整个视锥。

建议资源：

- `volume_scattering_extinction`：`RGBA16F`，RGB 为入射散射，A 为消光；
- `volume_history[2]`：`RGBA16F` Ping-Pong；
- `volume_integrated`：`RGBA16F`，RGB 为累计散射，A 为累计透射；
- 可选 `volume_local_density`：`R16F`。

若显存或带宽超预算，优先尝试 `R11G11B10F + R16F` 拆分，而不是先降低 Z Slice。

### 3.3 介质模型

全局密度采用指数高度雾：

```text
density(y) = base_density × exp(-height_falloff × (y - height_offset))
```

消光与散射：

```text
sigma_t = density × extinction_scale
sigma_s = sigma_t × albedo
T(s)    = exp(-sigma_t × s)
```

方向性散射使用 Henyey-Greenstein 相函数，`anisotropy g` 默认 0.2，可调范围建议 `[-0.2, 0.9]`。实现中必须限制极端参数，避免分母接近零导致 NaN 或亮斑。

### 3.4 光照与阴影

- 第一版只注入主方向光和低强度环境项；
- 使用现有 `LightingData`、CSM 变换与 Shadow Map；
- 每个 Froxel 取代表点，选择 CSM 层并采样体积阴影；
- 第一天先使用单次 PCF 或硬阴影验证正确性，性能调优阶段再决定采样数；
- 不在首版复用当前面向表面的 PCSS 全套采样，避免体积网格成本失控；
- 为点光源注入预留循环/灯光列表接口，但 P0 不依赖它。

### 3.5 时域重投影

当前引擎已有相机矩阵、Motion Vector 和时域处理经验，但体积历史应以 Froxel 世界位置重投影到上一帧视锥，而不是直接使用二维 Motion Vector。

最低要求：

- 每帧低差异 Jitter；
- 使用上一帧 ViewProjection 与当前 Froxel 世界位置重投影；
- 判断上一帧 UVW 是否越界；
- 相机切换、分辨率变化、FOV 变化、质量档切换时清空历史；
- 光源或雾参数突变时降低历史权重；
- 当前值与历史值进行邻域范围约束，防止拖影和漏光扩散；
- 默认历史权重从 `0.85–0.95` 区间调试，不写死为最终值。

### 3.6 沿视线积分与合成

沿 Z 切片从近到远执行前向积分：

```text
accumulated_scattering += accumulated_transmittance × slice_scattering
accumulated_transmittance *= slice_transmittance
```

最终使用场景深度确定像素对应的体积切片，并执行：

```text
final_hdr = scene_hdr × transmittance + scattering
```

天空像素积分到最大雾距离，几何像素积分到其深度。必须检查引擎 Reverse-Z、深度线性化和世界坐标重建约定。

### 3.7 与当前引擎的集成原则

- 沿用 `RasterRenderer`、`RasterContext`、`CommandList` 和现有 Compute Pipeline；
- 不依赖当前大面积注释的 RenderGraph；
- 使用 RHI 已支持的 `Extent3D`、`Texture3D`、`RWTexture3D`；
- 在窗口尺寸或质量档变化时重建体积资源；
- 所有资源必须正确释放 Bindless Handle；
- 每个子 Pass 加 GPU Time Scope；
- Shader 参数保持 C++/HLSL 布局一致，避免 scalar array 的 std140 对齐问题；
- 体积雾关闭时不得执行 Dispatch，且必须直接返回输入 HDR 纹理。

## 4. 预计代码改动

建议新增：

```text
source/runtime/render/renderer/raster/
  VolumetricFogPass.h
  VolumetricFogPass.cpp
  VolumetricFogResource.h
  VolumetricFogResource.cpp

source/runtime/render/shaderheaders/shared/raster/
  volumetric_fog/ShaderParameters.h

shaders/pipelines/raster/volumetric_fog/
  VolumetricFogCommon.hlsli
  InjectDensityAndLighting.hlsl
  TemporalReprojection.hlsl
  IntegrateScattering.hlsl
  CompositeVolumetricFog.hlsl
```

建议修改：

```text
source/runtime/render/renderer/raster/RasterRenderer.h/.cpp
source/runtime/render/renderer/raster/RasterConfig.h
source/runtime/render/renderer/raster/RasterResource.h
source/editor/raster_ui/RasterUI.cpp
source/runtime/render/shaderheaders/shared/raster/ShaderParameters.h
```

是否把体积纹理加入 `RasterTextures`，在第 1 天 RHI 3D 纹理冒烟测试后决定。更推荐由 `VolumetricFogResource` 独立管理，因为其尺寸不是屏幕二维分辨率，且需要历史 Ping-Pong。

## 5. 两周排期

### 第 1 周：正确性与基本效果

#### Day 1：设计冻结与 RHI 冒烟测试

- 确认当前 Reverse-Z、矩阵乘法和世界坐标约定；
- 验证 Vulkan `Texture3D/RWTexture3D` 创建、绑定、写入和采样；
- 创建最小 Compute Shader，向 3D 纹理写测试渐变；
- 确认资源释放、窗口 Resize 与 Bindless 更新；
- 建立 GPU Profile Scope；
- 固化 Medium 网格尺寸与内存预算。

交付：3D 纹理冒烟测试通过；若 RHI 3D UAV 存在缺陷，当天修复，最迟 Day 2 上午关闭该风险。

#### Day 2：Froxel 重建与基础密度

- 新建 `VolumetricFogResource` 和 Pass 框架；
- 实现屏幕/Froxel 坐标到 View/World Position；
- 实现指数高度密度；
- 实现无阴影环境散射；
- 实现调试可视化：Z Slice、密度和消光。

交付：相机移动时雾层稳定地绑定在世界空间，高度衰减方向正确。

#### Day 3：方向光、相函数与体积阴影

- 接入主方向光；
- 实现 Henyey-Greenstein 相函数；
- 接入 CSM 变换和 Shadow Map；
- 实现 Froxel 方向光阴影采样；
- 加入体积散射强度和阴影开关。

交付：Sponza 拱门、柱体等遮挡能形成可见光柱，前向/后向散射变化符合预期。

#### Day 4：沿视线积分与 HDR 合成

- 计算每个 Z Slice 的散射与透射；
- 实现前向积分；
- 使用几何深度截断积分；
- 合成到 HDR 后处理链；
- 检查天空、近裁剪面、远距离和相机进入几何体等边界情况。

交付：基础体积雾完整跑通，可通过 UI 开关，不出现明显 NaN、黑屏或曝光错误。

#### Day 5：时域重投影 MVP

- 添加当前/历史 3D 纹理 Ping-Pong；
- 添加每帧 Jitter；
- 用 Froxel 世界位置投影到上一帧 UVW；
- 加入越界和相机变化判定；
- 实现基础历史融合；
- 制作静止、平移、旋转三组对比录屏。

交付：静止画面噪声和分层明显降低；运动时允许有轻微拖影，但不得出现历史完全错位。

### 第 2 周：稳定性、性能与观感

#### Day 6：历史有效性与合成顺序调优

- 加入历史邻域 Clamp；
- 雾参数、光源变化时动态降低历史权重；
- 处理相机 Cut、FOV 和分辨率变化；
- 比较“雾在 SSR 前/后”的结果；
- 修复深度边缘漏雾和 Halo；
- 固化最终后处理顺序。

交付：常规相机运动下无大面积鬼影；几何边缘无明显亮边或穿透。

#### Day 7：GPU 性能优化

- 分 Pass 记录 GPU 时间；
- 检查 3D 纹理格式和带宽；
- 调整线程组尺寸；
- 合并可合并的密度/光照阶段；
- 减少 CSM 采样次数和分支；
- 实现 Low / Medium / High 档位；
- 必要时加入 Checkerboard/Froxel 稀疏更新，但不牺牲正确性。

交付：Medium 1080p 达到目标预算，三个质量档可稳定切换且不会复用错误历史。

#### Day 8：观感调优与 UE 对比

- 在 Sponza 建立固定相机、固定灯光和固定曝光测试位；
- 在 UE 建立尽可能相同的测试场景或使用等价几何；
- 对齐密度、高度衰减、最大距离、Albedo、Anisotropy；
- 调整 Z 分布、阴影采样和历史权重；
- 输出关闭雾、MoerEngine、UE 三组截图；
- 记录不能对齐的原因，区分算法差距与场景/曝光差距。

交付：至少 3 个固定机位的 UE 对照图；光柱、远景衰减和高度分层主观接近。

#### Day 9：鲁棒性与可选增强

- 测试强光、弱光、室内、室外、逆光、快速旋转；
- 测试不同分辨率和窗口 Resize；
- 修复闪烁、Banding、过曝、漏光和拖影；
- 若 P0 全部稳定，选择一个 P1：点光源注入或局部球形雾；
- 不允许为了 P1 推迟 P0 修复。

交付：问题清单清零到可接受范围；可选功能至少完成一个时才合入。

#### Day 10：最终验收与文档

- Clean Build；
- 运行 15 分钟稳定性测试；
- GPU 时间与显存复测；
- 输出质量档对比；
- 输出性能表、参数表、已知限制；
- 录制最终演示视频；
- 整理实现说明和后续优化方向。

交付：可复现构建、演示视频、UE 对比、性能数据、实现文档和已知问题列表。

## 6. 性能预算

基准设备为本机 RTX 4060 Laptop，1920×1080，Sponza，Raster 路径，固定相机和固定曝光。

目标：

| 档位 | 目标 GPU 增量 | 可接受上限 | 说明 |
|---|---:|---:|---|
| Low | ≤ 0.8 ms | 1.2 ms | 低成本回退 |
| Medium | ≤ 1.5 ms | 2.0 ms | 默认验收档 |
| High | ≤ 2.8 ms | 3.5 ms | 截图/高质量 |

额外约束：

- Medium 体积纹理新增显存目标 ≤ 32 MiB；
- 关闭体积雾时 GPU 增量接近 0；
- 不因体积雾引入每帧 CPU/GPU 强制同步；
- 相机静止时帧时间不得周期性尖峰；
- Resize、质量切换和历史清空不得泄漏纹理或 Bindless Handle。

UE 官方性能数据仅用于方法参考，不直接作为横向成绩，因为硬件、场景、分辨率和版本不同。最终报告必须使用本项目实测数据。

## 7. 观感验收标准

### 7.1 必须通过

- 无雾时和当前主分支结果一致；
- 开启雾后，近处清晰、远处逐渐衰减；
- 高度雾随世界高度变化，而不是跟随相机移动；
- 逆光时形成方向正确的光柱；
- 柱体和墙体能阻挡体积光；
- 相机静止时无明显 Froxel 分层和随机闪烁；
- 缓慢移动时无明显抖动；
- 快速旋转后历史可在短时间内恢复，不留下长时间残影；
- 几何边缘没有明显漏雾、亮边和深度穿透；
- 曝光变化时散射颜色不出现异常爆亮；
- Low/Medium/High 的质量与性能变化符合预期。

### 7.2 UE 对比方法

- 相同分辨率、FOV、相机位置和曝光；
- 尽可能相同的方向光方向、色温与强度；
- 关闭不相关后处理，避免 Bloom、自动曝光和色调映射掩盖问题；
- 分别比较：无阴影雾、体积阴影、前向散射、相机运动；
- 每个机位记录参数，不只保存截图；
- 对无法直接对应的 UE 参数写出换算或调参依据。

## 8. 调试与测量工具

实现以下可视化模式：

- Froxel Z Slice；
- Density；
- Extinction；
- Incident Scattering；
- Integrated Scattering；
- Transmittance；
- Volumetric Shadow；
- History Weight；
- Reprojection Validity。

性能记录至少拆分：

- Inject Density/Lighting；
- Temporal Reprojection；
- Integrate；
- Composite；
- Total Volumetric Fog。

每次调优必须在固定机位记录“参数、GPU 时间、截图”，避免只凭即时观感反复调参。

## 9. 风险与降级方案

| 风险 | 最晚发现时间 | 处理方式 |
|---|---|---|
| Vulkan 3D UAV 绑定或 Shader 反射异常 | Day 1 | 当天修 RHI；Day 2 仍阻塞则用 2D Array 临时承载切片 |
| CSM 数据难以在 Compute Pass 复用 | Day 3 | 先使用主级 Shadow Map 或无阴影完成积分，再补完整级联 |
| 时域重投影拖影严重 | Day 6 | 降低历史权重，增加 Clamp；保留无时域高质量模式用于对照 |
| 体积纹理带宽超预算 | Day 7 | 降低 XY、拆分格式、合并 Pass；最后才减少 Z Slice |
| 深度边缘 Halo | Day 6 | 使用深度感知采样；必要时合成阶段取邻域最近深度 |
| 两周范围膨胀 | 每日 | P1 不得影响 P0；Day 8 后冻结功能，只修质量与性能 |

触发降级时的保留优先级：

1. 正确的指数高度雾与视线积分；
2. 方向光与 CSM 体积阴影；
3. 时域稳定性；
4. 性能档位；
5. 点光源；
6. 局部雾与 3D Noise。

## 10. 每日完成定义

每天结束前必须满足：

- 当日代码可编译；
- 编辑器可启动并运行目标场景；
- 新增 Pass 可单独关闭；
- 有至少一张固定机位截图或一段短录屏；
- 记录 GPU 时间；
- 更新问题列表和次日优先级；
- 不把已知崩溃、资源泄漏或历史错位带入下一阶段。

## 11. 最终交付物

- 完整体积雾源代码与 Shader；
- 编辑器参数面板和质量档位；
- UE 对比截图与参数记录；
- 静止、慢速移动、快速旋转三类演示视频；
- Low/Medium/High GPU 时间与显存表；
- 关闭/开启体积雾的回归对比；
- 算法说明、资源布局、Pass 数据流；
- 已知限制和下一阶段路线图。

## 12. 两周结束后的扩展路线

后续按价值排序：

1. Clustered Point/Spot Light 注入；
2. 有阴影局部灯；
3. 局部雾体积与 3D Noise；
4. 更稳健的时域 Clamp 和响应式历史权重；
5. 透明物体体积雾；
6. 天空大气/云/雾统一合成；
7. 体积光照缓存或多次散射近似；
8. D3D12 与多平台质量分级。

## 13. 实施记录

### 2026-07-14：Day 1 基础验证

- 已确认引擎使用 Reverse-Z；Hi-Z 对 2×2 深度执行 `min` reduction，后续体积合成需用现有深度重建约定；
- 已确认 CPU 侧相机矩阵传入 Shader 前通常执行 `Transpose`，HLSL 侧使用 `mul(matrix, vector)`；
- 已确认 Vulkan RHI 支持 `Extent3D`、`Texture3D`、`RWTexture3D` 和 3D Texture View；
- 已建立 `VolumetricFogPass` 骨架和独立资源生命周期；
- Medium 基线固定为 XY 每 12×12 像素一个 Froxel、Z=64；1920×1080 时为 160×90×64；
- 已添加 `RGBA16F` 3D UAV 写入 Shader 和 3D SRV 采样 Shader；两个 Shader 均通过 DXC Vulkan 1.3 SPIR-V 编译；
- 已接入窗口 Resize 资源重建和 `Volumetric Fog Day1 Smoke Test` GPU Time Scope；
- 已添加默认关闭的开发开关，关闭时不记录 Dispatch；
- C++ Debug 构建通过，编辑器在 RTX 4060 Laptop / Vulkan 1.4 上运行 60 秒无立即崩溃；
- 当前系统未安装 `VK_LAYER_KHRONOS_validation`，后续应补装 Vulkan SDK/Validation Layer，避免只依赖运行结果判断资源屏障正确性。

### 2026-07-21：Day 2 基础介质

- 已将开发资源扩展为相机对齐的 `160×90×64` Froxel 网格；
- 已实现指数分布的 View-Z 切片，并按引擎 Reverse-Z 与矩阵约定重建 Froxel 世界坐标；
- 已实现指数高度密度、消光系数、Albedo 与环境入射散射，`MediumVolume.RGB` 保存散射、A 保存消光；
- 已注册全分辨率 `volumetric_fog_debug` 调试纹理，支持 Scattering、Density 和 Extinction 切片；
- 已通过固定切片确认高度变化来自世界空间高度而非屏幕渐变；
- 1920×1080 下基础 `RGBA16F` 介质纹理约占 7.03 MiB；
- 全量 Debug 构建与 Sponza 运行验证通过。

### 2026-07-21：Day 3 方向光与体积阴影

- 已接入场景主方向光颜色、方向和强度，并增加独立体积方向光强度参数；
- 已实现 Henyey–Greenstein 相函数，`g` 可在 `[-0.9, 0.9]` 范围调节，默认值为 0.2；
- 已复用现有 `LightingData` 的四级 CSM 矩阵、分割比例、Shadow Map Bindless Handle 和 Reverse-Z 深度约定；
- 已实现每 Froxel 的级联选择、0～2 半径 PCF、可调 Shadow Bias，以及无有效方向光时自动禁用阴影采样；
- 已增加 `R16F` 的 `ShadowVisibility` 三维纹理，总体积雾资源约占 8.79 MiB；
- 已增加 `CSM Shadow Visibility` 调试模式和对应 UI 参数；
- DXC Vulkan 1.3 SPIR-V 独立编译通过，C++ 全量干净构建通过；
- 运行日志确认 `phase_g=0.2`、`csm_shadows=1`、`pcf_radius=1`；
- A/B 验证：关闭体积 CSM 阴影时可见度切片为全白，开启后第 51 层出现稳定黑白遮挡边界，证明级联矩阵、阴影句柄、Reverse-Z 比较与三维写入链路生效；
- 发现并定位一次增量构建 ABI 错位：`RasterConfig` 新增字段后旧目标把 `shadow_map_mode` 读取为无效枚举。全量干净构建后问题消失；UI 另增加 framebuffer 索引防御；
- Day 3 仅完成 Froxel 注光，主画面合成要等 Day 4 的沿视线积分，因此当前不以最终雾效观感作为验收依据。

### 2026-07-22：Day 4 沿视线积分与 HDR 合成

- 新增 `IntegratedScattering` RGBA16F 三维纹理，按每条 Froxel 视线从近到远累计散射 `L` 与透射率 `T`；
- 使用解析形式的 Beer–Lambert 单段积分：`T = exp(-sigma_t * ds)`，并用 `(1 - T) / sigma_t` 避免小步长下的能量误差；
- Z Slice 边界继续使用指数 View-Z 分布，射线段长度会根据视线方向的 View-Z 分量换算，避免屏幕边缘路径长度偏短；
- 新增全分辨率 `volumetric_fog_output` HDR 纹理，并在 AO/双边去噪之后、SSR/Bloom/Tonemapping 之前执行体积雾合成；
- 合成阶段读取 Reverse-Z 几何深度，将其线性化后只采样到可见表面；天空像素积分到 Fog Max Distance；
- 关闭体积雾时直接返回输入 HDR 纹理，不提交注光、积分或合成 Dispatch；
- 新增 `Integrated Scattering` 与 `Transmittance` 调试视图，并将 GPU 时间范围拆成 Light Injection、Beer-Lambert Integration、Debug Visualize 和 HDR Composite；
- 三张 Froxel 纹理（RGBA16F + R16F + RGBA16F）在 160×90×64 下共约 15.82 MiB；另有一张 1920×1080 RGBA16F 合成纹理约 15.82 MiB，总新增显存约 31.64 MiB，仍在 Medium 32 MiB 目标内；
- DXC Vulkan 1.3 SPIR-V 编译通过，C++ 全量干净构建与后续增量构建通过；运行日志确认 64 层积分和 1920×1080 深度感知 HDR 合成已启用；
- 运行验证：最远层透射率从画面高处接近 1 向地面连续衰减到接近 0，符合世界空间指数高度雾规律；编辑器无黑屏、NaN、设备丢失或崩溃；
- 当前已知画质项：合成阶段 XY 方向仍为最近 Froxel 采样，较强雾下可能暴露 12×12 像素块状边界；Day 6 应改为深度感知双线性/邻域采样并处理几何边缘 Halo。累计散射调试默认曝光 8 在远层容易饱和，后续需重新标定调试曝光范围；
- 当前主画面参数属于克制的基础高度雾，Day 8 再按固定机位与 UE 对齐密度、方向光强度、曝光和色调映射，不在 Day 4 提前用单场景参数掩盖算法问题。

### 2026-07-22：Day 5 时域重投影 MVP

- 新增两张 `RGBA16F` Froxel 历史纹理并采用 Ping-Pong 写入，历史处理位于方向光注入之后、Beer–Lambert 积分之前；
- 新增 `TemporalReprojection.hlsl`：重建当前抖动 Froxel 的世界位置，投影到上一帧 View/Projection，反算上一帧指数 Z Slice，并手工执行 8 邻域三线性历史采样；
- 使用 Halton 2/3/5 序列生成三维 Froxel Jitter，分别扰动 XY 像素覆盖和指数深度层内位置；关闭时域时会同步关闭 Jitter，确保无历史基线稳定；
- 历史融合默认权重为 0.90，首帧、重新启用、窗口 Resize、FOV/近远裁剪面/最大雾距离变化时直接使用当前帧；
- 增加相机突变防御：单帧位移超过 2 m 或朝向变化超过 20° 时放弃旧历史；阈值可在 UI 调节；
- 密度、高度衰减、消光、Albedo、环境光、方向光比例、相函数、阴影开关/PCF/Bias 和 Jitter 设置变化时会立即清空历史，避免调参后旧雾缓慢残留；
- 新增独立 GPU 时间范围 `Volumetric Fog Day5 Temporal Reprojection`，可与 Injection、Integration、Composite 分开测量；
- DXC Vulkan 1.3 SPIR-V 独立编译通过；C++ 共享结构全量干净构建及后续增量构建通过；运行时 Shader 编译、资源绑定和 Ping-Pong 状态转换无报错；
- 运行日志确认 `history_weight=0.900`、`jitter=1`、`reset_distance=2.00`、`reset_angle=20.0`，并通过 Jitter 开关 A/B 确认设置变化会触发历史失效；
- 静止画面对照：关闭 Jitter、保留历史时会收敛回单帧结果；开启 Jitter 后会积累不同 Froxel/体积阴影采样，远端雾化和散射更连续，未观察到加法能量无限累积；
- 当前限制：Day 5 只实现基础历史融合，尚无邻域 Clamp、响应式历史权重和显式 History Validity 调试图，快速旋转的拖影控制留到 Day 6；
- 显存风险：两张历史纹理额外占用约 14.06 MiB，使 Froxel 纹理达到约 29.88 MiB，加上全分辨率 HDR 合成纹理后总新增显存约 45.70 MiB，暂时超过 Medium 32 MiB 目标；Day 7 必须通过资源复用、历史格式压缩或降低部分纹理精度回收显存。

### 2026-07-22：Day 6 历史有效性与合成顺序调优

- 历史重投影加入当前帧 `3×3×3` 邻域 Min/Max Clamp，并提供 `History Clamp Expansion` 参数，默认以邻域动态范围的 10% 放宽边界，抑制旧雾能量在新遮挡区域拖尾；
- 在固定基础历史权重之上加入运动响应：扣除当前/上一帧 Froxel Jitter 的预期位移后，根据剩余重投影距离指数衰减历史权重；新增 `History Motion Response` 参数，默认 0.35；
- 新增 `R16F` 二维 `TemporalDebugSlice` 与 `History Weight` 热力图。静止镜头中主体稳定为约 0.9 的红色，重投影越界边界为蓝色；关闭时间重投影后整屏归零为蓝色，确认不会显示陈旧历史；
- 继续保留 Day 5 的相机 Cut、FOV、近远裁剪面、Resize、最大雾距离和全部雾/光照参数变化失效规则；首帧与重新启用时历史权重为 0；
- HDR 合成由最近 XY Froxel 采样改为 XY 双线性 + 指数 Z 线性插值的三线性采样，主画面不再直接暴露 12×12 像素块边界；几何深度仍逐像素决定积分终点，因此不会跨像素混合场景深度；
- 对比 SSR 合成顺序：原“体积雾 → SSR”会让最后写入的反射缺少一致空气透视；最终固定为 `AO/去噪 → SSR → 体积雾 → AA/Bloom/Tonemapping`，复测中远处地面反射受到雾衰减，同时近处反射高光仍保留；
- `TemporalReprojection.hlsl`、`CompositeVolumetricFog.hlsl` 与 `DebugVisualize.hlsl` 均通过 DXC Vulkan 1.3 SPIR-V 独立编译；共享结构全量干净构建和 SSR 顺序增量构建均通过；
- 运行日志确认 `history_weight=0.900`、`motion_response=0.350`、`clamp_expansion=0.100`，无 Shader、资源绑定、Vulkan 设备或 NaN 错误；Sponza 同时启用体积雾与 SSR 时编辑器显示整帧约 31 ms，该数字仅用于烟雾测试，不作为 GPU Pass 预算结论；
- 当前限制：邻域 Clamp 每 Froxel 读取 27 个当前帧样本，正确性优先但带宽成本偏高；Day 7 需要用组共享内存、十字/分离邻域或低成本统计近似优化，并单独测量 GPU Scope。Computer Use 的离散按键不能形成持续高速旋转，本日验证覆盖静止、开关 A/B、越界和 SSR 顺序，高速旋转拖影仍需人工长按/鼠标操作补充压力测试；
- Day 6 的初步统计只计入 29.88 MiB Froxel 与 15.82 MiB HDR 合成纹理，遗漏了全分辨率 RGBA16F 调试图；按实际新增分配复核约为 61.52 MiB。Day 7 必须复用合成 Scratch 并降低仅供观察的调试资源规格。

### 2026-07-22：Day 7 第一阶段性能与资源优化

- 历史邻域 Clamp 从完整 `3×3×3` 的 27 Tap 改为中心点加 XYZ 六轴邻居的 7 Tap，当前帧邻域纹理读取减少约 74%；DXC Vulkan 1.3 SPIR-V 体积由约 18.3 KiB 降至 12.2 KiB；
- 审计确认 `upsample_output` 在现有 Raster 后处理链中没有生产者或消费者，将其增加 UAV 用途并作为体积雾 HDR 合成 Scratch，删除独占的全分辨率 `volumetric_fog_output`，节省 15.82 MiB；
- `volumetric_fog_debug` 改为半分辨率 RGBA8。调试图属于 LDR 切片/热力图，不需要 RGBA16F；1080p 下由 15.82 MiB 降至约 1.98 MiB；
- Medium 1080p 的实际体积雾自有资源现在为 29.88 MiB Froxel + 约 0.03 MiB History Weight 切片 + 1.98 MiB 调试图，共 31.89 MiB，回到 32 MiB 目标内；复用的 `upsample_output` 属于引擎既有 Scratch，不重复计入；
- 全量干净构建 911 步通过；运行日志确认 `owned_memory_with_half_res_debug=31.89 MiB`，半分辨率 Incident Scattering 与 History Weight 调试输出均可正常铺满视口；
- 为避免默认一开启就是开发期白雾，基线参数改为 `Base Density=0.006`、`Height Falloff=0.12`、`Ambient Intensity=0.25`、`Scattering Intensity=0.75`、`Directional Intensity=0.50`、`Fog Max Distance=60m`。滑块范围不变，后续 UE 对齐仍以固定机位实测为准；
- 同一 Sponza 启动镜头的编辑器整帧粗测约为：关闭雾 27.4 ms、开启雾 30.8 ms。约 3.4 ms 差值包含调度波动与整条渲染链，只作为烟雾测试，不能代替 GPU Scope 的逐 Pass 结论；
- 后续仍需用 GPU Scope 获取 27 Tap/7 Tap 的实际毫秒差，并针对相机连续旋转验证六轴 Clamp 是否需要更大的 Expansion 或质量档位切换。
- 用户复测仍能观察到明显体积雾轮廓。代码审计确认 Day 6 的 XY 双线性只考虑屏幕距离，未比较四个 Froxel 代表像素的场景深度；在前景/背景深度断层处会把背景雾混入物体轮廓。现增加深度引导权重：同深度层保持双线性，深度差异按相对距离指数衰减，极薄轮廓四邻域均失配时回退到最近 Froxel；不增加纹理或显存。
- 深度保边后用户复测仍报告边缘闪烁。时间重投影审计发现原 `History Motion Response=0.35` 会在约一个 Froxel 的运动下把 0.90 历史权重降至约 0.63，重新暴露逐帧 Jitter/CSM 采样。默认历史权重调整为 0.94、运动响应降为 0.15；Temporal Pass 根据当前 7 Tap 邻域的散射/消光对比识别高变化边界，边界最多提升到 0.98 历史权重并把运动惩罚降至 35%，仍由邻域 Clamp 限制拖影。
- 进一步用静止镜头做 12 帧 A/B：关闭 Probe GI 与 RTAO 后无雾底噪为 0；开启雾与 Jitter 后平均帧差为 1.16/255，关闭 Jitter 后降为 0；保留 Jitter、关闭体积 CSM 后仍为 0.96/255，证明 Jitter 是主因，CSM 只放大高对比边界。根因是 Temporal Pass 把已经代表“固定 Froxel 单元时间平均”的历史纹理继续按相邻两帧 Halton 差值平移重采样。现改为稳定网格语义：Jitter 仅用于当帧注入取样，历史重投影使用未抖动单元中心，静止相机精确回到同一历史 Texel。
- 稳定历史网格后继续隔离，确认剩余可见闪烁集中在开启 CSM 的光柱与遮挡轮廓。原因是二值阴影比较使用了逐帧变化的 Jitter 世界坐标，PCF 核会在高对比阴影边界反复跨边。现将光照相位与 CSM 查询固定到未抖动 Froxel 中心，只保留密度取样的空间 Jitter，在保留深度层带抑制能力的同时消除阴影轮廓随机游走。
- 2026-07-22 复测：Debug 构建通过；在 Probe GI/RTAO 关闭的隔离环境中，以 `CSM=On + Froxel Jitter=On + Temporal=On` 连续观察静止帧，并执行跨 Froxel 的前移与小幅连续运动，未再观察到光柱/遮挡轮廓随机游走或运动后回跳。恢复 Probe GI 与 RTAO 后完整渲染链路仍稳定。运行日志仅包含预期的设置变更和 camera-cut 历史重置，无体积雾着色器、资源或 NaN 错误。
