// Day-3: reconstruct a view-aligned froxel center, inject an exponential-height medium,
// and evaluate directional-light scattering through the engine's cascaded shadow maps.

#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogInjectParam> param;
[[vk::binding(0, 0)]] ConstantBuffer<Moer::LightingData> lighting_data;
[[vk::binding(1, 0)]] RWTexture3D<float4> volume_texture;
[[vk::binding(2, 0)]] RWTexture3D<float>  shadow_volume;

float3 world_pos_from_depth(float depth, float2 screen_uv, float4x4 clip2world) {
    const float4 clip = float4(screen_uv.x * 2.0 - 1.0, 1.0 - screen_uv.y * 2.0, depth, 1.0);
    const float4 world = mul(clip2world, clip);
    return world.xyz / world.w;
}

float henyey_greenstein(float cos_theta, float g) {
    const float g2 = g * g;
    const float denominator = max(1.0 + g2 - 2.0 * g * cos_theta, 1.0e-4);
    return (1.0 - g2) / (4.0 * PI * denominator * sqrt(denominator));
}

int get_cascade_index(float3 world_position) {
    const float view_z = abs(mul(lighting_data.world2view, float4(world_position, 1.0)).z);
    const float depth_ratio = (view_z - lighting_data.near_clip)
        / max(lighting_data.far_clip - lighting_data.near_clip, 1.0e-4);
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

float sample_csm_visibility(float3 world_position) {
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
    const float2 shadow_uv = float2(shadow_ndc.x * 0.5 + 0.5, 1.0 - (shadow_ndc.y * 0.5 + 0.5));
    if (any(shadow_uv < 0.0) || any(shadow_uv > 1.0) || shadow_ndc.z < 0.0 || shadow_ndc.z > 1.0) {
        return 1.0;
    }

    const uint shadow_handle = lighting_data.cascade_shadow_map[cascade_index];
    const float texel_size = 1.0 / max(float(lighting_data.shadow_csm_sm_size), 1.0);
    const int radius = min(int(param.shadow_pcf_radius), 2);
    float visibility = 0.0;
    float sample_count = 0.0;
    [loop]
    for (int y = -radius; y <= radius; ++y) {
        [loop]
        for (int x = -radius; x <= radius; ++x) {
            const float2 sample_uv = shadow_uv + float2(x, y) * texel_size;
            const float occluder_depth = TextureHandle(shadow_handle).SampleLevel<float>(sample_uv, 0.0);
            // CSM uses reversed Z: a larger stored depth is closer to the light.
            visibility += occluder_depth > shadow_ndc.z + param.shadow_bias ? 0.0 : 1.0;
            sample_count += 1.0;
        }
    }
    return visibility / max(sample_count, 1.0);
}

[numthreads(4, 4, 4)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    volume_texture.GetDimensions(width, height, depth);

    if (any(dispatch_thread_id >= uint3(width, height, depth))) {
        return;
    }

    const float2 uv =
        (float2(dispatch_thread_id.xy) + 0.5 + param.jitter.xy) / float2(width, height);

    // Moer uses reversed Z: device depth 0 is the far plane. The normalized ray is then
    // scaled so the exponentially distributed slice depth is measured along view-space Z,
    // matching a perspective frustum rather than a spherical shell around the camera.
    const float3 far_world = world_pos_from_depth(0.0, uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view  = mul(param.world2view, float4(ray_world, 0.0)).xyz;

    const float slice_fraction = saturate(
        (float(dispatch_thread_id.z) + 0.5 + param.jitter.z) / float(depth)
    );
    const float near_distance  = max(param.near_clip, 1.0e-3);
    const float far_distance   = max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float view_depth     = near_distance * pow(far_distance / near_distance, slice_fraction);
    const float ray_distance   = view_depth / max(abs(ray_view.z), 1.0e-4);
    const float3 world_position = param.camera_position + ray_world * ray_distance;

    // Density is specified at height_offset and decays upward. Clamp the exponent to keep
    // FP16 storage stable when the camera moves far below the reference height.
    const float height_exponent = clamp(
        -param.height_falloff * (world_position.y - param.height_offset), -16.0, 16.0
    );
    const float density    = min(max(param.base_density, 0.0) * exp(height_exponent), 64.0);
    const float extinction = density * max(param.extinction_scale, 0.0);

    const float3 scattering = extinction * saturate(param.albedo) * max(param.ambient_color, 0.0)
        * max(param.ambient_intensity, 0.0);

    const float visibility = sample_csm_visibility(world_position);
    const float cos_theta = dot(normalize(param.directional_light_direction), -ray_world);
    const float phase = henyey_greenstein(cos_theta, param.phase_g);
    const float3 directional_scattering = extinction * saturate(param.albedo)
        * max(param.directional_light_color, 0.0) * max(param.directional_intensity, 0.0)
        * phase * visibility;

    volume_texture[dispatch_thread_id] = float4(
        (scattering + directional_scattering) * max(param.scattering_intensity, 0.0), extinction
    );
    shadow_volume[dispatch_thread_id] = visibility;
}
