// Evaluate a low-sample, temporally rotated CSM visibility field before medium injection.
// Keeping this signal in its own history lets us spend four shadow taps per froxel without
// exposing the rotating pattern as light-shaft shimmer.

#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogInjectParam> param;
[[vk::binding(0, 0)]] ConstantBuffer<Moer::LightingData> lighting_data;
[[vk::binding(1, 0)]] RWTexture3D<float> shadow_volume;
[[vk::binding(2, 0)]] Texture3D<float4> fast_noise_texture;

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

uint fog_hash(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    value ^= value >> 16u;
    return value;
}

float hash_to_unit_float(uint value) {
    return float(fog_hash(value) & 0x00ffffffu) * (1.0 / 16777216.0);
}

float rotation_noise(uint3 froxel_id) {
    uint noise_width;
    uint noise_height;
    uint noise_frames;
    fast_noise_texture.GetDimensions(noise_width, noise_height, noise_frames);
    if (param.jitter_mode == Moer::EVolumetricFogJitterMode::FAST_XY ||
        param.jitter_mode == Moer::EVolumetricFogJitterMode::FAST_XYZ_OFFSET) {
        const uint frame = param.jitter_frame_index % max(noise_frames, 1u);
        const uint2 coordinate = uint2(
            (froxel_id.x + froxel_id.z * 37u) % max(noise_width, 1u),
            (froxel_id.y + froxel_id.z * 17u) % max(noise_height, 1u)
        );
        return fast_noise_texture.Load(int4(coordinate, frame, 0)).r;
    }
    const uint seed = froxel_id.x + fog_hash(
        froxel_id.y + fog_hash(froxel_id.z + fog_hash(param.jitter_frame_index))
    );
    return hash_to_unit_float(seed);
}

int get_cascade_index(float3 world_position) {
    const float view_z = abs(mul(lighting_data.world2view, float4(world_position, 1.0)).z);
    const float depth_ratio = (view_z - lighting_data.near_clip) /
        max(lighting_data.far_clip - lighting_data.near_clip, 1.0e-4);
    [unroll]
    for (int cascade_index = 0; cascade_index < 4; ++cascade_index) {
        if (cascade_index >= int(lighting_data.shadow_csm_num_of_cascades)) {
            break;
        }
        if (depth_ratio < lighting_data.cascade_split_ratios[cascade_index]) {
            return cascade_index;
        }
    }
    return -1;
}

float compare_shadow(uint shadow_handle, float2 uv, float receiver_depth) {
    const float occluder_depth = TextureHandle(shadow_handle).SampleLevel<float>(uv, 0.0);
    // CSM uses reversed Z: a larger stored depth is closer to the light.
    return occluder_depth > receiver_depth + param.shadow_bias ? 0.0 : 1.0;
}

float sample_csm_visibility(float3 world_position, uint3 froxel_id) {
    if (param.shadow_enabled == 0 || lighting_data.shadow_csm_num_of_cascades == 0) {
        return 1.0;
    }

    const int cascade_index = get_cascade_index(world_position);
    if (cascade_index < 0) {
        return 1.0;
    }

    const float4 shadow_clip = mul(
        lighting_data.world2shadow_clip[cascade_index], float4(world_position, 1.0)
    );
    const float3 shadow_ndc = shadow_clip.xyz / shadow_clip.w;
    const float2 shadow_uv = float2(
        shadow_ndc.x * 0.5 + 0.5, 1.0 - (shadow_ndc.y * 0.5 + 0.5)
    );
    if (any(shadow_uv < 0.0) || any(shadow_uv > 1.0) ||
        shadow_ndc.z < 0.0 || shadow_ndc.z > 1.0) {
        return 1.0;
    }

    const uint shadow_handle = lighting_data.cascade_shadow_map[cascade_index];
    if (param.shadow_pcf_radius == 0u) {
        return compare_shadow(shadow_handle, shadow_uv, shadow_ndc.z);
    }

    // Four stratified Poisson taps replace the old 3x3/5x5 square kernel. A per-froxel,
    // per-frame rotation turns spatial undersampling into zero-mean temporal noise, which the
    // independent scalar history pass resolves before lighting injection.
    static const float2 poisson[4] = {
        float2(-0.613392, 0.617481),
        float2(0.170019, -0.040254),
        float2(-0.299417, -0.791925),
        float2(0.645680, 0.493210)
    };
    const float angle = rotation_noise(froxel_id) * (2.0 * PI);
    const float2 rotation = float2(cos(angle), sin(angle));
    const float filter_radius = float(max(param.shadow_pcf_radius, 1u));
    const float texel_size = 1.0 / max(float(lighting_data.shadow_csm_sm_size), 1.0);
    float visibility = 0.0;
    [unroll]
    for (uint sample_index = 0u; sample_index < 4u; ++sample_index) {
        const float2 offset = float2(
            poisson[sample_index].x * rotation.x - poisson[sample_index].y * rotation.y,
            poisson[sample_index].x * rotation.y + poisson[sample_index].y * rotation.x
        );
        visibility += compare_shadow(
            shadow_handle,
            shadow_uv + offset * filter_radius * texel_size,
            shadow_ndc.z
        );
    }
    return visibility * 0.25;
}

[numthreads(4, 4, 4)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    shadow_volume.GetDimensions(width, height, depth);
    const uint3 volume_size = uint3(width, height, depth);
    if (any(dispatch_thread_id >= volume_size)) {
        return;
    }

    const float2 uv = (float2(dispatch_thread_id.xy) + 0.5) / float2(volume_size.xy);
    const float3 far_world = world_pos_from_depth(0.0, uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;
    const float slice_fraction = (float(dispatch_thread_id.z) + 0.5) / float(volume_size.z);
    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance = max(
        min(param.max_distance, param.far_clip), near_distance + 1.0e-3
    );
    const float view_depth = near_distance * pow(far_distance / near_distance, slice_fraction);
    const float ray_distance = view_depth / max(abs(ray_view.z), 1.0e-4);
    const float3 world_position = param.camera_position + ray_world * ray_distance;
    shadow_volume[dispatch_thread_id] = sample_csm_visibility(
        world_position, dispatch_thread_id
    );
}
