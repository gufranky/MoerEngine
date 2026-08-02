// Day-2 debug view: expose one froxel Z slice without requiring RenderDoc.

#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogDebugParam> param;
[[vk::binding(0, 0)]] Texture3D<float4>   volume_texture;
[[vk::binding(1, 0)]] Texture3D<float>    shadow_volume;
[[vk::binding(2, 0)]] Texture3D<float4>   integrated_volume;
[[vk::binding(3, 0)]] Texture2D<float>    temporal_debug_slice;
[[vk::binding(4, 0)]] Texture2D<float4>   radiance_cache_debug_slice;
[[vk::binding(5, 0)]] Texture2D<float4>   radiance_cache_meta_slice;
[[vk::binding(6, 0)]] RWTexture2D<float4> debug_output;

float3 heatmap(float value) {
    const float x = saturate(value);
    return saturate(float3(1.5 - abs(4.0 * x - 3.0), 1.5 - abs(4.0 * x - 2.0), 1.5 - abs(4.0 * x - 1.0)));
}

[numthreads(8, 8, 1)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint output_width;
    uint output_height;
    debug_output.GetDimensions(output_width, output_height);
    if (any(dispatch_thread_id.xy >= uint2(output_width, output_height))) {
        return;
    }

    uint volume_width;
    uint volume_height;
    uint volume_depth;
    volume_texture.GetDimensions(volume_width, volume_height, volume_depth);

    const uint2 source_xy = min(
        dispatch_thread_id.xy * uint2(volume_width, volume_height) / uint2(output_width, output_height),
        uint2(volume_width - 1, volume_height - 1)
    );
    const uint source_z = min(param.debug_slice, volume_depth - 1);
    const float4 medium = volume_texture.Load(int4(source_xy, source_z, 0));
    const float shadow_visibility = shadow_volume.Load(int4(source_xy, source_z, 0));
    const float4 integrated = integrated_volume.Load(int4(source_xy, source_z, 0));
    const float history_weight = param.temporal_enabled != 0
        ? temporal_debug_slice.Load(int3(source_xy, 0))
        : 0.0;
    const float4 cache_debug = radiance_cache_debug_slice.Load(int3(source_xy, 0));
    const float4 cache_meta = radiance_cache_meta_slice.Load(int3(source_xy, 0));

    float3 color;
    if (param.debug_mode == 11) {
        color = heatmap(1.0 - exp(-cache_meta.w * max(param.exposure, 0.0)));
    } else if (param.debug_mode == 10) {
        color = heatmap(cache_meta.z);
    } else if (param.debug_mode == 9) {
        color = heatmap(cache_meta.y);
    } else if (param.debug_mode == 8) {
        color = heatmap(cache_debug.a);
    } else if (param.debug_mode == 7) {
        color = 1.0 - exp(-max(cache_debug.rgb, 0.0) * max(param.exposure, 0.0));
    } else if (param.debug_mode == 6) {
        color = heatmap(history_weight);
    } else if (param.debug_mode == 5) {
        color = integrated.a.xxx;
    } else if (param.debug_mode == 4) {
        color = 1.0 - exp(-max(integrated.rgb, 0.0) * max(param.exposure, 0.0));
    } else if (param.debug_mode == 3) {
        color = shadow_visibility.xxx;
    } else if (param.debug_mode == 1) {
        const float density = medium.a / max(param.extinction_scale, 1.0e-5);
        color = 1.0 - exp(-density.xxx * max(param.exposure, 0.0));
    } else if (param.debug_mode == 2) {
        color = heatmap(1.0 - exp(-medium.a * max(param.exposure, 0.0)));
    } else {
        color = 1.0 - exp(-max(medium.rgb, 0.0) * max(param.exposure, 0.0));
    }

    debug_output[dispatch_thread_id.xy] = float4(color, 1.0);
}
