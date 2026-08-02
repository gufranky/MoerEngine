#include "RasterTool.h"

#include "RasterConfig.h"
#include "log/LogSystem.h"
#include "misc/Timer.h"
#include "rhi/RHI.h"
#include "rhi/RHICommand.h"
#include "scene/Scene.h"

#include <algorithm>
#include <cassert>
#include <source_location>
#include <span>
#include <sstream>

namespace Moer::Render::Raster {

namespace {
constexpr StaticArray<std::string_view, CSM_MAX_CASCADES> s_shadow_culling_scope_names = {
    "Raster Shadow Culling CSM0",
    "Raster Shadow Culling CSM1",
    "Raster Shadow Culling CSM2",
    "Raster Shadow Culling CSM3"
};

constexpr StaticArray<std::string_view, CSM_MAX_CASCADES> s_shadow_draw_scope_names = {
    "Raster Shadow Draw CSM0",
    "Raster Shadow Draw CSM1",
    "Raster Shadow Draw CSM2",
    "Raster Shadow Draw CSM3"
};

constexpr StaticArray<std::string_view, 7> s_volumetric_fog_scope_names = {
    "Volumetric Fog Rotated Low Sample CSM",
    "Volumetric Fog Independent Shadow History",
    "Volumetric Fog Light And Probe GI Injection",
    "Volumetric Fog Day6 Temporal Reprojection Clamp",
    "Volumetric Fog Day4 Beer-Lambert Integration",
    "Volumetric Fog Debug Visualize",
    "Volumetric Fog Low-Resolution Reconstruction Composite"
};
constexpr std::string_view s_volumetric_radiance_cache_scope_name =
    "Volumetric Fog Radiance Cache Update";

constexpr std::string_view s_rt_scene_build_blas_scope_name  = "RTScene BuildBLAS";
constexpr std::string_view s_rt_scene_build_tlas_scope_name  = "RTScene BuildTLAS";
constexpr std::string_view s_rt_scene_update_tlas_scope_name = "RTScene UpdateTLAS";

std::string BuildDebugLogSiteKey(std::source_location location) {
    std::ostringstream stream;
    stream << location.file_name() << ':' << location.line();
    return stream.str();
}

double FindGpuTime(const ProfileData& profile_data, std::string_view name) {
    for (const auto& entry : profile_data.gpu_entries) {
        if (entry.name == name) {
            return entry.time;
        }
    }
    return -1.0;
}

std::string_view GetVolumetricFogJitterModeName(uint8 mode) {
    switch (static_cast<EVolumetricFogJitterMode>(mode)) {
        case EVolumetricFogJitterMode::OFF: return "off";
        case EVolumetricFogJitterMode::HALTON: return "halton";
        case EVolumetricFogJitterMode::WHITE_NOISE: return "white_noise";
        case EVolumetricFogJitterMode::FAST_XY: return "fast_xy";
        case EVolumetricFogJitterMode::FAST_XYZ_OFFSET: return "fast_xyz_offset";
        default: return "unknown";
    }
}

void LogRtSceneProfiling(CommandQueue& gfx_queue) {
    const auto profile_data = gfx_queue.GetProfilerEntry();
    if (profile_data.gpu_entries.empty()) {
        return;
    }

    const double graphics_exec = FindGpuTime(profile_data, "Graphics Exec");
    const double build_blas    = FindGpuTime(profile_data, s_rt_scene_build_blas_scope_name);
    const double build_tlas    = FindGpuTime(profile_data, s_rt_scene_build_tlas_scope_name);
    const double update_tlas   = FindGpuTime(profile_data, s_rt_scene_update_tlas_scope_name);
    if (build_blas < 0.0 && build_tlas < 0.0 && update_tlas < 0.0) {
        return;
    }

    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(3);
    stream << "[RTSceneProfile] ScenePending GPU(ms)";
    if (graphics_exec >= 0.0) {
        stream << " GraphicsExec=" << graphics_exec;
    }
    if (build_blas >= 0.0) {
        stream << " BuildBLAS=" << build_blas;
    }
    if (build_tlas >= 0.0) {
        stream << " BuildTLAS=" << build_tlas;
    }
    if (update_tlas >= 0.0) {
        stream << " UpdateTLAS=" << update_tlas;
    }

    LOG_DEBUG("{}", stream.str());
}

} // namespace

// 返回屏幕空间全屏三角形绘制共用的 draw 参数。
Array<SingleDrawParam> RasterTool::GetFullScreenDrawDatas() {
    Array<SingleDrawParam> full_screen_draw_datas;
    full_screen_draw_datas.emplace_back(SingleDrawParam{3, 1, 0, 0, 0});
    return full_screen_draw_datas;
}

// 返回整个阴影深度阶段使用的 profiling scope 名称。
std::string_view RasterTool::GetShadowDepthPassProfileScopeName() {
    return "Raster ShadowDepthPass";
}

// 返回整个几何阶段使用的 profiling scope 名称。
std::string_view RasterTool::GetGeometryPassProfileScopeName() {
    return "Raster GeometryPass";
}

// 返回主相机视角几何剔除 dispatch 使用的 profiling scope 名称。
std::string_view RasterTool::GetGeometryCullingProfileScopeName() {
    return "Raster Geometry Culling";
}

// 返回几何阶段绘制提交使用的 profiling scope 名称。
std::string_view RasterTool::GetGeometryDrawProfileScopeName() {
    return "Raster Geometry Draw";
}

// 返回某个级联阴影视锥剔除 dispatch 使用的 profiling scope 名称。
std::string_view RasterTool::GetShadowCullingProfileScopeName(uint cascade_index) {
    assert(cascade_index < CSM_MAX_CASCADES);
    return s_shadow_culling_scope_names[cascade_index];
}

// 返回某个级联阴影绘制提交使用的 profiling scope 名称。
std::string_view RasterTool::GetShadowDrawProfileScopeName(uint cascade_index) {
    assert(cascade_index < CSM_MAX_CASCADES);
    return s_shadow_draw_scope_names[cascade_index];
}

void RasterTool::LogDebugEverySeconds(std::string_view str, double seconds, std::source_location location) {
    if (seconds <= 0.0) {
        LOG_DEBUG("{}", str);
        return;
    }

    static UnorderedMap<std::string, LoopedTimer> s_debug_log_timers;

    const std::string site_key = BuildDebugLogSiteKey(location);
    auto [timer_it, inserted]  = s_debug_log_timers.try_emplace(site_key, seconds, true);
    if (inserted || timer_it->second.Tick()) {
        LOG_DEBUG("{}", str);
    }
}

// 按固定时间间隔输出 raster GPU profiling 汇总，避免把 profiler 状态放进 renderer。
void RasterTool::TickAndLogProfiling(CommandQueue& gfx_queue, const RasterConfig& raster_config) {
    const auto profile_data = gfx_queue.GetProfilerEntry();
    if (profile_data.gpu_entries.empty()) {
        return;
    }

    auto find_gpu_time = [&profile_data](std::string_view name) -> double { return FindGpuTime(profile_data, name); };

    auto sum_gpu_times = [&find_gpu_time](std::span<const std::string_view> names) -> double {
        double total = 0.0;
        for (std::string_view name : names) {
            const double time = find_gpu_time(name);
            if (time >= 0.0) {
                total += time;
            }
        }
        return total;
    };

    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(3);

    const double graphics_exec      = find_gpu_time("Graphics Exec");
    const double shadow_culling_sum = sum_gpu_times(s_shadow_culling_scope_names);
    const double shadow_draw_sum    = sum_gpu_times(s_shadow_draw_scope_names);
    const double geometry_culling   = find_gpu_time(GetGeometryCullingProfileScopeName());
    const double geometry_draw      = find_gpu_time(GetGeometryDrawProfileScopeName());
    const double fog_shadow_csm     = std::max(find_gpu_time(s_volumetric_fog_scope_names[0]), 0.0);
    const double fog_shadow_temporal = std::max(find_gpu_time(s_volumetric_fog_scope_names[1]), 0.0);
    const double fog_injection      = std::max(find_gpu_time(s_volumetric_fog_scope_names[2]), 0.0);
    const double fog_temporal       = std::max(find_gpu_time(s_volumetric_fog_scope_names[3]), 0.0);
    const double fog_integration    = std::max(find_gpu_time(s_volumetric_fog_scope_names[4]), 0.0);
    const double fog_debug          = std::max(find_gpu_time(s_volumetric_fog_scope_names[5]), 0.0);
    const double fog_composite      = std::max(find_gpu_time(s_volumetric_fog_scope_names[6]), 0.0);
    const double fog_total          = sum_gpu_times(s_volumetric_fog_scope_names);
    const double fog_radiance_cache_raw = find_gpu_time(s_volumetric_radiance_cache_scope_name);
    const double fog_radiance_cache     = std::max(fog_radiance_cache_raw, 0.0);

    static uint radiance_cache_scope_missing_frames = 0u;
    if (raster_config.volumetric_fog_enabled &&
        raster_config.volumetric_fog_radiance_cache_enabled && fog_radiance_cache_raw < 0.0) {
        ++radiance_cache_scope_missing_frames;
        if (radiance_cache_scope_missing_frames == 10u) {
            std::ostringstream inventory;
            inventory << "[RasterProfile] Radiance-cache timing scope missing for 10 frames; available GPU scopes=";
            for (const auto& entry : profile_data.gpu_entries) {
                inventory << "['" << entry.name << "'] ";
            }
            LOG_DEBUG("{}", inventory.str());
        }
    } else {
        radiance_cache_scope_missing_frames = 0u;
    }

    stream << "[RasterProfile] GPU(ms)";
    if (graphics_exec >= 0.0) {
        stream << " GraphicsExec=" << graphics_exec;
    }
    if (shadow_culling_sum > 0.0) {
        stream << " ShadowCullSum=" << shadow_culling_sum;
    }
    if (shadow_draw_sum > 0.0) {
        stream << " ShadowDrawSum=" << shadow_draw_sum;
    }
    if (geometry_culling >= 0.0) {
        stream << " GeometryCull=" << geometry_culling;
    }
    if (geometry_draw >= 0.0) {
        stream << " GeometryDraw=" << geometry_draw;
    }

    stream << " FogShadowCSM=" << fog_shadow_csm
           << " FogShadowTemporal=" << fog_shadow_temporal
           << " FogInject=" << fog_injection
           << " FogTemporal=" << fog_temporal
           << " FogIntegrate=" << fog_integration
           << " FogDebug=" << fog_debug
           << " FogComposite=" << fog_composite
           << " FogTotal=" << fog_total
           << " FogRadianceCache=" << fog_radiance_cache;

    stream << " | FogConfig enabled=" << (raster_config.volumetric_fog_enabled ? 1 : 0)
           << " temporal=" << (raster_config.volumetric_fog_temporal_enabled ? 1 : 0)
           << " jitter=" << GetVolumetricFogJitterModeName(raster_config.volumetric_fog_jitter_mode)
           << " shadows=" << (raster_config.volumetric_fog_shadows_enabled ? 1 : 0)
           << " pcf=" << raster_config.volumetric_fog_shadow_pcf_radius
           << " reconstruction="
           << (raster_config.volumetric_fog_reconstruction_filter_enabled ? 1 : 0)
           << " reconstructionStrength="
           << raster_config.volumetric_fog_reconstruction_filter_strength
           << " probeGI="
           << (raster_config.volumetric_fog_probe_gi_enabled && raster_config.probe_gi_enabled ? 1 : 0)
           << " radianceCache="
           << (raster_config.volumetric_fog_radiance_cache_enabled ? 1 : 0)
           << " local=" << (raster_config.volumetric_fog_local_volume_enabled ? 1 : 0);

    const auto& culling_stats = raster_config.culling_stats;
    if (culling_stats.total_instances_before > 0) {
        stream << " | CullStats inst=" << culling_stats.total_instances_after << "/"
               << culling_stats.total_instances_before << " draws=" << culling_stats.visible_draws << "/"
               << culling_stats.total_draws << " frustum=" << culling_stats.frustum_culled_instances
               << " occlusion=" << culling_stats.occlusion_culled_instances
               << " ratio=" << culling_stats.GetCullingRatio() * 100.0f << "%";
    }

    LogDebugEverySeconds(stream.str(), 1.0);
}

// 执行 Scene 同步阶段积累的 copy/gfx command list。
void RasterTool::ExecuteScenePendingCommands(Scene& scene, RenderDevice& device, CommandQueue& gfx_queue) {
    auto&& scene_cmd_list = scene.PopPendingCommandList();

    auto copy_evt = device.GetCopyQueue().Execute(scene_cmd_list.copy_queue_cmd_list.Submit());
    device.GetCopyQueue().Sync(copy_evt.timeline);

    gfx_queue.Execute(scene_cmd_list.gfx_queue_cmd_list.Submit().TickProfiling());
    gfx_queue.Sync();
    // LogRtSceneProfiling(gfx_queue);

    scene.ConsumePendingGpuSceneCommands();
}

} // namespace Moer::Render::Raster
