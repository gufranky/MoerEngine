// Reproject the previous view-aligned froxel medium into the current grid and blend it with
// the jittered current-frame result. Day 7 uses a 7-tap axis cross for a lower-bandwidth clamp.

#include "core/common/Common.hlsl"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogTemporalParam> param;
[[vk::binding(0, 0)]] Texture3D<float4> current_volume;
[[vk::binding(1, 0)]] Texture3D<float4> history_volume;
[[vk::binding(2, 0)]] RWTexture3D<float4> output_volume;
[[vk::binding(3, 0)]] RWTexture2D<float> temporal_debug_slice;
[[vk::binding(4, 0)]] SamplerState linear_sampler;

// Cache the 4x4x4 center tile. Interior neighbors come from LDS; only the six workgroup faces
// fall back to texture loads. That reduces current-volume traffic from 448 to 160 reads per full
// workgroup while keeping LDS at 1 KiB and avoiding a 6x6x6 cooperative halo.
groupshared float4 group_current_medium[64];

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

float4 load_history_trilinear(float3 coordinate, uint3 dimensions) {
    // Texture coordinates address texel centers. One hardware trilinear sample replaces eight
    // explicit loads and their interpolation arithmetic.
    const float3 uvw = (coordinate + 0.5) / float3(dimensions);
    return history_volume.SampleLevel(linear_sampler, uvw, 0.0);
}

void store_temporal_result(uint3 coordinate, float4 medium, float applied_history_weight) {
    output_volume[coordinate] = medium;
    if (coordinate.z == param.debug_slice) {
        temporal_debug_slice[coordinate.xy] = saturate(applied_history_weight);
    }
}

uint shared_index(uint3 coordinate) {
    return coordinate.x + coordinate.y * 4u + coordinate.z * 16u;
}

void current_neighborhood_bounds(
    uint3 group_thread_id,
    uint3 dispatch_thread_id,
    uint3 dimensions,
    out float4 neighborhood_min,
    out float4 neighborhood_max
) {
    neighborhood_min = group_current_medium[shared_index(group_thread_id)];
    neighborhood_max = neighborhood_min;
    static const int3 offsets[6] = {
        int3(-1, 0, 0), int3(1, 0, 0),
        int3(0, -1, 0), int3(0, 1, 0),
        int3(0, 0, -1), int3(0, 0, 1)
    };
    const int3 max_coordinate = int3(dimensions) - 1;
    [unroll]
    for (uint sample_index = 0u; sample_index < 6u; ++sample_index) {
        const int3 local_coordinate = int3(group_thread_id) + offsets[sample_index];
        const bool inside_group = all(local_coordinate >= 0) && all(local_coordinate < 4);
        const int3 global_coordinate = clamp(
            int3(dispatch_thread_id) + offsets[sample_index],
            int3(0, 0, 0),
            max_coordinate
        );
        const float4 sample_medium = inside_group
            ? group_current_medium[shared_index(uint3(local_coordinate))]
            : current_volume.Load(int4(global_coordinate, 0));
        neighborhood_min = min(neighborhood_min, sample_medium);
        neighborhood_max = max(neighborhood_max, sample_medium);
    }
}

[numthreads(4, 4, 4)]
void main(
    uint3 dispatch_thread_id : SV_DispatchThreadID,
    uint3 group_thread_id : SV_GroupThreadID
) {
    uint width;
    uint height;
    uint depth;
    output_volume.GetDimensions(width, height, depth);
    const uint3 dimensions = uint3(width, height, depth);

    const int3 max_source_coordinate = int3(dimensions) - 1;
    const int3 source_coordinate = clamp(
        int3(dispatch_thread_id), int3(0, 0, 0), max_source_coordinate
    );
    group_current_medium[shared_index(group_thread_id)] = current_volume.Load(
        int4(source_coordinate, 0)
    );
    GroupMemoryBarrierWithGroupSync();

    if (any(dispatch_thread_id >= dimensions)) {
        return;
    }

    const float4 current_medium = group_current_medium[
        shared_index(group_thread_id)
    ];
    if (param.history_valid == 0 || param.history_weight <= 0.0) {
        store_temporal_result(dispatch_thread_id, current_medium, 0.0);
        return;
    }

    // The history texture is a cell-average estimate on a stable, unjittered froxel grid.
    // Jitter only chooses the current frame's stochastic injection sample inside that cell;
    // it must not move the accumulated history grid itself.
    const float2 current_uv =
        (float2(dispatch_thread_id.xy) + 0.5) / float2(width, height);
    const float3 far_world = world_pos_from_depth(0.0, current_uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;

    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance = max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float current_slice_fraction = saturate(
        (float(dispatch_thread_id.z) + 0.5) / float(depth)
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
        previous_uv * float2(width, height) - 0.5,
        previous_slice_fraction * float(depth) - 0.5
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
        group_thread_id,
        dispatch_thread_id,
        dimensions,
        neighborhood_min,
        neighborhood_max
    );
    const float4 neighborhood_range = neighborhood_max - neighborhood_min;
    const float4 clamp_margin =
        neighborhood_range * max(param.clamp_expansion, 0.0) + 1.0e-5;
    const float4 raw_history_medium = load_history_trilinear(
        previous_coordinate, dimensions
    );
    const float4 history_medium = clamp(
        raw_history_medium,
        neighborhood_min - clamp_margin,
        neighborhood_max + clamp_margin
    );

    // Jitter does not participate in history-grid motion. A static camera therefore maps an
    // accumulated cell exactly back to itself instead of resampling the whole history volume
    // by the Halton delta every frame.
    const float3 reprojection_motion =
        previous_coordinate - float3(dispatch_thread_id);
    // Stochastic froxel and shadow samples have the most visible variance at a high-contrast
    // lighting boundary. Do not throw their valid world-space history away just because the
    // camera moved across the froxel grid: that exposes a different jitter sample every frame
    // and presents as a shimmering edge. The neighborhood clamp above remains the guard against
    // stale history, while smooth regions keep the configured motion response.
    const float3 rgb_range = neighborhood_range.rgb;
    const float rgb_reference = max(
        max(max(neighborhood_max.r, neighborhood_max.g), neighborhood_max.b), 1.0e-3
    );
    const float normalized_rgb_range = max(max(rgb_range.r, rgb_range.g), rgb_range.b) /
        rgb_reference;
    const float normalized_extinction_range = neighborhood_range.a /
        max(neighborhood_max.a, 1.0e-3);
    const float edge_confidence = saturate(
        max(normalized_rgb_range, normalized_extinction_range) * 1.5
    );

    const float base_history_weight = saturate(param.history_weight);
    const float edge_history_weight = min(base_history_weight + 0.04, 0.98);
    const float motion_response = max(param.motion_weight_scale, 0.0) *
        lerp(1.0, 0.35, edge_confidence);
    const float history_rejection = max(
        max(
            abs(raw_history_medium.r - history_medium.r) /
                max(neighborhood_range.r, max(abs(current_medium.r) * 0.1, 1.0e-4)),
            abs(raw_history_medium.g - history_medium.g) /
                max(neighborhood_range.g, max(abs(current_medium.g) * 0.1, 1.0e-4))
        ),
        max(
            abs(raw_history_medium.b - history_medium.b) /
                max(neighborhood_range.b, max(abs(current_medium.b) * 0.1, 1.0e-4)),
            abs(raw_history_medium.a - history_medium.a) /
                max(neighborhood_range.a, max(abs(current_medium.a) * 0.1, 1.0e-4))
        )
    );
    const float reactive_mask = saturate((history_rejection - 0.05) * 1.5) *
        saturate(0.25 + length(reprojection_motion) * 0.75);
    const float history_acceptance = lerp(
        1.0,
        0.20,
        reactive_mask * saturate(param.reactive_strength)
    );
    const float applied_history_weight = lerp(
        base_history_weight,
        edge_history_weight,
        edge_confidence
    ) * exp(-length(reprojection_motion) * motion_response) * history_acceptance;
    const float4 temporal_medium = lerp(
        current_medium,
        max(history_medium, 0.0),
        applied_history_weight
    );
    store_temporal_result(dispatch_thread_id, temporal_medium, applied_history_weight);
}
