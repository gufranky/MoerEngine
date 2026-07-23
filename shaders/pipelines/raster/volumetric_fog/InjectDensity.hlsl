// Day-3: reconstruct a view-aligned froxel center, inject an exponential-height medium,
// and evaluate directional-light scattering through the engine's cascaded shadow maps.

#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "shared/raster/ShaderParameters.h"
#include "pipelines/raster/deferred/lighting/ProbeGI.hlsli"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricFogInjectParam> param;
[[vk::binding(0, 0)]] ConstantBuffer<Moer::LightingData> lighting_data;
[[vk::binding(1, 0)]] RWTexture3D<float4> volume_texture;
[[vk::binding(2, 0)]] RWTexture3D<float>  shadow_volume;

groupshared float3 group_probe_radiance;

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

float3 stable_world_position_from_froxel(uint3 froxel_id, uint3 volume_size) {
    const float2 uv = (float2(froxel_id.xy) + 0.5) / float2(volume_size.xy);
    const float3 far_world = world_pos_from_depth(0.0, uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view = mul(param.world2view, float4(ray_world, 0.0)).xyz;
    const float slice_fraction = (float(froxel_id.z) + 0.5) / float(volume_size.z);
    const float near_distance = max(param.near_clip, 1.0e-3);
    const float far_distance =
        max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float view_depth =
        near_distance * pow(far_distance / near_distance, slice_fraction);
    const float ray_distance = view_depth / max(abs(ray_view.z), 1.0e-4);
    return param.camera_position + ray_world * ray_distance;
}

float3 sample_group_probe_radiance(float3 world_position) {
    if (param.probe_gi_direction == 0 || !ProbeGIIsEnabled(lighting_data)) {
        return float3(0.0, 0.0, 0.0);
    }

    // Fog has no surface normal. Rotate one tetrahedral hemispherical irradiance direction per
    // frame and let the existing temporal reprojection reconstruct the direction average. This
    // avoids cloning the large adaptive Probe GI lookup graph four times in the compiled shader.
    static const float inv_sqrt3 = 0.57735026919;
    float3 basis = float3(inv_sqrt3, inv_sqrt3, inv_sqrt3);
    if (param.probe_gi_direction == 2u) {
        basis = float3(-inv_sqrt3, -inv_sqrt3, inv_sqrt3);
    } else if (param.probe_gi_direction == 3u) {
        basis = float3(-inv_sqrt3, inv_sqrt3, -inv_sqrt3);
    } else if (param.probe_gi_direction == 4u) {
        basis = float3(inv_sqrt3, -inv_sqrt3, -inv_sqrt3);
    }

    const float3 irradiance =
        ProbeGISampleIrradiance(lighting_data, world_position, basis);
    // Probe GI returns hemispherical irradiance. Dividing by PI gives an approximate mean
    // incident radiance suitable for a low-frequency isotropic multiple-scattering term.
    return max(irradiance, 0.0) * (1.0 / PI) * max(param.probe_gi_intensity, 0.0);
}

[numthreads(4, 4, 4)]
void main(
    uint3 dispatch_thread_id : SV_DispatchThreadID,
    uint3 group_thread_id : SV_GroupThreadID,
    uint3 group_id : SV_GroupID
) {
    uint width;
    uint height;
    uint depth;
    volume_texture.GetDimensions(width, height, depth);
    const uint3 volume_size = uint3(width, height, depth);
    const bool in_bounds = all(dispatch_thread_id < volume_size);

    // Probe irradiance varies far more slowly than density or CSM visibility. One lane samples
    // the center of each 4x4x4 workgroup and broadcasts 12 bytes through group shared memory,
    // reducing Probe GI lookup positions by 64x. Four-frame directional rotation provides a
    // further 4x temporal amortization without adding a texture or another dispatch.
    if (all(group_thread_id == uint3(0, 0, 0))) {
        const uint3 group_center = min(group_id * 4u + 2u, volume_size - 1u);
        const float3 group_world_position =
            stable_world_position_from_froxel(group_center, volume_size);
        group_probe_radiance = sample_group_probe_radiance(group_world_position);
    }
    GroupMemoryBarrierWithGroupSync();

    if (!in_bounds) {
        return;
    }

    const float2 jittered_uv =
        (float2(dispatch_thread_id.xy) + 0.5 + param.jitter.xy) / float2(width, height);
    const float2 stable_uv =
        (float2(dispatch_thread_id.xy) + 0.5) / float2(width, height);

    // Moer uses reversed Z: device depth 0 is the far plane. The normalized ray is then
    // scaled so the exponentially distributed slice depth is measured along view-space Z,
    // matching a perspective frustum rather than a spherical shell around the camera.
    const float3 far_world = world_pos_from_depth(0.0, jittered_uv, param.clip2world);
    const float3 ray_world = normalize(far_world - param.camera_position);
    const float3 ray_view  = mul(param.world2view, float4(ray_world, 0.0)).xyz;

    // Keep discontinuous lighting queries on the stable froxel center. Sampling CSM at the
    // jittered density position makes the binary depth comparisons cross a shadow edge every
    // frame; even after temporal accumulation this presents as a shimmering light-shaft edge.
    // Density remains stochastic below so temporal supersampling still hides slice banding.
    const float3 stable_far_world = world_pos_from_depth(0.0, stable_uv, param.clip2world);
    const float3 stable_ray_world = normalize(stable_far_world - param.camera_position);
    const float3 stable_ray_view = mul(
        param.world2view, float4(stable_ray_world, 0.0)
    ).xyz;

    const float slice_fraction = saturate(
        (float(dispatch_thread_id.z) + 0.5 + param.jitter.z) / float(depth)
    );
    const float stable_slice_fraction =
        (float(dispatch_thread_id.z) + 0.5) / float(depth);
    const float near_distance  = max(param.near_clip, 1.0e-3);
    const float far_distance   = max(min(param.max_distance, param.far_clip), near_distance + 1.0e-3);
    const float view_depth     = near_distance * pow(far_distance / near_distance, slice_fraction);
    const float ray_distance   = view_depth / max(abs(ray_view.z), 1.0e-4);
    const float3 world_position = param.camera_position + ray_world * ray_distance;
    const float stable_view_depth = near_distance * pow(
        far_distance / near_distance, stable_slice_fraction
    );
    const float stable_ray_distance = stable_view_depth / max(abs(stable_ray_view.z), 1.0e-4);
    const float3 stable_world_position =
        param.camera_position + stable_ray_world * stable_ray_distance;

    // Density is specified at height_offset and decays upward. Clamp the exponent to keep
    // FP16 storage stable when the camera moves far below the reference height.
    const float near_fade = param.near_fade_distance > 1.0e-4
        ? smoothstep(
            0.0,
            1.0,
            saturate((stable_view_depth - param.start_distance) / param.near_fade_distance)
        )
        : (stable_view_depth >= param.start_distance ? 1.0 : 0.0);

    const float height_exponent = clamp(
        -param.height_falloff * (world_position.y - param.height_offset), -16.0, 16.0
    );
    const float global_density = min(
        max(param.base_density, 0.0) * exp(height_exponent), 64.0
    ) * near_fade;

    float local_density = 0.0;
    if (param.local_volume_enabled != 0 && param.local_volume_radius > 1.0e-3) {
        const float radial_distance = length(
            world_position - param.local_volume_center
        ) / param.local_volume_radius;
        const float radial_fade = smoothstep(0.0, 1.0, saturate(1.0 - radial_distance));
        const float local_height_exponent = clamp(
            -param.local_volume_height_falloff *
                (world_position.y - param.local_volume_center.y - param.local_volume_height_offset),
            -16.0,
            16.0
        );
        local_density = min(
            max(param.local_volume_density, 0.0) *
                pow(radial_fade, max(param.local_volume_edge_falloff, 0.25)) *
                exp(local_height_exponent),
            64.0
        ) * near_fade;
    }

    const float extinction_scale = max(param.extinction_scale, 0.0);
    const float global_extinction = global_density * extinction_scale;
    const float local_extinction = local_density * extinction_scale;
    const float extinction = global_extinction + local_extinction;

    const float3 ambient_irradiance = max(param.ambient_color, 0.0) *
        max(param.ambient_intensity, 0.0);
    const float3 indirect_radiance = ambient_irradiance + group_probe_radiance;
    const float3 scattering =
        (global_extinction * saturate(param.albedo) +
         local_extinction * saturate(param.local_volume_albedo)) * indirect_radiance;

    const float visibility = sample_csm_visibility(stable_world_position);
    const float cos_theta = dot(
        normalize(param.directional_light_direction), -stable_ray_world
    );
    const float global_phase = henyey_greenstein(cos_theta, param.phase_g);
    const float local_phase = henyey_greenstein(cos_theta, param.local_volume_phase_g);
    const float3 directional_scattering =
        (global_extinction * saturate(param.albedo) * global_phase +
         local_extinction * saturate(param.local_volume_albedo) * local_phase) *
        max(param.directional_light_color, 0.0) * max(param.directional_intensity, 0.0) *
        visibility;
    const float3 local_emission = local_density * max(param.local_volume_emissive, 0.0);

    volume_texture[dispatch_thread_id] = float4(
        (scattering + directional_scattering) * max(param.scattering_intensity, 0.0) +
            local_emission,
        extinction
    );
    shadow_volume[dispatch_thread_id] = visibility;
}
