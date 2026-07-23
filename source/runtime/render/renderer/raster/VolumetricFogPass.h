#pragma once

#include "RasterConfig.h"
#include "RasterResource.h"
#include "scene/camera/Camera.h"
#include "shader/ShaderPipeline.h"
#include "shaderheaders/shared/raster/ShaderParameters.h"

namespace Moer::Render::Raster {

class VolumetricFogSmokeWritePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogSmokeWritePipeline);
    DEFINE_SHADER_TEX(volume_texture);
    DEFINE_SHADER_ARGS(volume_texture);
};

class VolumetricFogSmokeReadPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogSmokeReadPipeline);
    DEFINE_SHADER_TEX(volume_texture);
    DEFINE_SHADER_TEX(debug_output);
    DEFINE_SHADER_ARGS(volume_texture, debug_output);
};

class VolumetricFogInjectPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogInjectPipeline);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricFogInjectParam, param);
    DEFINE_SHADER_BUFFER(lighting_data);
    DEFINE_SHADER_TEX(volume_texture);
    DEFINE_SHADER_TEX(shadow_volume);
    DEFINE_SHADER_BINDLESS_ARRAY(bdls);
    DEFINE_SHADER_ARGS(param, lighting_data, volume_texture, shadow_volume, bdls);
};

class VolumetricFogDebugPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogDebugPipeline);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricFogDebugParam, param);
    DEFINE_SHADER_TEX(volume_texture);
    DEFINE_SHADER_TEX(shadow_volume);
    DEFINE_SHADER_TEX(integrated_volume);
    DEFINE_SHADER_TEX(temporal_debug_slice);
    DEFINE_SHADER_TEX(debug_output);
    DEFINE_SHADER_ARGS(
        param, volume_texture, shadow_volume, integrated_volume, temporal_debug_slice, debug_output
    );
};

class VolumetricFogIntegratePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogIntegratePipeline);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricFogIntegrateParam, param);
    DEFINE_SHADER_TEX(medium_volume);
    DEFINE_SHADER_TEX(integrated_volume);
    DEFINE_SHADER_ARGS(param, medium_volume, integrated_volume);
};

class VolumetricFogTemporalPipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogTemporalPipeline);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricFogTemporalParam, param);
    DEFINE_SHADER_TEX(current_volume);
    DEFINE_SHADER_TEX(history_volume);
    DEFINE_SHADER_TEX(output_volume);
    DEFINE_SHADER_TEX(temporal_debug_slice);
    DEFINE_SHADER_ARGS(param, current_volume, history_volume, output_volume, temporal_debug_slice);
};

class VolumetricFogCompositePipeline : public ComputePipeline {
public:
    DEFINE_COMPUTE_PIPELINE_CLASS(VolumetricFogCompositePipeline);
    DEFINE_SHADER_CONSTANT_STRUCT(VolumetricFogCompositeParam, param);
    DEFINE_SHADER_TEX(scene_color);
    DEFINE_SHADER_TEX(scene_depth);
    DEFINE_SHADER_TEX(integrated_volume);
    DEFINE_SHADER_TEX(output_texture);
    DEFINE_SHADER_ARGS(param, scene_color, scene_depth, integrated_volume, output_texture);
};

struct VolumetricFogResource {
    TextureRef medium_volume;
    TextureRef shadow_volume;
    TextureRef integrated_volume;
    StaticArray<TextureRef, 2> history_volume;
    TextureRef temporal_debug_slice;
    uint3      froxel_size = uint3(0u);
};

/**
 * Day-2 volumetric-fog foundation: view-aligned froxel reconstruction, exponential-height medium,
 * unshadowed ambient in-scattering and directly selectable debug slices.
 */
class VolumetricFogPass {
public:
    explicit VolumetricFogPass(RasterContext& context);

    void RecreateResources(RasterContext& context);
    void ProcessSmokeTest(RasterContext& context, const RasterConfig& config);
    void Process(RasterContext& context, const RasterConfig& config, const Camera& camera);
    TextureWithHandle Composite(
        RasterContext& context,
        const RasterConfig& config,
        const Camera& camera,
        TextureWithHandle input_image
    );

private:
    static constexpr uint k_froxel_tile_size = 12;
    static constexpr uint k_froxel_depth     = 64;
    static constexpr uint k_debug_size       = 16;

    VolumetricFogResource resource;
    TextureRef debug_output;

    VolumetricFogSmokeWritePipeline smoke_write_pipeline;
    VolumetricFogSmokeReadPipeline  smoke_read_pipeline;
    VolumetricFogInjectPipeline     inject_pipeline;
    VolumetricFogTemporalPipeline   temporal_pipeline;
    VolumetricFogIntegratePipeline  integrate_pipeline;
    VolumetricFogCompositePipeline  composite_pipeline;
    VolumetricFogDebugPipeline      debug_pipeline;

    bool day2_was_enabled = false;
    bool day4_composite_was_enabled = false;
    bool temporal_history_valid = false;
    bool temporal_was_enabled = false;
    uint temporal_write_index = 0;
    uint64 temporal_frame_index = 0;
    float3 previous_camera_position = float3(0.0f);
    float3 previous_camera_front = float3(0.0f, 0.0f, -1.0f);
    float3 previous_jitter = float3(0.0f);
    float previous_fov = 0.0f;
    float previous_near_clip = 0.0f;
    float previous_far_clip = 0.0f;
    float previous_max_distance = 0.0f;
    float4 previous_fog_state0 = float4(0.0f);
    float4 previous_fog_state1 = float4(0.0f);
    float4 previous_fog_state2 = float4(0.0f);
    float4 previous_fog_state3 = float4(0.0f);
    float4 previous_fog_state4 = float4(0.0f);
    float4 previous_fog_state5 = float4(0.0f);
    float4 previous_fog_state6 = float4(0.0f);
    float4 previous_fog_state7 = float4(0.0f);
    float4 previous_fog_state8 = float4(0.0f);
    float4 previous_fog_state9 = float4(0.0f);
    float4x4 previous_view_projection = float4x4::Identity();
    float4x4 previous_view = float4x4::Identity();
};

} // namespace Moer::Render::Raster
