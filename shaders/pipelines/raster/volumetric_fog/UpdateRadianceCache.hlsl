#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "shared/raster/ShaderParameters.h"
#include "shared/raster/SharedEnum.h"
#include "shared/ShaderParameters.h"
#include "shared/scene/SharedSceneStruct.h"

[[vk::push_constant]] ConstantBuffer<Moer::VolumetricRadianceCacheUpdateParam> param;

[[vk::binding(0, 0)]] StructuredBuffer<Moer::ProbeGridProbeData> probe_data;
[[vk::binding(1, 0)]] StructuredBuffer<Moer::ProbeGridIrradianceTexel> irradiance_atlas;
[[vk::binding(2, 0)]] StructuredBuffer<Moer::ProbeBrickGpuDesc> probe_brick_data;
[[vk::binding(3, 0)]] StructuredBuffer<Moer::VolumetricRadianceProbeData> history_radiance_cache;
[[vk::binding(4, 0)]] RWStructuredBuffer<Moer::VolumetricRadianceProbeData> rw_radiance_cache;
#if VRC_USE_RAY_QUERY
[[vk::binding(5, 0)]] RaytracingAccelerationStructure tlas;
#endif

float3 safe_normalize(float3 value, float3 fallback) {
    const float length_squared = dot(value, value);
    return length_squared > 1.0e-6 ? value * rsqrt(length_squared) : fallback;
}

float2 encode_octahedral(float3 direction) {
    float3 n = direction / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 1.0e-5);
    if (n.z < 0.0) {
        const float2 sign_xy = float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
        n.xy = (1.0 - abs(n.yx)) * sign_xy;
    }
    return saturate(n.xy * 0.5 + 0.5);
}

int2 fold_octahedral_texel(int2 texel, uint dim) {
    const int max_texel = int(dim) - 1;
    int2 folded = texel;
    [unroll] for (uint fold = 0u; fold < 2u; ++fold) {
        if (folded.x < 0) {
            folded.x = max_texel;
            folded.y = max_texel - folded.y;
        } else if (folded.x > max_texel) {
            folded.x = 0;
            folded.y = max_texel - folded.y;
        }
        if (folded.y < 0) {
            folded.y = max_texel;
            folded.x = max_texel - folded.x;
        } else if (folded.y > max_texel) {
            folded.y = 0;
            folded.x = max_texel - folded.x;
        }
    }
    return clamp(folded, int2(0, 0), int2(max_texel, max_texel));
}

float4 load_irradiance_texel(uint probe_index, int2 texel) {
    const uint dim = Moer::RASTER_PROBE_IRRADIANCE_ATLAS_DIM;
    const int2 folded = fold_octahedral_texel(texel, dim);
    const uint atlas_index = probe_index * Moer::RASTER_PROBE_IRRADIANCE_ATLAS_TEXEL_COUNT +
                             uint(folded.y) * dim + uint(folded.x);
    return irradiance_atlas[atlas_index].irradiance;
}

float4 sample_irradiance(uint probe_index, float3 direction) {
    const uint dim = Moer::RASTER_PROBE_IRRADIANCE_ATLAS_DIM;
    const float2 texel_position = encode_octahedral(direction) * float(dim) - 0.5;
    const int2 base = int2(floor(texel_position));
    const float2 f = saturate(texel_position - float2(base));
    const float4 i00 = load_irradiance_texel(probe_index, base);
    const float4 i10 = load_irradiance_texel(probe_index, base + int2(1, 0));
    const float4 i01 = load_irradiance_texel(probe_index, base + int2(0, 1));
    const float4 i11 = load_irradiance_texel(probe_index, base + int2(1, 1));
    const float w00 = (1.0 - f.x) * (1.0 - f.y);
    const float w10 = f.x * (1.0 - f.y);
    const float w01 = (1.0 - f.x) * f.y;
    const float w11 = f.x * f.y;
    const float confidence = saturate(i00.w * w00 + i10.w * w10 + i01.w * w01 + i11.w * w11);
    if (confidence <= 1.0e-4) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    const float3 irradiance =
        (i00.rgb * i00.w * w00 + i10.rgb * i10.w * w10 +
         i01.rgb * i01.w * w01 + i11.rgb * i11.w * w11) / confidence;
    return float4(max(irradiance, 0.0), confidence);
}

float evaluate_medium_extinction(float3 world_position) {
    const float global_exponent = clamp(
        -max(param.medium_global.y, 0.0) * (world_position.y - param.medium_global.z),
        -16.0,
        16.0
    );
    float density = max(param.medium_global.x, 0.0) * exp(global_exponent);
    if (param.cache_control.z > 0.5 && param.medium_local_center.w > 1.0e-3) {
        const float radial_distance =
            length(world_position - param.medium_local_center.xyz) / param.medium_local_center.w;
        const float radial_fade = smoothstep(0.0, 1.0, saturate(1.0 - radial_distance));
        const float local_exponent = clamp(
            -max(param.medium_local_shape.z, 0.0) *
                (world_position.y - param.medium_local_center.y - param.medium_local_shape.w),
            -16.0,
            16.0
        );
        density += max(param.medium_local_shape.x, 0.0) *
            pow(radial_fade, max(param.medium_local_shape.y, 0.25)) * exp(local_exponent);
    }
    return min(density * max(param.medium_global.w, 0.0), 64.0);
}

float integrate_medium_transmittance(float3 origin, float3 direction, float distance_to_light) {
    const float distance = min(max(distance_to_light, 0.0), max(param.cache_control.y, 0.0));
    if (distance <= 1.0e-4) {
        return 1.0;
    }
    const uint step_count = clamp(param.cache_dispatch.x, 1u, 12u);
    const float step_length = distance / float(step_count);
    float optical_depth = 0.0;
    [loop] for (uint step = 0u; step < 12u; ++step) {
        if (step >= step_count) {
            break;
        }
        const float sample_t = (float(step) + 0.5) * step_length;
        optical_depth += evaluate_medium_extinction(origin + direction * sample_t) * step_length;
    }
    return exp(-min(optical_depth, 16.0));
}

float trace_geometric_visibility(float3 origin, float3 direction, float distance_to_light) {
#if VRC_USE_RAY_QUERY
    if (distance_to_light <= 1.0e-4) {
        return 1.0;
    }
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = direction;
    ray.TMin = 0.01;
    ray.TMax = distance_to_light;
    RayQuery<
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH |
        RAY_FLAG_FORCE_OPAQUE> query;
    query.TraceRayInline(tlas, RAY_FLAG_NONE, Moer::RTVM_ALL, ray);
    query.Proceed();
    return query.CommittedStatus() == COMMITTED_NOTHING ? 1.0 : 0.0;
#else
    return 1.0;
#endif
}

float3 evaluate_first_scatter_source(float3 world_position, float local_scatter_probability) {
    if (param.probe.probe_update_context.x == 0u || param.probe.probe_update_context.y == 0u ||
        local_scatter_probability <= 1.0e-5) {
        return float3(0.0, 0.0, 0.0);
    }

    ArrayBuffer light_buffer = ArrayBuffer(param.probe.probe_update_context.x);
    float3 source = float3(0.0, 0.0, 0.0);
    [loop] for (uint light_index = 0u; light_index < param.probe.probe_update_context.y; ++light_index) {
        const Moer::GLight light = light_buffer.Load<Moer::GLight>(light_index);
        const float3 energy = max(light.color * light.intensity, 0.0);
        if (light.type == Moer::ELightType::Ambient || light.type == Moer::ELightType::Environment) {
            source += energy;
            continue;
        }

        float3 direction_to_light = float3(0.0, 1.0, 0.0);
        float distance_to_light = max(param.cache_control.y, 0.1);
        float attenuation = 1.0;
        if (light.type == Moer::ELightType::Directional) {
            direction_to_light = safe_normalize(-light.direction, direction_to_light);
        } else if (light.type == Moer::ELightType::Point || light.type == Moer::ELightType::Spot) {
            const float3 to_light = light.position - world_position;
            const float distance_squared = dot(to_light, to_light);
            if (distance_squared <= 1.0e-6) {
                continue;
            }
            distance_to_light = sqrt(distance_squared);
            direction_to_light = to_light / distance_to_light;
            attenuation = rcp(max(4.0 * PI * distance_squared, 1.0e-4));
            if (light.type == Moer::ELightType::Spot) {
                const float cone_cosine = dot(
                    -direction_to_light,
                    safe_normalize(light.direction, float3(0.0, -1.0, 0.0))
                );
                attenuation *= saturate(
                    (cone_cosine - light.info.y) / max(light.info.x - light.info.y, 1.0e-4)
                );
            }
        } else {
            continue;
        }

        const float max_shadow_distance = max(distance_to_light - 0.02, 0.0);
        const float visibility = trace_geometric_visibility(
            world_position + direction_to_light * 0.02,
            direction_to_light,
            max_shadow_distance
        );
        const float medium_transmittance = integrate_medium_transmittance(
            world_position,
            direction_to_light,
            distance_to_light
        );
        source += energy * attenuation * visibility * medium_transmittance;
    }

    // This source is deliberately scattered once before caching. InjectDensity applies the next
    // scattering event, so primary directional lighting is not counted twice.
    return source * saturate(param.medium_albedo.rgb) * local_scatter_probability *
           max(param.medium_albedo.w, 0.0) * (1.0 / (4.0 * PI));
}

void accumulate_neighbor(
    Moer::ProbeBrickGpuDesc brick,
    int3 coordinate,
    float3 current_position,
    inout float3 radiance_sum,
    inout float weight_sum
) {
    const int3 counts = int3(max(brick.local_counts.xyz, uint3(1u, 1u, 1u)));
    if (any(coordinate < int3(0, 0, 0)) || any(coordinate >= counts)) {
        return;
    }
    const uint local_index = uint(coordinate.x) + uint(coordinate.y) * uint(counts.x) +
                             uint(coordinate.z) * uint(counts.x * counts.y);
    const uint neighbor_index = brick.probe_range.x + local_index;
    const Moer::VolumetricRadianceProbeData neighbor = history_radiance_cache[neighbor_index];
    if (neighbor.l0.w <= 1.0e-4) {
        return;
    }
    const Moer::ProbeGridProbeData neighbor_probe = probe_data[neighbor_index];
    if (length(neighbor.world_position.xyz - neighbor_probe.world_position.xyz) > 1.0e-3) {
        return;
    }
    const float distance = length(neighbor.world_position.xyz - current_position);
    const float transmittance = integrate_medium_transmittance(
        current_position,
        safe_normalize(neighbor.world_position.xyz - current_position, float3(0.0, 1.0, 0.0)),
        distance
    );
    radiance_sum += max(neighbor.l0.rgb, 0.0) * transmittance * saturate(neighbor.l0.w);
    weight_sum += saturate(neighbor.l0.w);
}

[numthreads(Moer::RASTER_PROBE_UPDATE_GROUP_SIZE, 1, 1)]
void main(uint local_probe_index : SV_DispatchThreadID) {
    const uint brick_index = param.probe.probe_update_context.w;
    if (brick_index >= Moer::RASTER_PROBE_MAX_BRICK_COUNT) {
        return;
    }
    const Moer::ProbeBrickGpuDesc brick = probe_brick_data[brick_index];
    if (brick.probe_range.z == 0u || brick.coord_volume.w != param.probe.probe_volume_counts.w) {
        return;
    }
    const uint3 local_counts = max(brick.local_counts.xyz, uint3(1u, 1u, 1u));
    const uint local_count = local_counts.x * local_counts.y * local_counts.z;
    if (local_probe_index >= local_count) {
        return;
    }

    const uint probe_index = brick.probe_range.x + local_probe_index;
    const Moer::ProbeGridProbeData probe = probe_data[probe_index];
    const uint state = uint(round(max(probe.world_position.w, 0.0)));
    if (state == Moer::RASTER_PROBE_STATE_INVALID) {
        Moer::VolumetricRadianceProbeData invalid = (Moer::VolumetricRadianceProbeData)0;
        invalid.world_position = float4(probe.world_position.xyz, 0.0);
        rw_radiance_cache[probe_index] = invalid;
        return;
    }

    static const float inv_sqrt3 = 0.57735026919;
    const float3 d0 = float3( inv_sqrt3,  inv_sqrt3,  inv_sqrt3);
    const float3 d1 = float3(-inv_sqrt3, -inv_sqrt3,  inv_sqrt3);
    const float3 d2 = float3(-inv_sqrt3,  inv_sqrt3, -inv_sqrt3);
    const float3 d3 = float3( inv_sqrt3, -inv_sqrt3, -inv_sqrt3);
    const float4 s0 = sample_irradiance(probe_index, d0);
    const float4 s1 = sample_irradiance(probe_index, d1);
    const float4 s2 = sample_irradiance(probe_index, d2);
    const float4 s3 = sample_irradiance(probe_index, d3);
    const float confidence = min(min(s0.w, s1.w), min(s2.w, s3.w));

    // Surface DDGI is the stable boundary-radiance source. The cache itself owns directional
    // coefficients, temporal transport and medium-aware higher-order scattering.
    const float3 r0 = s0.rgb * (1.0 / PI);
    const float3 r1 = s1.rgb * (1.0 / PI);
    const float3 r2 = s2.rgb * (1.0 / PI);
    const float3 r3 = s3.rgb * (1.0 / PI);
    Moer::VolumetricRadianceProbeData current;
    current.l0 = float4((r0 + r1 + r2 + r3) * 0.25, confidence);
    current.l1_x = float4((r0 * d0.x + r1 * d1.x + r2 * d2.x + r3 * d3.x) * 0.75, 0.0);
    current.l1_y = float4((r0 * d0.y + r1 * d1.y + r2 * d2.y + r3 * d3.y) * 0.75, 0.0);
    current.l1_z = float4((r0 * d0.z + r1 * d1.z + r2 * d2.z + r3 * d3.z) * 0.75, 0.0);

    const float extinction = evaluate_medium_extinction(probe.world_position.xyz);
    const float transport_scale = max(
        min(min(param.probe.probe_volume_spacing.x, param.probe.probe_volume_spacing.y),
            param.probe.probe_volume_spacing.z),
        0.05
    );
    const float scatter_probability = 1.0 - exp(-extinction * transport_scale);
    const float3 direct_multiple_scatter = evaluate_first_scatter_source(
        probe.world_position.xyz,
        scatter_probability
    );

    const uint x = local_probe_index % local_counts.x;
    const uint y = (local_probe_index / local_counts.x) % local_counts.y;
    const uint z = local_probe_index / (local_counts.x * local_counts.y);
    const int3 coordinate = int3(x, y, z);
    float3 neighbor_sum = float3(0.0, 0.0, 0.0);
    float neighbor_weight = 0.0;
    accumulate_neighbor(brick, coordinate + int3(-1, 0, 0), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    accumulate_neighbor(brick, coordinate + int3( 1, 0, 0), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    accumulate_neighbor(brick, coordinate + int3(0, -1, 0), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    accumulate_neighbor(brick, coordinate + int3(0,  1, 0), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    accumulate_neighbor(brick, coordinate + int3(0, 0, -1), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    accumulate_neighbor(brick, coordinate + int3(0, 0,  1), probe.world_position.xyz, neighbor_sum, neighbor_weight);
    const float3 neighbor_multiple_scatter = neighbor_weight > 1.0e-4
        ? neighbor_sum / neighbor_weight * saturate(param.medium_albedo.rgb) * scatter_probability *
            max(param.medium_albedo.w, 0.0)
        : float3(0.0, 0.0, 0.0);
    const float3 multiple_scatter = direct_multiple_scatter + neighbor_multiple_scatter;
    current.l0.rgb += min(multiple_scatter, max(current.l0.rgb * 2.0 + 0.25, 0.25));

    const Moer::VolumetricRadianceProbeData history = history_radiance_cache[probe_index];
    const float position_error = length(history.world_position.xyz - probe.world_position.xyz);
    const float history_weight = history.l0.w > 1.0e-4 && position_error < 1.0e-3
        ? saturate(param.cache_control.x)
        : 0.0;
    current.l0.rgb = lerp(current.l0.rgb, history.l0.rgb, history_weight);
    current.l1_x.rgb = lerp(current.l1_x.rgb, history.l1_x.rgb, history_weight);
    current.l1_y.rgb = lerp(current.l1_y.rgb, history.l1_y.rgb, history_weight);
    current.l1_z.rgb = lerp(current.l1_z.rgb, history.l1_z.rgb, history_weight);
    current.l0.w = max(confidence, history.l0.w * history_weight);
    current.l1_x.w = dot(multiple_scatter, float3(0.2126, 0.7152, 0.0722));
    current.l1_y.w = scatter_probability;
    current.l1_z.w = float(param.cache_dispatch.y & 0xffffu) * (1.0 / 65535.0);
    current.world_position = float4(probe.world_position.xyz, extinction);
    rw_radiance_cache[probe_index] = current;
}
