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
    float center_view_depth,
    out float2 fog_edge_gradient,
    out float fog_edge_confidence
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

    float4 sample_fog[4];
    float geometry_weights[4];
    float4 weighted_fog = 0.0;
    float total_weight = 0.0;
    [unroll]
    for (uint sample_index = 0u; sample_index < 4u; ++sample_index) {
        sample_fog[sample_index] = load_integrated_boundary(
            sample_coordinates[sample_index], boundary_position
        );
        geometry_weights[sample_index] = geometry_depth_weight(
            center_view_depth, sample_coordinates[sample_index], volume_dimensions
        );
        const float weight = bilinear_weights[sample_index] * geometry_weights[sample_index];
        weighted_fog += sample_fog[sample_index] * weight;
        total_weight += weight;
    }

    if (total_weight > 1.0e-5) {
        const float4 center_fog = weighted_fog / total_weight;
        const float center_feature =
            dot(max(center_fog.rgb, 0.0), float3(0.2126, 0.7152, 0.0722)) +
            (1.0 - saturate(center_fog.a));
        float features[4];
        [unroll]
        for (uint feature_index = 0u; feature_index < 4u; ++feature_index) {
            const float raw_feature =
                dot(max(sample_fog[feature_index].rgb, 0.0), float3(0.2126, 0.7152, 0.0722)) +
                (1.0 - saturate(sample_fog[feature_index].a));
            // Do not interpret a foreground/background depth discontinuity as a volumetric edge.
            features[feature_index] = lerp(
                center_feature,
                raw_feature,
                saturate(geometry_weights[feature_index] * 2.0)
            );
        }

        fog_edge_gradient = 0.5 * float2(
            (features[1] - features[0]) + (features[3] - features[2]),
            (features[2] - features[0]) + (features[3] - features[1])
        );
        const float feature_max = max(max(features[0], features[1]), max(features[2], features[3]));
        const float feature_min = min(min(features[0], features[1]), min(features[2], features[3]));
        fog_edge_confidence = saturate(
            (feature_max - feature_min) / max(abs(center_feature), 0.02) * 1.5
        );
        return center_fog;
    }

    // All four representatives can disagree at a very thin silhouette. Use the nearest column
    // instead of allowing background fog to bleed across the geometry edge.
    const uint2 nearest_xy = uint2(round(clamped_position));
    fog_edge_gradient = 0.0;
    fog_edge_confidence = 0.0;
    return load_integrated_boundary(nearest_xy, boundary_position);
}

float4 reconstruct_integrated_fog(
    float2 volume_position,
    float boundary_position,
    uint2 volume_dimensions,
    float center_view_depth
) {
    float2 edge_gradient;
    float edge_confidence;
    const float4 center = load_integrated_depth_aware(
        volume_position,
        boundary_position,
        volume_dimensions,
        center_view_depth,
        edge_gradient,
        edge_confidence
    );
    if (param.reconstruction_filter_enabled == 0u ||
        param.reconstruction_filter_strength <= 1.0e-4) {
        return center;
    }

    // Flat fog already reconstructs well with the four bilinear taps above. Only spend extra
    // samples at a real volumetric-lighting edge, and smooth along its tangent rather than
    // isotropically widening the light shaft across its normal.
    const float edge_blend = saturate(param.reconstruction_filter_strength) *
        smoothstep(0.03, 0.22, edge_confidence);
    if (edge_blend <= 1.0e-3) {
        return center;
    }

    const float gradient_length = max(length(edge_gradient), 1.0e-5);
    const float2 edge_normal = edge_gradient / gradient_length;
    const float2 edge_tangent = float2(-edge_normal.y, edge_normal.x);
    const float2 directional_offset = edge_tangent * 0.95;

    float2 unused_gradient;
    float unused_confidence;
    const float4 tangent_positive = load_integrated_depth_aware(
        volume_position + directional_offset,
        boundary_position,
        volume_dimensions,
        center_view_depth,
        unused_gradient,
        unused_confidence
    );
    const float4 tangent_negative = load_integrated_depth_aware(
        volume_position - directional_offset,
        boundary_position,
        volume_dimensions,
        center_view_depth,
        unused_gradient,
        unused_confidence
    );
    const float4 filtered = center * 0.5 +
        (tangent_positive + tangent_negative) * 0.25;

    return lerp(center, filtered, edge_blend);
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
    const float4 fog = reconstruct_integrated_fog(
        volume_position,
        boundary_position,
        uint2(volume_width, volume_height),
        target_view_depth
    );
    const float4 color = scene_color.Load(int3(pixel, 0));

    output_texture[pixel] = float4(color.rgb * saturate(fog.a) + max(fog.rgb, 0.0), color.a);
}
