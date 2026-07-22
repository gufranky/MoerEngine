#include "VolumetricFogPass.h"

#include "log/LogSystem.h"
#include "shader/ShaderResourceManager.h"

#include <algorithm>
#include <cmath>

namespace Moer::Render::Raster {

namespace {

float RadicalInverse(uint64 index, uint base) {
    float value = 0.0f;
    float inverse_base = 1.0f / static_cast<float>(base);
    float factor = inverse_base;
    while (index > 0u) {
        value += static_cast<float>(index % base) * factor;
        index /= base;
        factor *= inverse_base;
    }
    return value;
}

float3 BuildFroxelJitter(uint64 frame_index) {
    const uint64 sample_index = frame_index % 1024u + 1u;
    return float3(
        RadicalInverse(sample_index, 2u) - 0.5f,
        RadicalInverse(sample_index, 3u) - 0.5f,
        RadicalInverse(sample_index, 5u) - 0.5f
    );
}

} // namespace

VolumetricFogPass::VolumetricFogPass(RasterContext& context) {
    smoke_write_pipeline = context.manager.Compute<VolumetricFogSmokeWritePipeline>(
        "pipelines/raster/volumetric_fog/SmokeWrite.hlsl"
    );
    smoke_read_pipeline = context.manager.Compute<VolumetricFogSmokeReadPipeline>(
        "pipelines/raster/volumetric_fog/SmokeRead.hlsl"
    );
    inject_pipeline = context.manager.Compute<VolumetricFogInjectPipeline>(
        "pipelines/raster/volumetric_fog/InjectDensity.hlsl"
    );
    temporal_pipeline = context.manager.Compute<VolumetricFogTemporalPipeline>(
        "pipelines/raster/volumetric_fog/TemporalReprojection.hlsl"
    );
    integrate_pipeline = context.manager.Compute<VolumetricFogIntegratePipeline>(
        "pipelines/raster/volumetric_fog/IntegrateScattering.hlsl"
    );
    composite_pipeline = context.manager.Compute<VolumetricFogCompositePipeline>(
        "pipelines/raster/volumetric_fog/CompositeVolumetricFog.hlsl"
    );
    debug_pipeline = context.manager.Compute<VolumetricFogDebugPipeline>(
        "pipelines/raster/volumetric_fog/DebugVisualize.hlsl"
    );
    RecreateResources(context);
}

void VolumetricFogPass::RecreateResources(RasterContext& context) {
    const uint2 resolution = context.GetResolution();
    const uint  froxel_x   = std::max(1u, (resolution.x + k_froxel_tile_size - 1u) / k_froxel_tile_size);
    const uint  froxel_y   = std::max(1u, (resolution.y + k_froxel_tile_size - 1u) / k_froxel_tile_size);

    resource.froxel_size = uint3(froxel_x, froxel_y, k_froxel_depth);
    resource.medium_volume = context.device.CreateTexture(
        "VolumetricFog::MediumVolume",
        Extent3D(froxel_x, froxel_y, k_froxel_depth),
        PF_R16G16B16A16_SFLOAT,
        ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
    );
    resource.shadow_volume = context.device.CreateTexture(
        "VolumetricFog::ShadowVisibility",
        Extent3D(froxel_x, froxel_y, k_froxel_depth),
        PF_R16_SFLOAT,
        ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
    );
    resource.integrated_volume = context.device.CreateTexture(
        "VolumetricFog::IntegratedScattering",
        Extent3D(froxel_x, froxel_y, k_froxel_depth),
        PF_R16G16B16A16_SFLOAT,
        ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
    );
    for (uint history_index = 0u; history_index < resource.history_volume.size(); ++history_index) {
        resource.history_volume[history_index] = context.device.CreateTexture(
            std::format("VolumetricFog::TemporalHistory{}", history_index),
            Extent3D(froxel_x, froxel_y, k_froxel_depth),
            PF_R16G16B16A16_SFLOAT,
            ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
        );
    }
    resource.temporal_debug_slice = context.device.CreateTexture(
        "VolumetricFog::TemporalDebugSlice",
        Extent2D(froxel_x, froxel_y),
        PF_R16_SFLOAT,
        ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
    );
    debug_output = context.device.CreateTexture(
        "VolumetricFog::SmokeReadback",
        Extent3D(k_debug_size, k_debug_size, 1),
        PF_R16G16B16A16_SFLOAT,
        ETextureUsageFlags::SAMPLED | ETextureUsageFlags::UNORDERED_ACCESS
    );

    LOG_INFO(
        "[VolumetricFog] Created Froxel resources: {}x{}x{} (tile={}, medium=RGBA16F, shadow=R16F, "
        "integrated=RGBA16F, history=2xRGBA16F, froxel_memory={:.2f} MiB, "
        "owned_memory_with_half_res_debug={:.2f} MiB, composite_scratch=upsample_output).",
        froxel_x,
        froxel_y,
        k_froxel_depth,
        k_froxel_tile_size,
        static_cast<double>(froxel_x) * froxel_y * k_froxel_depth * 34.0 / (1024.0 * 1024.0),
        (static_cast<double>(froxel_x) * froxel_y * k_froxel_depth * 34.0 +
         static_cast<double>(froxel_x) * froxel_y * 2.0 +
         static_cast<double>(context.textures.volumetric_fog_debug.GetSize().x) *
             context.textures.volumetric_fog_debug.GetSize().y * 4.0) /
            (1024.0 * 1024.0)
    );

    temporal_history_valid = false;
    temporal_write_index = 0u;
}

void VolumetricFogPass::ProcessSmokeTest(RasterContext& context, const RasterConfig& config) {
    if (!config.volumetric_fog_smoke_test_enabled) {
        return;
    }

    const uint3 volume_size(
        resource.medium_volume->GetWidth(),
        resource.medium_volume->GetHeight(),
        resource.medium_volume->GetDepth()
    );

    context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Day1 Smoke Test");

    context.cmd_list.Compute(smoke_write_pipeline, resource.medium_volume->GetView())
        .Dispatch(
            uint3((volume_size.x + 3u) / 4u, (volume_size.y + 3u) / 4u, (volume_size.z + 3u) / 4u),
            "Volumetric Fog Smoke Write 3D"
        );

    context.cmd_list.Compute(smoke_read_pipeline, resource.medium_volume->GetView(), debug_output->GetView())
        .Dispatch(
            uint3((k_debug_size + 7u) / 8u, (k_debug_size + 7u) / 8u, 1u),
            "Volumetric Fog Smoke Sample 3D"
        );

    context.cmd_list.PopScopeWithTimeScope();
}

void VolumetricFogPass::Process(RasterContext& context, const RasterConfig& config, const Camera& camera) {
    if (!config.volumetric_fog_enabled) {
        if (day2_was_enabled) {
            LOG_INFO("[VolumetricFog][Day2] Base medium disabled.");
            day2_was_enabled = false;
        }
        temporal_history_valid = false;
        temporal_was_enabled = false;
        return;
    }

    const uint3 volume_size = resource.froxel_size;

    VolumetricFogInjectParam inject_param{};
    inject_param.clip2world          = Transpose(camera.GetViewProjectionMatrixInv());
    inject_param.world2view          = Transpose(camera.GetViewMatrix());
    inject_param.camera_position     = camera.GetPosition();
    inject_param.near_clip           = camera.GetNearClip();
    inject_param.albedo              = config.volumetric_fog_albedo;
    inject_param.far_clip            = camera.GetFarClip();
    inject_param.ambient_color       = config.volumetric_fog_ambient_color;
    inject_param.max_distance        = std::min(config.volumetric_fog_max_distance, camera.GetFarClip());
    inject_param.base_density        = config.volumetric_fog_base_density;
    inject_param.height_falloff      = config.volumetric_fog_height_falloff;
    inject_param.height_offset       = config.volumetric_fog_height_offset;
    inject_param.extinction_scale    = config.volumetric_fog_extinction_scale;
    inject_param.ambient_intensity   = config.volumetric_fog_ambient_intensity;
    inject_param.scattering_intensity = config.volumetric_fog_scattering_intensity;

    const entt::entity directional_light_entity = context.scene.GetMainDirectionalLightEntity();
    const bool has_directional_light =
        directional_light_entity != entt::null && context.scene.r().valid(directional_light_entity) &&
        context.scene.r().all_of<ecs::CLightDirectional>(directional_light_entity);
    if (has_directional_light) {
        const auto& directional_light =
            context.scene.r().get<ecs::CLightDirectional>(directional_light_entity);
        inject_param.directional_light_color     = directional_light.color;
        inject_param.directional_light_direction = Normalizef(directional_light.d_direction);
        inject_param.directional_intensity =
            directional_light.intensity * config.volumetric_fog_directional_intensity;
    } else {
        inject_param.directional_light_color     = float3(0.0f);
        inject_param.directional_light_direction = float3(0.0f, -1.0f, 0.0f);
        inject_param.directional_intensity       = 0.0f;
    }
    inject_param.phase_g = std::clamp(config.volumetric_fog_phase_g, -0.9f, 0.9f);

    const bool csm_mode = config.shadow_map_mode == EShadowMapMode::CSM ||
                          config.shadow_map_mode == EShadowMapMode::CSM_AUTO;
    inject_param.shadow_enabled =
        config.volumetric_fog_shadows_enabled && csm_mode && has_directional_light ? 1u : 0u;
    inject_param.shadow_pcf_radius = static_cast<uint>(
        std::clamp(config.volumetric_fog_shadow_pcf_radius, 0, 2)
    );
    inject_param.shadow_bias = std::max(config.volumetric_fog_shadow_bias, 0.0f);

    const float position_delta = Lengthf(camera.GetPosition() - previous_camera_position);
    const float front_alignment = std::clamp(Dotf(camera.GetFront(), previous_camera_front), -1.0f, 1.0f);
    const float reset_angle_radians = std::max(config.volumetric_fog_history_reset_angle, 0.0f)
        * 3.14159265358979323846f / 180.0f;
    const bool camera_cut = temporal_history_valid &&
        (position_delta > std::max(config.volumetric_fog_history_reset_distance, 0.0f) ||
         front_alignment < std::cos(reset_angle_radians));
    const bool projection_changed = temporal_history_valid &&
        (std::abs(camera.GetFov() - previous_fov) > 1.0e-4f ||
         std::abs(camera.GetNearClip() - previous_near_clip) > 1.0e-5f ||
         std::abs(camera.GetFarClip() - previous_far_clip) > 1.0e-3f ||
         std::abs(inject_param.max_distance - previous_max_distance) > 1.0e-3f);
    const float4 current_fog_state0(
        config.volumetric_fog_base_density,
        config.volumetric_fog_height_falloff,
        config.volumetric_fog_height_offset,
        config.volumetric_fog_extinction_scale
    );
    const float4 current_fog_state1(
        config.volumetric_fog_ambient_intensity,
        config.volumetric_fog_scattering_intensity,
        config.volumetric_fog_directional_intensity,
        inject_param.phase_g
    );
    const float4 current_fog_state2(config.volumetric_fog_albedo, inject_param.max_distance);
    const float4 current_fog_state3(config.volumetric_fog_ambient_color, inject_param.shadow_bias);
    const float4 current_fog_state4(
        static_cast<float>(inject_param.shadow_enabled),
        static_cast<float>(inject_param.shadow_pcf_radius),
        config.volumetric_fog_jitter_enabled ? 1.0f : 0.0f,
        0.0f
    );
    const bool fog_settings_changed = temporal_history_valid &&
        (SquaredLengthf(current_fog_state0 - previous_fog_state0) > 1.0e-10f ||
         SquaredLengthf(current_fog_state1 - previous_fog_state1) > 1.0e-10f ||
         SquaredLengthf(current_fog_state2 - previous_fog_state2) > 1.0e-10f ||
         SquaredLengthf(current_fog_state3 - previous_fog_state3) > 1.0e-10f ||
         SquaredLengthf(current_fog_state4 - previous_fog_state4) > 1.0e-10f);
    if (camera_cut || projection_changed || fog_settings_changed) {
        LOG_DEBUG(
            "[VolumetricFog][Day5] History reset: camera_cut={}, projection_changed={}, settings_changed={}.",
            camera_cut ? 1 : 0,
            projection_changed ? 1 : 0,
            fog_settings_changed ? 1 : 0
        );
        temporal_history_valid = false;
    }

    const float3 current_jitter =
        config.volumetric_fog_temporal_enabled && config.volumetric_fog_jitter_enabled
        ? BuildFroxelJitter(temporal_frame_index)
        : float3(0.0f);
    inject_param.jitter = current_jitter;

    VolumetricFogDebugParam debug_param{};
    debug_param.debug_mode       = static_cast<uint>(std::clamp(config.volumetric_fog_debug_mode, 0, 6));
    debug_param.debug_slice      = static_cast<uint>(std::clamp(
        config.volumetric_fog_debug_slice, 0, static_cast<int>(volume_size.z) - 1
    ));
    debug_param.extinction_scale = std::max(config.volumetric_fog_extinction_scale, 1.0e-5f);
    debug_param.exposure         = config.volumetric_fog_debug_exposure;
    debug_param.temporal_enabled = config.volumetric_fog_temporal_enabled ? 1u : 0u;

    context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Day3 Light Injection");
    context.cmd_list.Compute(
        inject_pipeline,
        inject_param,
        context.lighting_data_buffer.buf,
        resource.medium_volume->GetView(),
        resource.shadow_volume->GetView(),
        context.bdls
    )
        .Dispatch(
            uint3((volume_size.x + 3u) / 4u, (volume_size.y + 3u) / 4u, (volume_size.z + 3u) / 4u),
            "Volumetric Fog Inject Density Directional Light CSM"
        );
    context.cmd_list.PopScopeWithTimeScope();

    TextureView medium_for_integration = resource.medium_volume->GetView();
    if (config.volumetric_fog_temporal_enabled) {
        VolumetricFogTemporalParam temporal_param{};
        temporal_param.clip2world        = Transpose(camera.GetViewProjectionMatrixInv());
        temporal_param.world2view        = Transpose(camera.GetViewMatrix());
        temporal_param.world2prev_clip   = Transpose(previous_view_projection);
        temporal_param.prev_world2view   = Transpose(previous_view);
        temporal_param.camera_position   = camera.GetPosition();
        temporal_param.near_clip         = camera.GetNearClip();
        temporal_param.current_jitter    = current_jitter;
        temporal_param.far_clip          = camera.GetFarClip();
        temporal_param.previous_jitter   = previous_jitter;
        temporal_param.max_distance      = inject_param.max_distance;
        temporal_param.history_weight    = std::clamp(config.volumetric_fog_history_weight, 0.0f, 0.99f);
        temporal_param.motion_weight_scale = std::max(config.volumetric_fog_history_motion_scale, 0.0f);
        temporal_param.clamp_expansion   = std::max(config.volumetric_fog_history_clamp_expansion, 0.0f);
        temporal_param.history_valid     = temporal_history_valid ? 1u : 0u;
        temporal_param.debug_slice       = debug_param.debug_slice;

        const uint read_index = temporal_write_index ^ 1u;
        context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Day6 Temporal Reprojection Clamp");
        context.cmd_list.Compute(
            temporal_pipeline,
            temporal_param,
            resource.medium_volume->GetView(),
            resource.history_volume[read_index]->GetView(),
            resource.history_volume[temporal_write_index]->GetView(),
            resource.temporal_debug_slice->GetView()
        ).Dispatch(
            uint3((volume_size.x + 3u) / 4u, (volume_size.y + 3u) / 4u, (volume_size.z + 3u) / 4u),
            "Volumetric Fog Reproject And Blend History"
        );
        context.cmd_list.PopScopeWithTimeScope();

        medium_for_integration = resource.history_volume[temporal_write_index]->GetView();
        temporal_write_index ^= 1u;
        temporal_history_valid = true;

        if (!temporal_was_enabled) {
            LOG_INFO(
                "[VolumetricFog][Day6] Temporal reprojection active: history_weight={:.3f}, jitter={}, "
                "motion_response={:.3f}, clamp_expansion={:.3f}, reset_distance={:.2f}, "
                "reset_angle={:.1f} degrees.",
                temporal_param.history_weight,
                config.volumetric_fog_jitter_enabled ? 1 : 0,
                temporal_param.motion_weight_scale,
                temporal_param.clamp_expansion,
                config.volumetric_fog_history_reset_distance,
                config.volumetric_fog_history_reset_angle
            );
            temporal_was_enabled = true;
        }
    } else {
        temporal_history_valid = false;
        temporal_was_enabled = false;
    }

    VolumetricFogIntegrateParam integrate_param{};
    integrate_param.clip2world   = Transpose(camera.GetViewProjectionMatrixInv());
    integrate_param.world2view   = Transpose(camera.GetViewMatrix());
    integrate_param.camera_position = camera.GetPosition();
    integrate_param.near_clip    = camera.GetNearClip();
    integrate_param.far_clip     = camera.GetFarClip();
    integrate_param.max_distance = inject_param.max_distance;

    context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Day4 Beer-Lambert Integration");
    context.cmd_list.Compute(
        integrate_pipeline,
        integrate_param,
        medium_for_integration,
        resource.integrated_volume->GetView()
    ).Dispatch(
        uint3((volume_size.x + 7u) / 8u, (volume_size.y + 7u) / 8u, 1u),
        "Volumetric Fog Integrate Scattering Transmittance"
    );
    context.cmd_list.PopScopeWithTimeScope();

    previous_view_projection = camera.GetViewProjectionMatrix();
    previous_view = camera.GetViewMatrix();
    previous_camera_position = camera.GetPosition();
    previous_camera_front = camera.GetFront();
    previous_jitter = current_jitter;
    previous_fov = camera.GetFov();
    previous_near_clip = camera.GetNearClip();
    previous_far_clip = camera.GetFarClip();
    previous_max_distance = inject_param.max_distance;
    previous_fog_state0 = current_fog_state0;
    previous_fog_state1 = current_fog_state1;
    previous_fog_state2 = current_fog_state2;
    previous_fog_state3 = current_fog_state3;
    previous_fog_state4 = current_fog_state4;
    ++temporal_frame_index;

    const uint2 debug_size = context.textures.volumetric_fog_debug.GetSize();
    context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Debug Visualize");
    context.cmd_list.Compute(
        debug_pipeline,
        debug_param,
        resource.medium_volume->GetView(),
        resource.shadow_volume->GetView(),
        resource.integrated_volume->GetView(),
        resource.temporal_debug_slice->GetView(),
        context.textures.volumetric_fog_debug.tex
    ).Dispatch(
        uint3((debug_size.x + 7u) / 8u, (debug_size.y + 7u) / 8u, 1u),
        "Volumetric Fog Debug Z Slice"
    );
    context.cmd_list.PopScopeWithTimeScope();

    if (!day2_was_enabled) {
        LOG_INFO(
            "[VolumetricFog][Day3] Directional injection active: froxels={}x{}x{}, density={:.4f}, falloff={:.3f}, "
            "height={:.2f}, max_distance={:.1f}, phase_g={:.3f}, csm_shadows={}, pcf_radius={}, "
            "debug_mode={}, debug_slice={}.",
            volume_size.x,
            volume_size.y,
            volume_size.z,
            config.volumetric_fog_base_density,
            config.volumetric_fog_height_falloff,
            config.volumetric_fog_height_offset,
            inject_param.max_distance,
            inject_param.phase_g,
            inject_param.shadow_enabled,
            inject_param.shadow_pcf_radius,
            debug_param.debug_mode,
            debug_param.debug_slice
        );
        day2_was_enabled = true;
    }
}

TextureWithHandle VolumetricFogPass::Composite(
    RasterContext& context,
    const RasterConfig& config,
    const Camera& camera,
    TextureWithHandle input_image
) {
    if (!config.volumetric_fog_enabled) {
        day4_composite_was_enabled = false;
        return input_image;
    }

    VolumetricFogCompositeParam param{};
    param.near_clip         = camera.GetNearClip();
    param.far_clip          = camera.GetFarClip();
    param.max_distance      = std::min(config.volumetric_fog_max_distance, camera.GetFarClip());
    param.volume_depth      = resource.froxel_size.z;
    // upsample_output is otherwise unused at this point in the raster post-process chain.
    // Reusing it avoids another full-resolution RGBA16F allocation dedicated to fog.
    param.output_resolution = uint2(context.textures.upsample_output.GetSize());

    context.cmd_list.PushScopeWithTimeScope("Volumetric Fog Day6 Trilinear HDR Composite");
    context.cmd_list.Compute(
        composite_pipeline,
        param,
        input_image.tex,
        context.textures.depth_nearest_sampler.tex->GetView(),
        resource.integrated_volume->GetView(),
        context.textures.upsample_output.tex
    ).Dispatch(
        uint3((param.output_resolution.x + 7u) / 8u, (param.output_resolution.y + 7u) / 8u, 1u),
        "Volumetric Fog Depth-Aware HDR Composite"
    );
    context.cmd_list.PopScopeWithTimeScope();

    if (!day4_composite_was_enabled) {
        LOG_INFO(
            "[VolumetricFog][Day4] Beer-Lambert integration and depth-aware HDR composite active: "
            "output={}x{}, depth_slices={}, max_distance={:.1f}.",
            param.output_resolution.x,
            param.output_resolution.y,
            param.volume_depth,
            param.max_distance
        );
        day4_composite_was_enabled = true;
    }

    return context.textures.upsample_output;
}

} // namespace Moer::Render::Raster
