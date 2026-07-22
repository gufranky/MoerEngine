// Day-4: analytically integrate incident scattering and Beer-Lambert transmittance
// from the near plane toward the far end of each view-aligned froxel column.

#include "core/common/Common.hlsl"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogIntegrateParam> param;
[[vk::binding(0, 0)]] Texture3D<float4>   medium_volume;
[[vk::binding(1, 0)]] RWTexture3D<float4> integrated_volume;

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

[numthreads(8, 8, 1)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    integrated_volume.GetDimensions(width, height, depth);
    if (any(dispatch_thread_id.xy >= uint2(width, height))) {
        return;
    }

    const float2 uv = (float2(dispatch_thread_id.xy) + 0.5) / float2(width, height);
    const float3 far_world = world_pos_from_depth(0.0, uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;
    const float inv_abs_ray_view_z = 1.0 / max(abs(ray_view.z), 1.0e-4);

    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance = max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float depth_ratio = far_distance / near_distance;

    float3 accumulated_scattering = 0.0;
    float accumulated_transmittance = 1.0;
    float previous_view_depth = near_distance;

    [loop]
    for (uint z = 0; z < depth; ++z) {
        const float boundary_fraction = float(z + 1u) / float(depth);
        const float current_view_depth = near_distance * pow(depth_ratio, boundary_fraction);
        const float segment_length = (current_view_depth - previous_view_depth) * inv_abs_ray_view_z;
        previous_view_depth = current_view_depth;

        const float4 medium = medium_volume.Load(int4(dispatch_thread_id.xy, z, 0));
        const float extinction = max(medium.a, 0.0);
        const float slice_transmittance = exp(-extinction * segment_length);
        const float scattering_integral = extinction > 1.0e-5
            ? (1.0 - slice_transmittance) / extinction
            : segment_length;

        accumulated_scattering +=
            accumulated_transmittance * max(medium.rgb, 0.0) * scattering_integral;
        accumulated_transmittance *= slice_transmittance;

        integrated_volume[uint3(dispatch_thread_id.xy, z)] =
            float4(accumulated_scattering, accumulated_transmittance);
    }
}
