// Day-4: stop the integrated volume at opaque scene depth and composite it into HDR color.

#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogCompositeParam> param;
[[vk::binding(0, 0)]] Texture2D<float4>   scene_color;
[[vk::binding(1, 0)]] Texture2D<float>    scene_depth;
[[vk::binding(2, 0)]] Texture3D<float4>   integrated_volume;
[[vk::binding(3, 0)]] RWTexture2D<float4> output_texture;

float linearize_reverse_z(float depth) {
    return param.near_clip * param.far_clip /
        max(param.far_clip + (1.0 - depth) * (param.near_clip - param.far_clip), 1.0e-5);
}

float4 load_integrated_boundary(uint2 volume_xy, float boundary_position) {
    if (boundary_position <= 0.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float clamped_position = clamp(boundary_position, 0.0, float(param.volume_depth));
    const float lower_boundary = floor(clamped_position);
    const float upper_boundary = ceil(clamped_position);
    const float interpolation = frac(clamped_position);

    const float4 lower_value = lower_boundary <= 0.0
        ? float4(0.0, 0.0, 0.0, 1.0)
        : integrated_volume.Load(int4(volume_xy, uint(lower_boundary) - 1u, 0));
    const float4 upper_value = upper_boundary <= 0.0
        ? float4(0.0, 0.0, 0.0, 1.0)
        : integrated_volume.Load(int4(volume_xy, min(uint(upper_boundary) - 1u, param.volume_depth - 1u), 0));
    return lerp(lower_value, upper_value, interpolation);
}

float scene_view_depth_at(uint2 pixel) {
    const float raw_depth = scene_depth.Load(int3(pixel, 0));
    return raw_depth <= 1.0e-6 ? param.max_distance : linearize_reverse_z(raw_depth);
}

uint2 froxel_center_pixel(uint2 volume_xy, uint2 volume_dimensions) {
    const float2 pixel_position =
        (float2(volume_xy) + 0.5) * float2(param.output_resolution) /
        float2(volume_dimensions) - 0.5;
    return uint2(clamp(
        round(pixel_position), 0.0, float2(param.output_resolution - 1u)
    ));
}

float geometry_depth_weight(
    float center_view_depth,
    uint2 volume_xy,
    uint2 volume_dimensions
) {
    const float neighbor_view_depth = scene_view_depth_at(
        froxel_center_pixel(volume_xy, volume_dimensions)
    );

    // Keep interpolation smooth on the same plane, but reject columns whose representative
    // geometry belongs to another depth layer. The absolute floor prevents over-rejection near
    // the camera, while the relative term scales with perspective distance.
    const float depth_sigma = max(0.25, min(center_view_depth, neighbor_view_depth) * 0.04);
    return exp(-abs(neighbor_view_depth - center_view_depth) / depth_sigma);
}

float4 load_integrated_depth_aware(
    float2 volume_position,
    float boundary_position,
    uint2 volume_dimensions,
    float center_view_depth
) {
    const float2 clamped_position = clamp(
        volume_position, 0.0, float2(volume_dimensions - 1u)
    );
    const uint2 lower_xy = uint2(floor(clamped_position));
    const uint2 upper_xy = min(lower_xy + 1u, volume_dimensions - 1u);
    const float2 interpolation = frac(clamped_position);

    const uint2 sample_coordinates[4] = {
        lower_xy,
        uint2(upper_xy.x, lower_xy.y),
        uint2(lower_xy.x, upper_xy.y),
        upper_xy
    };
    const float bilinear_weights[4] = {
        (1.0 - interpolation.x) * (1.0 - interpolation.y),
        interpolation.x * (1.0 - interpolation.y),
        (1.0 - interpolation.x) * interpolation.y,
        interpolation.x * interpolation.y
    };

    float4 weighted_fog = 0.0;
    float total_weight = 0.0;
    [unroll]
    for (uint sample_index = 0u; sample_index < 4u; ++sample_index) {
        const float weight = bilinear_weights[sample_index] * geometry_depth_weight(
            center_view_depth, sample_coordinates[sample_index], volume_dimensions
        );
        weighted_fog += load_integrated_boundary(
            sample_coordinates[sample_index], boundary_position
        ) * weight;
        total_weight += weight;
    }

    if (total_weight > 1.0e-5) {
        return weighted_fog / total_weight;
    }

    // All four representatives can disagree at a very thin silhouette. Use the nearest column
    // instead of allowing background fog to bleed across the geometry edge.
    const uint2 nearest_xy = uint2(round(clamped_position));
    return load_integrated_boundary(nearest_xy, boundary_position);
}

[numthreads(8, 8, 1)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    if (any(dispatch_thread_id.xy >= param.output_resolution)) {
        return;
    }

    uint volume_width;
    uint volume_height;
    uint volume_depth;
    integrated_volume.GetDimensions(volume_width, volume_height, volume_depth);

    const uint2 pixel = dispatch_thread_id.xy;
    const float2 volume_position =
        (float2(pixel) + 0.5) * float2(volume_width, volume_height) /
        float2(param.output_resolution) - 0.5;

    const float scene_view_depth = scene_view_depth_at(pixel);
    const float target_view_depth = clamp(scene_view_depth, param.near_clip, param.max_distance);
    const float log_range = log(max(param.max_distance / max(param.near_clip, 1.0e-3), 1.0001));
    const float boundary_position =
        log(max(target_view_depth, param.near_clip) / max(param.near_clip, 1.0e-3)) / log_range
        * float(param.volume_depth);
    const float4 fog = load_integrated_depth_aware(
        volume_position,
        boundary_position,
        uint2(volume_width, volume_height),
        target_view_depth
    );
    const float4 color = scene_color.Load(int3(pixel, 0));

    output_texture[pixel] = float4(color.rgb * saturate(fog.a) + max(fog.rgb, 0.0), color.a);
}
