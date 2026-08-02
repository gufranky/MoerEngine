# MoerEngine 特性、差异化优势与 Unreal Engine 对比调研报告

> 调研日期：2026-08-01
>
> 本地代码基线：`1227f31`
>
> UE 对照版本：Unreal Engine 5.8 官方文档
>
> 调研方法：README 与设计文档初筛、关键执行路径代码审计、运行日志交叉验证、UE 官方资料对照。

## 1. 结论摘要

MoerEngine 当前仍是早期开发阶段的实时渲染研究引擎。它在最终画质、内容生产工具、平台覆盖、稳定性、可伸缩性和大型场景能力上都不能与 Unreal Engine 直接竞争。UE 5.8 的 Nanite、Lumen、TSR、RDG、Path Tracer、材质系统、编辑器和生产工具链明显更成熟。

MoerEngine 真正有价值的地方不是“某项功能 UE 完全没有”，而是以下能力以较小、开放、容易修改的代码规模组合在一起：

1. 光栅化和硬件光线追踪两条渲染路径并存，并实际接入 ReSTIR DI；
2. 光栅路径具有自研的动态 Ray Query Probe GI，包括自适应层次、稀疏 Brick、物理页分配、Streaming、Prefetch、Clipmap、Dirty Tracking 和更新预算；
3. Cluster DAG LOD 已贯通模型导入、CPU/GPU Scene 和 GPU Culling，而不是只有离线切分代码；
4. RHI 采用显式资源状态、Bindless、命令依赖分析和 Vulkan Descriptor Buffer 风格实现；
5. HLSL 运行时编译、Shader Mutation、依赖跟踪、磁盘缓存和 C++/HLSL 共享结构适合快速图形实验；
6. GUI、嵌入式 Python、HTTP、WebSocket 和 MCP 共用同一套 Scene 修改语义，形成了面向自动化与智能体的渲染实验闭环；
7. Apache-2.0 开源，核心渲染路径足够小，研究者可以完整追踪一个算法从场景数据到最终像素的全过程。

因此，MoerEngine 相对 UE 的优势应定义为：

> **MoerEngine 不是更强的通用商业引擎，而是更透明、更轻量、更容易进行跨层算法改造和自动化实验的现代渲染研究平台。**

其中最有辨识度、也最值得继续投入的两项资产是：

- **动态稀疏层次化 Probe GI；**
- **场景 API、Python、Remote 和 MCP 组成的智能体可控渲染实验环境。**

## 2. “独有特点”的判断标准

严格地说，Bindless、ECS、ReSTIR、Cluster LOD、Python 和 HTTP 都不是 MoerEngine 首创。报告中的“独有”指以下三种情况之一：

1. 当前 MoerEngine 自己实现了具有明确数据结构和调度策略的方案，而不是简单调用第三方黑盒；
2. 多项常见技术在同一个轻量引擎里形成了少见的组合；
3. 与 UE 相比，MoerEngine 在可读、可改、可测方面形成工程优势。

成熟度使用四级标记：

| 等级 | 含义 |
|---|---|
| A：已运行验证 | 已有完整执行路径，并在当前环境看到真实运行结果 |
| B：代码已接通 | 有完整 CPU/Shader 调用链，但本轮未对所有场景做系统验证 |
| C：实验性 | 能运行或具备主要实现，但存在明显规模、平台或工作流限制 |
| D：骨架/停放 | 目录或接口存在，但不能作为当前有效能力 |

## 3. MoerEngine 的主要特性与代码完成度

### 3.1 动态稀疏层次化 Probe GI：最强的差异化技术资产

成熟度：**A/B**

这套系统不是简单的均匀探针网格。代码中可以确认以下组成：

- 使用 Inline Ray Query 对当前 Resident Brick 中的探针进行 DDGI 更新；
- 多 Probe Volume 和多级 Cell/Brick 层次；
- 根据几何占用进行自适应放置与细分；
- 虚拟页到物理 Probe 存储的映射和代际校验；
- 物理 Probe 分配器、延迟退休和容量驱逐；
- Resident/Pending/Retiring 等 Streaming 状态；
- 基于相机运动的 Prefetch、Clipmap 滚动和 L0 Brick 复用；
- 几何、动态物体、灯光、材质的 Dirty Reason；
- 更新 Scheduler、Brick/Probe Budget 和延迟更新统计；
- Irradiance/Visibility Atlas，以及针对漏光和可见性的采样逻辑；
- Probe、Cell、Brick、Streaming、Dirty 等调试可视化。

关键证据：

- [`ProbeUpdatePass.h`](../source/runtime/render/renderer/raster/ProbeUpdatePass.h) 中存在 Resident Brick Ray Query Dispatch；
- [`ProbeUpdate.comp.hlsl`](../shaders/pipelines/raster/deferred/lighting/ProbeUpdate.comp.hlsl) 使用 `RayQuery` 和 `TraceRayInline`；
- [`ProbeVolumeResource.h`](../source/runtime/render/renderer/raster/ProbeVolumeResource.h) 暴露自适应层次、物理容量、Streaming、Clipmap、Prefetch、Dirty 和 Scheduler 快照；
- [`ProbeGI.hlsli`](../shaders/pipelines/raster/deferred/lighting/ProbeGI.hlsli) 处理层次定位、页表、Streaming 状态、Atlas 插值和调试模式。

它的独特价值不是“质量超过 Lumen”，而是把动态 GI 拆成了一组可以独立观测和修改的研究变量：

- 探针怎么放；
- 哪些区域驻留；
- 哪些更新被延迟；
- 动态变化多久传播；
- 物理容量不足时驱逐谁；
- 如何在漏光、响应速度和开销之间取舍。

这比将 GI 视为一个整体黑盒，更适合研究生做调度、Streaming、动态更新和参与介质耦合实验。

当前限制：

- 仍是实验系统，场景规模和长期稳定性没有 UE Lumen 的产品级验证；
- 质量依赖探针分布、Visibility 参数和更新预算，容易出现漏光与延迟；
- Shader 复杂度较高，冷编译时间明显；
- 缺少完整的平台分级和大规模基准。

### 3.2 双渲染器与 ReSTIR DI

成熟度：**B/C**

MoerEngine 同时维护光栅化渲染器和硬件光追渲染器。光追 Lighting Pass 已接通：

1. Light/Envmap Presampling；
2. Initial Reservoir 生成；
3. Temporal Resampling；
4. Spatial Resampling；
5. 最终 Shading；
6. 可选 NVIDIA NRD 降噪。

关键证据位于：

- [`LightingPass.cpp`](../source/runtime/render/renderer/raytracing/LightingPass.cpp)；
- [`LightingPass.h`](../source/runtime/render/renderer/raytracing/LightingPass.h)；
- [`restir_di`](../shaders/pipelines/raytracing/restir_di) Shader 目录。

相对 UE 的优势不是最终效果，而是 ReSTIR 的 Reservoir、时空重采样和可见性测试都直接暴露在项目代码中，可以方便地修改候选样本数、邻域策略、权重、历史拒绝和调试输出。它适合：

- ReSTIR 变体研究；
- 光源采样研究；
- 时空复用稳定性研究；
- 自研降噪器或神经降噪器接入。

当前限制：UE Path Tracer 已具备更完整的材质、反射/折射、Sequencer 和 Movie Render Queue 集成；MoerEngine 当前更接近算法实验渲染器，而不是生产级离线渲染器。

### 3.3 Cluster DAG LOD 与 GPU Driven Culling

成熟度：**B/C**

MoerEngine 的 Cluster LOD 已经形成完整链路：

```text
Assimp 导入
  -> ClusterBuilder / meshoptimizer
  -> Cluster Group DAG 与误差数据
  -> LogicalScene / CpuScene
  -> GpuScene Buffer
  -> GPU Culling
  -> 屏幕空间误差选择 LOD 切面
  -> Vertex Pulling / 间接绘制
```

关键证据：

- [`ClusterBuilder.cpp`](../source/runtime/render/scene/loader/assimp/ClusterBuilder.cpp) 调用 Cluster LOD 构建并生成父子 Group；
- [`CpuScene.cpp`](../source/runtime/render/scene/CpuScene.cpp) 将局部 Group ID 转换成全局 GPU Scene 索引；
- [`GpuScene.cpp`](../source/runtime/render/scene/GpuScene.cpp) 创建并上传 Cluster Group Buffer；
- [`Cull.comp.hlsl`](../shaders/pipelines/raster/culling/Cull.comp.hlsl) 根据屏幕误差执行 O(1) 的 Cluster 激活判断。

这个实现很适合研究“导入期几何结构如何传递到运行时 GPU 决策”，也方便增加：

- DAG 自顶向下遍历；
- Cluster Streaming；
- Cluster 级遮挡剔除；
- LOD 误差模型；
- Raster 与 RT 几何表示共享。

但它不能与 Nanite 等价。当前 Shader 明确保留两个规模问题：百万 Cluster 时的平铺遍历，以及全局 Atomic 争用。它也没有 Nanite 的按需磁盘 Streaming、软件光栅路径、细粒度压缩和裂缝处理能力。

### 3.4 显式 RHI、Bindless 与命令依赖重排

成熟度：**B/C**

RHI 侧可以确认：

- Vulkan 为当前主要后端，D3D12 为部分支持；
- Graphics/Compute/Copy 等队列抽象；
- Buffer、Texture、Acceleration Structure 的显式资源状态；
- Bindless Buffer/Texture/Sampler；
- Vulkan Descriptor Buffer 风格的描述符数据；
- BLAS/TLAS 构建和更新；
- 命令访问资源分析、读写层次记录和重排；
- 可选 NRD、CUDA/Vulkan Interop、PIX/RenderDoc/Perfetto 接口。

关键证据：

- [`RHI.h`](../source/runtime/render/rhi/RHI.h)；
- [`RHICmdReorderer.h`](../source/runtime/render/rhi/vulkan/RHICmdReorderer.h)；
- [`VulkanRHIResource.cpp`](../source/runtime/render/rhi/vulkan/VulkanRHIResource.cpp)；
- [`VulkanCommandList.cpp`](../source/runtime/render/rhi/vulkan/VulkanCommandList.cpp)。

相对 UE，MoerEngine 的优势是 RHI 规模更小，研究者能追踪一个资源从创建、Bindless 分配、状态转换到 Dispatch 的全过程。UE 的 RHI/RDG 则胜在多平台、验证层、异步调度、资源别名、并行录制和多年生产验证。

必须特别说明：MoerEngine 的 `rendergraph` 目录当前不能列为成熟优势。多个 `.cpp` 主体被整体注释，Ray Tracing Pass 仍为 TODO，当前 Raster 路径主要依赖显式顺序和 RHI 命令系统。它与 UE RDG 存在显著差距。

### 3.5 Shader Mutation、运行时 DXC 和共享 CPU/GPU ABI

成熟度：**B**

MoerEngine Shader 系统支持：

- HLSL 统一源码；
- DXC 编译到目标 Shader 平台；
- Mutation/Permutation；
- Shader 参数反射；
- C++ 与 HLSL 共用结构头；
- Include 依赖跟踪；
- 编译结果哈希和磁盘缓存；
- Raster、Compute、Ray Tracing Pipeline 构造器。

关键证据：

- [`ShaderManager.cpp`](../source/runtime/render/shader/ShaderManager.cpp)；
- [`DirectXShaderCompiler.cpp`](../source/runtime/render/shader/DXC/DirectXShaderCompiler.cpp)；
- [`ShaderMutation.h`](../source/runtime/render/shader/ShaderMutation.h)；
- [`shaderheaders/shared`](../source/runtime/render/shaderheaders/shared)；
- [`Bindless.hlsl`](../shaders/core/common/Bindless.hlsl)。

优势在于增加一个研究 Pass 时，CPU 参数、Shader 变体和 Bindless 资源可以在较短路径内接通。我们此前将 Probe GI 注入体积雾，就是直接复用了共享 `LightingData` 和现有时域历史。

当前问题是冷编译成本仍高。DXC 直接编译复杂 Probe GI 调用时首次启动可达到分钟级，说明缓存预热、异步编译和变体控制仍需完善。

### 3.6 ECS、Logical/Cpu/Gpu Scene 分层和 Dirty 同步

成熟度：**B**

MoerEngine 使用 EnTT 表示逻辑场景，并将场景分成：

```text
LogicalScene：权威 ECS 数据与节点关系
     ↓ Dirty/Tag/同步规则
CpuScene：面向渲染的紧凑缓存和稳定索引
     ↓ 上传/局部更新
GpuScene：Buffer、Bindless Handle、BLAS/TLAS
```

外部写操作不应直接修改 Registry，而应通过 `Scene::Patch<T>()` 或结构化创建/销毁接口，让 Dirty Tag、派生数据、CPU Cache、GPU Buffer 和 RT Scene 同步规则集中维护。

这种设计适合渲染研究：逻辑对象与 GPU 数据结构解耦，既能保持 ECS 编辑灵活性，也能为 GPU 使用专门的紧凑布局。

当前限制是 API 仍在快速扩展，一部分 Public Registry 收敛、销毁/局部重建语义和复杂查询仍未完全完成。

### 3.7 GUI、Python、HTTP、WebSocket 与 MCP 的统一控制链

成熟度：**A/B**

这是 MoerEngine 最容易被低估的差异化特点。当前控制链不是几套互不相干的 Demo，而是：

```text
GUI / Python / HTTP / MCP
  -> ScriptExecutionRequest
  -> ScriptHost Worker
  -> Python Runtime + Session Registry
  -> MainThreadCommandQueue
  -> Scene API
  -> Dirty Sync
  -> CpuScene / GpuScene / Renderer
```

已经存在：

- SharedGlobal、NamedSession、Stateless 三种脚本上下文；
- 嵌入式 Python 3.12 与 pybind11 Scene API；
- Scene 操作回主线程执行，避免脚本线程直接破坏渲染状态；
- HTTP 状态、脚本执行和 Request 查询；
- WebSocket 完成/失败事件广播；
- MCP 的 `engine_ping`、`python_execute`、`scene_summary`、`scene_query`；
- 创建、删除、导入、层级修改、Transform 和点光源等场景操作；
- 已记录的真实 MCP 场景创建、移动与查询验证。

关键证据：

- [`runtime/scripting/README.md`](../source/runtime/scripting/README.md)；
- [`runtime/remote/README.md`](../source/runtime/remote/README.md)；
- [`tools/mcp/README.md`](../tools/mcp/README.md)；
- [`ScriptingModule.cpp`](../source/runtime/scripting/ScriptingModule.cpp)；
- [`server.py`](../tools/mcp/server.py)。

UE 同样具有 Python Editor Script 和 Remote Control API，而且 UObject/Blueprint 生态远比 MoerEngine 完整。MoerEngine 的相对优势是链路短、场景修改语义统一，并且 MCP 已作为仓库内一等工具存在，适合做“智能体自动布景—修改参数—运行渲染—读取状态—形成实验记录”的闭环。

当前限制：

- Remote `ExecuteAndWait` 是阻塞模型；
- 没有可靠的长任务 Cancel 和 stdout/stderr Streaming；
- WebSocket 目前主要下发事件，不是完整双向命令协议；
- Scene Query 仍以定点查询为主，不是通用 DSL；
- 长时间动画控制尚未稳定验证。

### 3.8 CUDA、TensorRT 与 Cooperative Ops

成熟度：**C/D**

MoerEngine 有直接的 CUDA/Vulkan 外部内存和信号量互操作，并提供 TensorRT/ONNX Pass。这种“直接把神经推理插入 Raster 后处理”的路径适合原型实验。

不过当前 CUDA Pass 仍调用测试 Kernel；Cooperative Vector 在 HLSL → DXC → SPIR-V 路径上被明确标记为 parked，仅完成能力枚举和 Host 侧布局转换，不能作为已完成的神经 Shader 优势。

UE 5.8 的 NNE 已提供多 Runtime 的统一 API、神经降噪和神经后处理等产品化入口。因此这一项目前只能算 MoerEngine 的扩展潜力，不是相对 UE 的现成优势。

## 4. 与 Unreal Engine 5.8 的逐项对比

| 维度 | MoerEngine | Unreal Engine 5.8 | 结论 |
|---|---|---|---|
| 定位 | 现代实时渲染研究引擎 | 商业级通用实时 3D 引擎 | 两者目标不同 |
| 几何系统 | Cluster DAG LOD、GPU Culling、Vertex Pulling；仍为实验规模 | Nanite 自动层次 Cluster、压缩、按需 Streaming、专用渲染路径 | UE 产品能力大幅领先；Moer 更适合改算法 |
| 动态 GI | 稀疏层次 Ray Query Probe GI，可直接修改调度和页表 | Lumen 软件/硬件追踪、Surface Cache、Radiance Cache、无限漫反射反弹 | UE 质量和适用范围领先；Moer 可解释性更强 |
| 光追照明 | ReSTIR DI 明确暴露 Initial/Temporal/Spatial/Shading | Lumen、硬件 RT 和生产级 Path Tracer | UE 完整度领先；Moer 更适合 ReSTIR 研究 |
| 体积雾 | Froxel、CSM、时域、深度保边、动态 Probe GI；功能仍有限 | 灯光、局部体积、材质、粒子、VLM/Lumen、平台分级成熟 | UE 完整度领先；Moer 可研究跨系统耦合 |
| RHI | Vulkan 主路径、D3D12 部分支持、Bindless、命令依赖分析 | D3D11/12、Vulkan、Metal、主机平台和成熟 RHI | UE 平台和稳定性领先；Moer 更容易读懂 |
| Render Graph | 现有骨架未激活 | RDG 覆盖 Deferred/Mobile，支持异步 Compute、Transient Aliasing、并行录制、验证和 Insights | Moer 存在明显基础设施缺口 |
| Shader | Runtime DXC、Mutation、共享头、缓存；冷编译偏慢 | 大型成熟 Permutation、Shader Compile Worker、平台 Cook/Cache | UE 工程能力领先；Moer 迭代路径更短 |
| 时域抗锯齿 | FXAA/SMAA/TAA，体积雾自有时域 | TSR 含复杂拒绝、历史恢复、动态分辨率和平台优化 | UE 显著领先 |
| 场景数据 | EnTT + Logical/Cpu/Gpu Scene + Dirty Tag | UObject/Actor/Component、World Partition、资产系统 | UE 生态领先；Moer 数据流更直接 |
| 自动化 | Python Worker、HTTP、WS、MCP 共享 Scene API | Python Editor Plugin、Blueprint、Remote Control API、Commandlet | UE API 广度领先；Moer MCP 原生组合更轻 |
| 神经推理 | CUDA/TensorRT 直连，Cooperative 路径未完成 | NNE 多 Runtime、神经后处理和降噪 | UE 更成熟；Moer 适合底层互操作实验 |
| 开源与改造 | Apache-2.0，仓库规模小，可直接改核心路径 | 提供完整 C++ 源码访问，但使用和分发受 Epic EULA 管理 | 学术原型中 Moer 的公开复现与分发约束更少 |
| 生产能力 | 早期、平台与内容工具有限 | 大型游戏、影视、虚拟制作完整生态 | UE 全面领先 |

## 5. MoerEngine 相对 UE 真正成立的优势

### 5.1 核心数据流可被一个研究者完整掌握

在 MoerEngine 中，可以沿着下面的路径完整追踪一次修改：

```text
ECS Component
 -> Dirty Tag
 -> CpuScene 紧凑数据
 -> GpuScene Buffer / Bindless Handle
 -> Pass 参数
 -> HLSL
 -> RHI Command
 -> Vulkan Resource / Barrier
```

UE 的对应体系更强，但横跨 UObject、Renderer Module、RDG、RHI、Shader Parameter、资产 Cook 和多平台分支，单个研究者理解和修改的成本高得多。

### 5.2 跨层改造半径小

在 MoerEngine 中，新的渲染想法通常只需要修改少数几个明确位置：配置、UI、共享参数、Pass 和 Shader。例如体积雾注入 Probe GI 没有新增一套光照缓存，而是直接复用现有 Probe Atlas、Bindless `LightingData` 和时域历史。

这使它适合两周到数月尺度的研究原型。UE 更适合使用现有成熟能力完成产品，而不是短时间重写核心算法。

### 5.3 研究变量比 UE 更容易隔离

Probe GI 将 Placement、Hierarchy、Streaming、Prefetch、Dirty、Scheduler、Rays、Visibility 和 Capacity 分别暴露。ReSTIR DI 也将 Initial、Temporal、Spatial、Shade 分开。研究中可以构造明确的消融实验，而不必把整个 GI 系统只当作开/关黑盒。

### 5.4 面向智能体的实验闭环更直接

MoerEngine 把 MCP 放在仓库内，并让它复用 Python、Remote 和 Scene API。后续可以扩展成：

1. 智能体创建或修改测试场景；
2. 修改渲染参数；
3. 固定相机和曝光；
4. 触发截图或 GPU Profile；
5. 查询 Scene/Probe/Streaming 状态；
6. 自动生成对照表和异常报告。

UE 能通过 Python、Commandlet 和 Remote Control 实现更强的生产自动化，但 MoerEngine 的统一链路更短，更适合把自动化本身作为研究对象。

### 5.5 光栅与光追算法共享场景数据

GpuScene 同时维护 Raster 所需的紧凑 Buffer 和 RT 所需的 BLAS/TLAS。Probe GI 使用 Ray Query 更新后又被 Raster Lighting 和体积雾消费；ReSTIR DI 使用同一场景光源与几何数据。这为混合渲染研究提供了自然入口。

### 5.6 许可和代码规模适合公开复现实验

MoerEngine 使用 Apache-2.0，算法修改可以随代码、Shader、配置和测试场景一起公开。对于课程项目、论文复现和教学，这通常比仅提供插件参数或二进制结果更有说服力。

## 6. 哪些说法不成立

为了避免报告和答辩夸大，以下表述不建议使用：

- “MoerEngine 的画质超过 UE”；
- “MoerEngine 的 Probe GI 比 Lumen 更先进”；
- “MoerEngine 已经实现类似 Nanite 的完整虚拟几何”；
- “MoerEngine 的 RenderGraph 比 UE RDG 更轻更快”；
- “MoerEngine 的 AI 渲染能力强于 UE NNE”；
- “MoerEngine 独创了 Bindless、ECS、ReSTIR 或 Cluster LOD”；
- “支持 D3D12”而不说明目前是部分支持；
- “MCP 可以稳定控制长时间动画”而不说明阻塞和 Cancel 缺口。

更准确的说法是：

> MoerEngine 选择了一组现代实时渲染技术，并以较小、开放、可追踪的实现将其组合成研究平台；它的优势是算法透明度和改造效率，而不是产品成熟度。

## 7. 对当前体积雾课题的意义

选择体积雾后，最普通的做法是复现 UE 的 Froxel、光照注入、积分和时域滤波。这样可以完成基本功能，但研究贡献有限。

利用 MoerEngine 特性，可以把课题提升为：

> **面向动态稀疏 Probe GI 的体积雾间接光注入与时空摊销方法。**

它能体现 MoerEngine 的三项优势：

1. 体积雾可以消费本帧 Ray Query 更新后的动态 Probe GI，而不是固定 Ambient；
2. 通过工作组共享，将一个 Probe 查询摊销给 `4×4×4` 共 64 个 Froxel；
3. 通过四面体方向轮换和体积雾历史重投影，在四帧内恢复方向平均，不新增体积缓存和 Dispatch。

这一贡献应该定位为“基于现有引擎架构的集成与优化”，而不是新的 GI 基础算法。它与 UE 对比时应重点测：

- 是否需要烘焙；
- 动态灯光和场景变化的响应速度；
- 彩色反弹和室内外过渡；
- 漏光、噪声和时域稳定性；
- Injection GPU 时间和显存；
- 关闭/开启 Probe GI 的消融结果。

## 8. 推荐的后续发展优先级

### P0：把已有优势变成可证明的数据

1. 建立固定场景、相机、曝光和硬件基准；
2. 对 Probe GI、ReSTIR DI、Cluster LOD 和体积雾记录 GPU Scope、P50/P95、显存和画质；
3. 保存所有配置和自动化脚本，形成可复现实验；
4. 给每项功能建立“关闭、基础、优化”三档消融。

### P1：补齐会限制研究的基础设施

1. 修复或重建可工作的 RenderGraph；
2. 增加异步 Shader 编译、预热和稳定磁盘缓存；
3. 给 Remote 增加非阻塞执行、流式输出和 Cancel；
4. 增加统一 GPU Counter/截图/参数导出接口；
5. 建立 CI 下的 Shader Compile 和场景 Smoke Test。

### P2：沿独特方向扩展

1. Probe GI：GPU 驱动 Streaming/Scheduler、更加鲁棒的 Visibility、动态响应评价；
2. Cluster：自顶向下 DAG Traversal、Cluster Streaming、Raster/RT 共用 LOD；
3. ReSTIR：GI、Emissive Sampling、Adaptive Candidate Budget；
4. Agent：自动场景生成、自动 A/B、自动异常检测和性能回归；
5. 体积：局部体积材质、点/聚光源、动态 GI、多次散射近似。

## 9. 最终评价

如果目标是制作商业游戏、影视项目或大规模内容，UE 5.8 的综合能力没有可比性，应该优先选择 UE。

如果目标是理解现代渲染系统、修改核心算法、完成可复现的研究原型，MoerEngine 反而有明显优势。它允许研究者直接操作 Probe 的虚拟页、物理容量、Streaming 和更新预算，直接修改 ReSTIR Reservoir，直接改变 Cluster LOD 决策，并通过 Python/HTTP/MCP 自动组织实验。这些事情在 UE 中不是做不到，而是理解成本、编译成本和跨模块改造成本高得多。

因此，对 MoerEngine 最准确的定位是：

> **一个以现代 GPU 技术为基础、强调渲染算法透明度、跨层可修改性和智能体自动化的开源研究引擎。**

## 10. 主要参考资料

### MoerEngine 一手资料

- [MoerEngine GitHub 仓库](https://github.com/NJUCG/MoerEngine)
- [`README.md`](../README.md)
- [`docs/DEVELOPMENT.md`](DEVELOPMENT.md)
- [`Scene API Design`](260428-SceneApiDesign.md)
- [`runtime/scripting`](../source/runtime/scripting/README.md)
- [`runtime/remote`](../source/runtime/remote/README.md)
- [`MCP Bridge`](../tools/mcp/README.md)
- [`Volumetric Fog Implementation Plan`](260714-VolumetricFogImplementationPlan.md)

### Unreal Engine 5.8 官方资料

- [Nanite Virtualized Geometry](https://dev.epicgames.com/documentation/en-us/unreal-engine/nanite-virtualized-geometry-in-unreal-engine)
- [Lumen Global Illumination and Reflections](https://dev.epicgames.com/documentation/en-us/unreal-engine/lumen-global-illumination-and-reflections-in-unreal-engine)
- [Render Dependency Graph](https://dev.epicgames.com/documentation/unreal-engine/render-dependency-graph-in-unreal-engine?lang=en-US)
- [Temporal Super Resolution](https://dev.epicgames.com/documentation/unreal-engine/temporal-super-resolution-in-unreal-engine)
- [Path Tracer](https://dev.epicgames.com/documentation/en-us/unreal-engine/path-tracer-in-unreal-engine)
- [Scripting the Unreal Editor Using Python](https://dev.epicgames.com/documentation/en-us/unreal-engine/scripting-the-unreal-editor-using-python)
- [Remote Control API HTTP Reference](https://dev.epicgames.com/documentation/en-us/unreal-engine/remote-control-api-http-reference-for-unreal-engine)
- [Neural Network Engine](https://dev.epicgames.com/documentation/unreal-engine/neural-network-engine-in-unreal-engine?lang=en-US)
- [Accessing Unreal Engine Source Code on GitHub](https://www.unrealengine.com/ue-on-github?lang=en-US)
- [Unreal Engine End User License Agreement](https://www.unrealengine.com/eula/unreal)
