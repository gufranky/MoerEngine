#pragma once

#include "RasterConfig.h"
#include "RasterResource.h"
#include "RasterTool.h"
#include "scene/camera/Camera.h"
#include "shader/ShaderPipeline.h"
#include "shaderheaders/shared/raster/lighting_pass/ShaderParameters.h"

namespace Moer::Render::Raster {

class ProbeUpdatePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(ProbeUpdatePipeline);

    DEFINE_SHADER_BUFFER(rw_probe_data);
    DEFINE_SHADER_BUFFER(rw_visibility_atlas);
    DEFINE_SHADER_BUFFER(rw_irradiance_atlas);
    DEFINE_SHADER_BUFFER(probe_scene_data);
    DEFINE_SHADER_TEX(rw_visibility_atlas_texture);
    DEFINE_SHADER_TEX(rw_irradiance_atlas_texture);
    DEFINE_SHADER_BUFFER(probe_volume_data);
    DEFINE_SHADER_BUFFER(probe_brick_data);
    DEFINE_SHADER_BINDLESS_ARRAY(bdls);
    DEFINE_SHADER_CONSTANT_STRUCT(ProbeUpdateParam, param);
    DEFINE_SHADER_ARGS(
        rw_probe_data,
        rw_visibility_atlas,
        rw_irradiance_atlas,
        probe_scene_data,
        rw_visibility_atlas_texture,
        rw_irradiance_atlas_texture,
        probe_volume_data,
        probe_brick_data,
        bdls,
        param
    );
};

class ProbeUpdateRayQueryPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(ProbeUpdateRayQueryPipeline);

    DEFINE_SHADER_BUFFER(rw_probe_data);
    DEFINE_SHADER_BUFFER(rw_visibility_atlas);
    DEFINE_SHADER_BUFFER(rw_irradiance_atlas);
    DEFINE_SHADER_BUFFER(probe_scene_data);
    DEFINE_SHADER_TEX(rw_visibility_atlas_texture);
    DEFINE_SHADER_TEX(rw_irradiance_atlas_texture);
    DEFINE_SHADER_TLAS(tlas);
    DEFINE_SHADER_BUFFER(probe_volume_data);
    DEFINE_SHADER_BUFFER(probe_brick_data);
    DEFINE_SHADER_BINDLESS_ARRAY(bdls);
    DEFINE_SHADER_CONSTANT_STRUCT(ProbeUpdateParam, param);
    DEFINE_SHADER_ARGS(
        rw_probe_data,
        rw_visibility_atlas,
        rw_irradiance_atlas,
        probe_scene_data,
        rw_visibility_atlas_texture,
        rw_irradiance_atlas_texture,
        tlas,
        probe_volume_data,
        probe_brick_data,
        bdls,
        param
    );

    MUTATION_BOOL(PROBE_GI_USE_RAY_QUERY);
};

MUTATION_SET(ProbeUpdateRayQueryMacros, ProbeUpdateRayQueryPipeline::PROBE_GI_USE_RAY_QUERY);

class VolumetricRadianceCacheClearPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricRadianceCacheClearPipeline);
    DEFINE_SHADER_BUFFER(rw_radiance_cache);
    DEFINE_SHADER_ARGS(rw_radiance_cache);
};

class VolumetricRadianceCacheUpdatePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricRadianceCacheUpdatePipeline);
    DEFINE_SHADER_BUFFER(probe_data);
    DEFINE_SHADER_BUFFER(irradiance_atlas);
    DEFINE_SHADER_BUFFER(probe_brick_data);
    DEFINE_SHADER_BUFFER(history_radiance_cache);
    DEFINE_SHADER_BUFFER(rw_radiance_cache);
    DEFINE_SHADER_BINDLESS_ARRAY(bdls);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricRadianceCacheUpdateParam, param);
    DEFINE_SHADER_ARGS(
        probe_data,
        irradiance_atlas,
        probe_brick_data,
        history_radiance_cache,
        rw_radiance_cache,
        bdls,
        param
    );
};

class VolumetricRadianceCacheRayQueryUpdatePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricRadianceCacheRayQueryUpdatePipeline);
    DEFINE_SHADER_BUFFER(probe_data);
    DEFINE_SHADER_BUFFER(irradiance_atlas);
    DEFINE_SHADER_BUFFER(probe_brick_data);
    DEFINE_SHADER_BUFFER(history_radiance_cache);
    DEFINE_SHADER_BUFFER(rw_radiance_cache);
    DEFINE_SHADER_TLAS(tlas);
    DEFINE_SHADER_BINDLESS_ARRAY(bdls);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricRadianceCacheUpdateParam, param);
    DEFINE_SHADER_ARGS(
        probe_data,
        irradiance_atlas,
        probe_brick_data,
        history_radiance_cache,
        rw_radiance_cache,
        tlas,
        bdls,
        param
    );

    MUTATION_BOOL(VRC_USE_RAY_QUERY);
};

MUTATION_SET(
    VolumetricRadianceCacheRayQueryMacros,
    VolumetricRadianceCacheRayQueryUpdatePipeline::VRC_USE_RAY_QUERY
);

class VolumetricRadianceCacheCopyPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricRadianceCacheCopyPipeline);
    DEFINE_SHADER_BUFFER(source_cache);
    DEFINE_SHADER_BUFFER(destination_cache);
    DEFINE_SHADER_ARGS(source_cache, destination_cache);
};

class ProbeUpdatePass {
public:
    ProbeUpdatePass(RasterContext& context) {
        probe_update_pipeline =
            context.manager.Compute<ProbeUpdatePipeline>("pipelines/raster/deferred/lighting/ProbeUpdate.comp.hlsl");

        ProbeUpdateRayQueryMacros ray_query_macros{};
        ray_query_macros.SetMutation<ProbeUpdateRayQueryPipeline::PROBE_GI_USE_RAY_QUERY>(true);
        probe_update_ray_query_pipeline = context.manager.Compute<ProbeUpdateRayQueryPipeline>(
            "pipelines/raster/deferred/lighting/ProbeUpdate.comp.hlsl",
            ray_query_macros
        );
        volumetric_radiance_cache_clear_pipeline =
            context.manager.Compute<VolumetricRadianceCacheClearPipeline>(
                "pipelines/raster/volumetric_fog/ClearRadianceCache.hlsl"
            );
        volumetric_radiance_cache_update_pipeline =
            context.manager.Compute<VolumetricRadianceCacheUpdatePipeline>(
                "pipelines/raster/volumetric_fog/UpdateRadianceCache.hlsl"
            );
        VolumetricRadianceCacheRayQueryMacros volume_ray_query_macros{};
        volume_ray_query_macros.SetMutation<
            VolumetricRadianceCacheRayQueryUpdatePipeline::VRC_USE_RAY_QUERY>(true);
        volumetric_radiance_cache_ray_query_update_pipeline =
            context.manager.Compute<VolumetricRadianceCacheRayQueryUpdatePipeline>(
                "pipelines/raster/volumetric_fog/UpdateRadianceCache.hlsl",
                volume_ray_query_macros
            );
        volumetric_radiance_cache_copy_pipeline =
            context.manager.Compute<VolumetricRadianceCacheCopyPipeline>(
                "pipelines/raster/volumetric_fog/CopyRadianceCache.hlsl"
            );
    }

    void Process(
        RasterContext&     context,
        const RasterConfig& config,
        const Scene&        scene,
        const Camera&       camera,
        uint64              frame_index
    ) {
        ProbeVolumeResource::UpdateInfo update_info =
            context.probe_volume.PrepareUpdate(config, scene, camera.GetPosition(), frame_index);

        const bool update_volumetric_cache =
            config.volumetric_fog_enabled && config.volumetric_fog_probe_gi_enabled &&
            config.volumetric_fog_radiance_cache_enabled && config.probe_gi_enabled;
        if (!update_volumetric_cache) {
            volumetric_radiance_cache_initialized = false;
        }
        if (update_volumetric_cache && !volumetric_radiance_cache_initialized) {
            const uint3 clear_dispatch(
                (RASTER_PROBE_MAX_COUNT + RASTER_PROBE_UPDATE_GROUP_SIZE - 1u) /
                    RASTER_PROBE_UPDATE_GROUP_SIZE,
                1u,
                1u
            );
            context.cmd_list.Compute(
                volumetric_radiance_cache_clear_pipeline,
                context.probe_volume.GetVolumetricRadianceHistoryBufferView()
            ).Dispatch(clear_dispatch, "Volumetric Radiance Cache History Clear");
            context.cmd_list.Compute(
                volumetric_radiance_cache_clear_pipeline,
                context.probe_volume.GetVolumetricRadianceWriteBufferView()
            ).Dispatch(clear_dispatch, "Volumetric Radiance Cache Write Clear");
            volumetric_radiance_cache_initialized = true;
        }

        if (!update_info.enabled) {
            return;
        }

        context.probe_volume.UpdateSceneData(context.cmd_list, scene);

        if (update_info.job_count == 0 || update_info.scheduled_probe_count == 0) {
            return;
        }

        RaytracingSceneRef rt_scene = context.rt_scene();
        const bool rt_available = rt_scene && rt_scene->GetTlas();
        for (uint job_index = 0; job_index < update_info.job_count; ++job_index) {
            ProbeVolumeResource::UpdateJob& job = update_info.jobs[job_index];
            if (job.probe_count == 0) {
                continue;
            }

            job.param.probe_update_context.z = context.textures.cubemap_tex.hdl;

            const uint dispatch_count =
                (job.probe_count + RASTER_PROBE_UPDATE_GROUP_SIZE - 1u) / RASTER_PROBE_UPDATE_GROUP_SIZE;

            if (rt_available) {
                job.param.probe_trace_config.w = 1.0f;
                context.cmd_list
                    .Compute(
                        probe_update_ray_query_pipeline,
                        context.probe_volume.GetProbeBufferView(),
                        context.probe_volume.GetVisibilityAtlasBufferView(),
                        context.probe_volume.GetIrradianceAtlasBufferView(),
                        context.probe_volume.GetSceneDataBufferView(),
                        context.probe_volume.GetVisibilityAtlasTextureView(),
                        context.probe_volume.GetIrradianceAtlasTextureView(),
                        rt_scene->GetTlas(),
                        context.probe_volume.GetVolumeBufferView(),
                        context.probe_volume.GetBrickBufferView(),
                        context.bdls,
                        job.param
                    )
                    .Dispatch(uint3(dispatch_count, 1, 1), "Probe GI DDGI Resident Brick Ray Query Update Pass");
                continue;
            }

            job.param.probe_trace_config.w = 0.0f;
            context.cmd_list
                .Compute(
                    probe_update_pipeline,
                    context.probe_volume.GetProbeBufferView(),
                    context.probe_volume.GetVisibilityAtlasBufferView(),
                    context.probe_volume.GetIrradianceAtlasBufferView(),
                    context.probe_volume.GetSceneDataBufferView(),
                    context.probe_volume.GetVisibilityAtlasTextureView(),
                    context.probe_volume.GetIrradianceAtlasTextureView(),
                    context.probe_volume.GetVolumeBufferView(),
                    context.probe_volume.GetBrickBufferView(),
                    context.bdls,
                    job.param
                )
                .Dispatch(uint3(dispatch_count, 1, 1), "Probe GI Fallback Resident Brick Update Pass");
        }

        if (update_volumetric_cache) {
            context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Radiance Cache Update");
            context.cmd_list.Compute(
                volumetric_radiance_cache_copy_pipeline,
                context.probe_volume.GetVolumetricRadianceHistoryBufferView(),
                context.probe_volume.GetVolumetricRadianceWriteBufferView()
            ).Dispatch(
                uint3(
                    (RASTER_PROBE_MAX_COUNT + RASTER_PROBE_UPDATE_GROUP_SIZE - 1u) /
                        RASTER_PROBE_UPDATE_GROUP_SIZE,
                    1u,
                    1u
                ),
                "Volumetric Radiance Cache Preserve Sparse History"
            );
            for (uint job_index = 0; job_index < update_info.job_count; ++job_index) {
                ProbeVolumeResource::UpdateJob& job = update_info.jobs[job_index];
                if (job.probe_count == 0u) {
                    continue;
                }
                const uint dispatch_count =
                    (job.probe_count + RASTER_PROBE_UPDATE_GROUP_SIZE - 1u) /
                    RASTER_PROBE_UPDATE_GROUP_SIZE;
                UpdateVolumetricRadianceCache(
                    context,
                    config,
                    job,
                    dispatch_count,
                    frame_index,
                    rt_available ? rt_scene->GetTlas() : nullptr
                );
            }
            context.probe_volume.SwapVolumetricRadianceBuffers();
            context.cmd_list.PopScopeWithTimeScope();
            RasterTool::LogDebugEverySeconds(
                "[VolumetricFog][VRC] Adaptive sparse medium-transport update active.",
                3.0
            );
        }

        if (rt_available) {
            RasterTool::LogDebugEverySeconds(
                "[ProbeGI] DDGI ray-query resident-brick update active: ray_sequence=rotated_fibonacci, "
                "placement=history_iterative(16x3+verify).",
                3.0
            );
            return;
        }

        RasterTool::LogDebugEverySeconds("[ProbeGI] TLAS unavailable, using fallback resident-brick update.", 3.0);
    }

private:
    void UpdateVolumetricRadianceCache(
        RasterContext& context,
        const RasterConfig& config,
        ProbeVolumeResource::UpdateJob& job,
        uint dispatch_count,
        uint64 frame_index,
        RaytracingTlasRef tlas
    ) {
        VolumetricRadianceCacheUpdateParam param{};
        param.probe = job.param;
        param.medium_global = float4(
            Max(config.volumetric_fog_base_density, 0.0f),
            Max(config.volumetric_fog_height_falloff, 0.0f),
            config.volumetric_fog_height_offset,
            Max(config.volumetric_fog_extinction_scale, 0.0f)
        );
        param.medium_local_center = float4(
            config.volumetric_fog_local_volume_center,
            Max(config.volumetric_fog_local_volume_radius, 0.01f)
        );
        param.medium_local_shape = float4(
            Max(config.volumetric_fog_local_volume_density, 0.0f),
            Max(config.volumetric_fog_local_volume_edge_falloff, 0.25f),
            Max(config.volumetric_fog_local_volume_height_falloff, 0.0f),
            config.volumetric_fog_local_volume_height_offset
        );
        param.medium_albedo = float4(
            Clamp(config.volumetric_fog_albedo, float3(0.0f), float3(1.0f)),
            Clamp(config.volumetric_fog_radiance_cache_multi_scatter, 0.0f, 0.5f)
        );
        param.cache_control = float4(
            Clamp(config.volumetric_fog_radiance_cache_history_weight, 0.0f, 0.98f),
            Max(config.volumetric_fog_max_distance, 0.1f),
            config.volumetric_fog_local_volume_enabled ? 1.0f : 0.0f,
            tlas ? 1.0f : 0.0f
        );
        param.cache_dispatch = uint4(
            static_cast<uint>(Clamp(
                config.volumetric_fog_radiance_cache_transmittance_steps,
                2,
                12
            )),
            static_cast<uint>(frame_index),
            0u,
            0u
        );

        if (tlas) {
            context.cmd_list.Compute(
                volumetric_radiance_cache_ray_query_update_pipeline,
                context.probe_volume.GetProbeBufferView(),
                context.probe_volume.GetIrradianceAtlasBufferView(),
                context.probe_volume.GetBrickBufferView(),
                context.probe_volume.GetVolumetricRadianceHistoryBufferView(),
                context.probe_volume.GetVolumetricRadianceWriteBufferView(),
                tlas,
                context.bdls,
                param
            ).Dispatch(
                uint3(dispatch_count, 1u, 1u),
                "Volumetric Radiance Cache Ray Query Medium Transport Update"
            );
            return;
        }

        context.cmd_list.Compute(
            volumetric_radiance_cache_update_pipeline,
            context.probe_volume.GetProbeBufferView(),
            context.probe_volume.GetIrradianceAtlasBufferView(),
            context.probe_volume.GetBrickBufferView(),
            context.probe_volume.GetVolumetricRadianceHistoryBufferView(),
            context.probe_volume.GetVolumetricRadianceWriteBufferView(),
            context.bdls,
            param
        ).Dispatch(
            uint3(dispatch_count, 1u, 1u),
            "Volumetric Radiance Cache Fallback Medium Transport Update"
        );
    }

    ProbeUpdatePipeline         probe_update_pipeline;
    ProbeUpdateRayQueryPipeline probe_update_ray_query_pipeline;
    VolumetricRadianceCacheClearPipeline volumetric_radiance_cache_clear_pipeline;
    VolumetricRadianceCacheUpdatePipeline volumetric_radiance_cache_update_pipeline;
    VolumetricRadianceCacheRayQueryUpdatePipeline volumetric_radiance_cache_ray_query_update_pipeline;
    VolumetricRadianceCacheCopyPipeline volumetric_radiance_cache_copy_pipeline;
    bool volumetric_radiance_cache_initialized = false;
};

} // namespace Moer::Render::Raster
