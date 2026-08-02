// Independent scalar history for the stochastic volumetric CSM field.

#include "core/common/Common.hlsl"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogTemporalParam> param;
[[vk::binding(0, 0)]] Texture3D<float> current_shadow_volume;
[[vk::binding(1, 0)]] Texture3D<float> history_shadow_volume;
[[vk::binding(2, 0)]] RWTexture3D<float> output_shadow_volume;
[[vk::binding(3, 0)]] SamplerState linear_sampler;

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

[numthreads(4, 4, 4)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    output_shadow_volume.GetDimensions(width, height, depth);
    const uint3 dimensions = uint3(width, height, depth);
    if (any(dispatch_thread_id >= dimensions)) {
        return;
    }

    const float current_visibility = current_shadow_volume.Load(
        int4(dispatch_thread_id, 0)
    );
    if (param.history_valid == 0 || param.history_weight <= 0.0) {
        output_shadow_volume[dispatch_thread_id] = current_visibility;
        return;
    }

    const float2 current_uv =
        (float2(dispatch_thread_id.xy) + 0.5) / float2(width, height);
    const float3 far_world = world_pos_from_depth(0.0, current_uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;
    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance = max(
        min(param.max_distance, param.far_clip), near_distance + 1.0e-3
    );
    const float slice_fraction =
        (float(dispatch_thread_id.z) + 0.5) / float(depth);
    const float view_depth = near_distance * pow(
        far_distance / near_distance, slice_fraction
    );
    const float ray_distance = view_depth / max(abs(ray_view.z), 1.0e-4);
    const float3 world_position = param.camera_position + ray_world * ray_distance;

    const float4 previous_clip = mul(
        param.world2prev_clip, float4(world_position, 1.0)
    );
    if (previous_clip.w <= 1.0e-5) {
        output_shadow_volume[dispatch_thread_id] = current_visibility;
        return;
    }

    const float3 previous_ndc = previous_clip.xyz / previous_clip.w;
    const float2 previous_uv = float2(
        previous_ndc.x * 0.5 + 0.5,
        1.0 - (previous_ndc.y * 0.5 + 0.5)
    );
    const float previous_view_depth = abs(
        mul(param.prev_world2view, float4(world_position, 1.0)).z
    );
    const float previous_slice_fraction =
        log(max(previous_view_depth, near_distance) / near_distance) /
        log(far_distance / near_distance);
    const float3 previous_coordinate = float3(
        previous_uv * float2(width, height) - 0.5,
        previous_slice_fraction * float(depth) - 0.5
    );
    const bool history_inside =
        all(previous_uv >= 0.0) && all(previous_uv <= 1.0) &&
        previous_view_depth >= near_distance && previous_view_depth <= far_distance &&
        all(previous_coordinate >= 0.0) &&
        all(previous_coordinate <= float3(dimensions - 1u));
    if (!history_inside) {
        output_shadow_volume[dispatch_thread_id] = current_visibility;
        return;
    }

    // Hardware trilinear sampling replaces eight explicit history loads. Coordinates refer to
    // texel centers, hence the +0.5 conversion to normalized texture space.
    const float3 history_uvw =
        (previous_coordinate + 0.5) / float3(dimensions);
    const float history_visibility = history_shadow_volume.SampleLevel(
        linear_sampler, history_uvw, 0.0
    );

    // A four-tap stochastic PCF result is quantized to five visibility levels. Clamp only gross
    // disagreement, while retaining enough history to converge the rotated sample pattern.
    const float difference = abs(history_visibility - current_visibility);
    const float acceptance = 1.0 - smoothstep(0.35, 0.8, difference);
    const float shadow_history_weight = min(saturate(param.history_weight) + 0.02, 0.97) *
        lerp(0.35, 1.0, acceptance);
    output_shadow_volume[dispatch_thread_id] = saturate(lerp(
        current_visibility, history_visibility, shadow_history_weight
    ));
}
