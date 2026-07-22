// Reproject the previous view-aligned froxel medium into the current grid and blend it with
// the jittered current-frame result. Day 7 uses a 7-tap axis cross for a lower-bandwidth clamp.

#include "core/common/Common.hlsl"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogTemporalParam> param;
[[vk::binding(0, 0)]] Texture3D<float4> current_volume;
[[vk::binding(1, 0)]] Texture3D<float4> history_volume;
[[vk::binding(2, 0)]] RWTexture3D<float4> output_volume;
[[vk::binding(3, 0)]] RWTexture2D<float> temporal_debug_slice;

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

float4 load_history_trilinear(float3 coordinate, uint3 dimensions) {
    const int3 base_coordinate = int3(floor(coordinate));
    const float3 fraction = frac(coordinate);
    const int3 max_coordinate = int3(dimensions) - 1;

    float4 result = 0.0;
    [unroll]
    for (int z = 0; z < 2; ++z) {
        [unroll]
        for (int y = 0; y < 2; ++y) {
            [unroll]
            for (int x = 0; x < 2; ++x) {
                const int3 offset = int3(x, y, z);
                const int3 sample_coordinate = clamp(base_coordinate + offset, int3(0, 0, 0), max_coordinate);
                const float weight =
                    (x == 0 ? 1.0 - fraction.x : fraction.x) *
                    (y == 0 ? 1.0 - fraction.y : fraction.y) *
                    (z == 0 ? 1.0 - fraction.z : fraction.z);
                result += history_volume.Load(int4(sample_coordinate, 0)) * weight;
            }
        }
    }
    return result;
}

void store_temporal_result(uint3 coordinate, float4 medium, float applied_history_weight) {
    output_volume[coordinate] = medium;
    if (coordinate.z == param.debug_slice) {
        temporal_debug_slice[coordinate.xy] = saturate(applied_history_weight);
    }
}

void current_neighborhood_bounds(
    uint3 coordinate,
    uint3 dimensions,
    out float4 neighborhood_min,
    out float4 neighborhood_max
) {
    neighborhood_min = current_volume.Load(int4(coordinate, 0));
    neighborhood_max = neighborhood_min;
    const int3 max_coordinate = int3(dimensions) - 1;
    static const int3 offsets[6] = {
        int3(-1, 0, 0), int3(1, 0, 0),
        int3(0, -1, 0), int3(0, 1, 0),
        int3(0, 0, -1), int3(0, 0, 1)
    };
    [unroll]
    for (uint sample_index = 0u; sample_index < 6u; ++sample_index) {
        const int3 sample_coordinate = clamp(
            int3(coordinate) + offsets[sample_index], int3(0, 0, 0), max_coordinate
        );
        const float4 sample_medium = current_volume.Load(int4(sample_coordinate, 0));
        neighborhood_min = min(neighborhood_min, sample_medium);
        neighborhood_max = max(neighborhood_max, sample_medium);
    }
}

[numthreads(4, 4, 4)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    output_volume.GetDimensions(width, height, depth);
    const uint3 dimensions = uint3(width, height, depth);
    if (any(dispatch_thread_id >= dimensions)) {
        return;
    }

    const float4 current_medium = current_volume.Load(int4(dispatch_thread_id, 0));
    if (param.history_valid == 0 || param.history_weight <= 0.0) {
        store_temporal_result(dispatch_thread_id, current_medium, 0.0);
        return;
    }

    const float2 current_uv =
        (float2(dispatch_thread_id.xy) + 0.5 + param.current_jitter.xy) / float2(width, height);
    const float3 far_world = world_pos_from_depth(0.0, current_uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;

    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance = max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float current_slice_fraction = saturate(
        (float(dispatch_thread_id.z) + 0.5 + param.current_jitter.z) / float(depth)
    );
    const float current_view_depth =
        near_distance * pow(far_distance / near_distance, current_slice_fraction);
    const float ray_distance = current_view_depth / max(abs(ray_view.z), 1.0e-4);
    const float3 world_position = param.camera_position + ray_world * ray_distance;

    const float4 previous_clip = mul(param.world2prev_clip, float4(world_position, 1.0));
    if (previous_clip.w <= 1.0e-5) {
        store_temporal_result(dispatch_thread_id, current_medium, 0.0);
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
        previous_uv * float2(width, height) - 0.5 - param.previous_jitter.xy,
        previous_slice_fraction * float(depth) - 0.5 - param.previous_jitter.z
    );
    const float3 max_coordinate = float3(dimensions - 1u);
    const bool history_inside =
        all(previous_uv >= 0.0) && all(previous_uv <= 1.0) &&
        previous_view_depth >= near_distance && previous_view_depth <= far_distance &&
        all(previous_coordinate >= 0.0) && all(previous_coordinate <= max_coordinate);
    if (!history_inside) {
        store_temporal_result(dispatch_thread_id, current_medium, 0.0);
        return;
    }

    float4 neighborhood_min;
    float4 neighborhood_max;
    current_neighborhood_bounds(
        dispatch_thread_id, dimensions, neighborhood_min, neighborhood_max
    );
    const float4 neighborhood_range = neighborhood_max - neighborhood_min;
    const float4 clamp_margin =
        neighborhood_range * max(param.clamp_expansion, 0.0) + 1.0e-5;
    const float4 history_medium = clamp(
        load_history_trilinear(previous_coordinate, dimensions),
        neighborhood_min - clamp_margin,
        neighborhood_max + clamp_margin
    );

    // Remove the expected Halton offset change so only actual camera/grid motion makes
    // the history more responsive.
    const float3 expected_jitter_motion = param.current_jitter - param.previous_jitter;
    const float3 reprojection_motion =
        previous_coordinate - float3(dispatch_thread_id) - expected_jitter_motion;
    const float applied_history_weight = saturate(param.history_weight) * exp(
        -length(reprojection_motion) * max(param.motion_weight_scale, 0.0)
    );
    const float4 temporal_medium = lerp(
        current_medium,
        max(history_medium, 0.0),
        applied_history_weight
    );
    store_temporal_result(dispatch_thread_id, temporal_medium, applied_history_weight);
}
