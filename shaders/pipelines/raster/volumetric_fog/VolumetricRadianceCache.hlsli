#ifndef MOER_VOLUMETRIC_RADIANCE_CACHE_HLSLI
#define MOER_VOLUMETRIC_RADIANCE_CACHE_HLSLI

Moer::VolumetricRadianceProbeData VolumetricRadianceCacheLoad(
    uint cache_buffer_handle,
    uint probe_index
) {
    ArrayBuffer cache_buffer = ArrayBuffer(cache_buffer_handle);
    return cache_buffer.Load<Moer::VolumetricRadianceProbeData>(probe_index);
}

float3 VolumetricRadianceCacheEvaluate(
    Moer::VolumetricRadianceProbeData cache,
    float3 direction,
    float directionality
) {
    const float3 directional =
        cache.l1_x.rgb * direction.x + cache.l1_y.rgb * direction.y + cache.l1_z.rgb * direction.z;
    return max(cache.l0.rgb + directional * saturate(directionality), 0.0);
}

void VolumetricRadianceCacheAccumulateProbe(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    uint probe_index,
    float trilinear_weight,
    float3 direction,
    float directionality,
    inout float3 radiance_sum,
    inout float weight_sum
) {
    if (probe_index == Moer::RASTER_PROBE_PAGE_INVALID || trilinear_weight <= 0.0) {
        return;
    }

    const Moer::ProbeGridProbeData probe = ProbeGILoadProbe(lighting_data, probe_index);
    const float state_weight = ProbeGIGetProbeStateWeight(probe);
    if (state_weight <= 0.0) {
        return;
    }
    const Moer::VolumetricRadianceProbeData cache =
        VolumetricRadianceCacheLoad(cache_buffer_handle, probe_index);
    const float position_error = length(cache.world_position.xyz - probe.world_position.xyz);
    if (cache.l0.w <= 1.0e-4 || position_error > 1.0e-3) {
        return;
    }

    const float weight = trilinear_weight * state_weight * saturate(cache.l0.w);
    radiance_sum += VolumetricRadianceCacheEvaluate(cache, direction, directionality) * weight;
    weight_sum += weight;
}

float3 VolumetricRadianceCacheSampleLevel(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    Moer::ProbeVolumeGpuDesc volume,
    float3 world_position,
    float3 direction,
    float directionality,
    uint subdivision_level,
    out float resident_coverage
) {
    resident_coverage = 0.0;
    if (!ProbeGIIsInsideVolume(volume, world_position)) {
        return float3(0.0, 0.0, 0.0);
    }

    const uint level = min(subdivision_level, volume.hierarchy.z);
    const uint3 counts = ProbeGIGetLevelCounts(volume, level);
    const uint3 max_coord = counts - uint3(1u, 1u, 1u);
    const float3 local = clamp(
        ProbeGIGetLocalCoordAtLevel(volume, world_position, level),
        float3(0.0, 0.0, 0.0),
        float3(max_coord)
    );
    const uint3 base_coord = uint3(floor(local));
    const uint3 next_coord = min(base_coord + uint3(1u, 1u, 1u), max_coord);
    const float3 f = frac(local);
    float3 radiance_sum = float3(0.0, 0.0, 0.0);
    float weight_sum = 0.0;

#define VRC_ACCUMULATE(COORD, WEIGHT) \
    VolumetricRadianceCacheAccumulateProbe( \
        lighting_data, cache_buffer_handle, \
        ProbeGIGetProbeIndexAtLevel(lighting_data, volume, COORD, level), \
        WEIGHT, direction, directionality, radiance_sum, weight_sum)

    VRC_ACCUMULATE(base_coord, (1.0 - f.x) * (1.0 - f.y) * (1.0 - f.z));
    VRC_ACCUMULATE(uint3(next_coord.x, base_coord.y, base_coord.z), f.x * (1.0 - f.y) * (1.0 - f.z));
    VRC_ACCUMULATE(uint3(base_coord.x, next_coord.y, base_coord.z), (1.0 - f.x) * f.y * (1.0 - f.z));
    VRC_ACCUMULATE(uint3(next_coord.x, next_coord.y, base_coord.z), f.x * f.y * (1.0 - f.z));
    VRC_ACCUMULATE(uint3(base_coord.x, base_coord.y, next_coord.z), (1.0 - f.x) * (1.0 - f.y) * f.z);
    VRC_ACCUMULATE(uint3(next_coord.x, base_coord.y, next_coord.z), f.x * (1.0 - f.y) * f.z);
    VRC_ACCUMULATE(uint3(base_coord.x, next_coord.y, next_coord.z), (1.0 - f.x) * f.y * f.z);
    VRC_ACCUMULATE(next_coord, f.x * f.y * f.z);
#undef VRC_ACCUMULATE

    resident_coverage = saturate(weight_sum);
    return weight_sum > 1.0e-5 ? radiance_sum / weight_sum : float3(0.0, 0.0, 0.0);
}

float3 VolumetricRadianceCacheSampleHierarchy(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    Moer::ProbeVolumeGpuDesc volume,
    float3 world_position,
    float3 direction,
    float directionality,
    uint start_level,
    out float resolved_coverage
) {
    float3 result = float3(0.0, 0.0, 0.0);
    float remaining = 1.0;
    resolved_coverage = 0.0;
    [unroll] for (uint level = 0u; level <= Moer::RASTER_PROBE_MAX_SUBDIVISION_LEVEL; ++level) {
        if (level < start_level || level > volume.hierarchy.z || remaining <= 1.0e-5) {
            continue;
        }
        float level_coverage = 0.0;
        const float3 level_radiance = VolumetricRadianceCacheSampleLevel(
            lighting_data,
            cache_buffer_handle,
            volume,
            world_position,
            direction,
            directionality,
            level,
            level_coverage
        );
        const float contribution = remaining * saturate(level_coverage);
        result += level_radiance * contribution;
        resolved_coverage += contribution;
        remaining *= 1.0 - saturate(level_coverage);
    }
    return resolved_coverage > 1.0e-5 ? result / resolved_coverage : float3(0.0, 0.0, 0.0);
}

float3 VolumetricRadianceCacheSampleVolume(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    Moer::ProbeVolumeGpuDesc volume,
    float3 world_position,
    float3 direction,
    float directionality,
    out float resident_coverage
) {
    uint desired_level;
    uint transition_level;
    float transition_weight;
    ProbeGIResolveAdaptiveLevels(
        lighting_data,
        volume,
        world_position,
        desired_level,
        transition_level,
        transition_weight
    );

    float primary_coverage = 0.0;
    const float3 primary = VolumetricRadianceCacheSampleHierarchy(
        lighting_data,
        cache_buffer_handle,
        volume,
        world_position,
        direction,
        directionality,
        desired_level,
        primary_coverage
    );
    if (transition_level <= desired_level || transition_weight <= 1.0e-5) {
        resident_coverage = primary_coverage;
        return primary;
    }

    float coarse_coverage = 0.0;
    const float3 coarse = VolumetricRadianceCacheSampleHierarchy(
        lighting_data,
        cache_buffer_handle,
        volume,
        world_position,
        direction,
        directionality,
        transition_level,
        coarse_coverage
    );
    const float primary_weight = primary_coverage * (1.0 - transition_weight);
    const float coarse_weight = coarse_coverage * transition_weight;
    const float combined = primary_weight + coarse_weight;
    resident_coverage = saturate(combined);
    return combined > 1.0e-5 ?
        (primary * primary_weight + coarse * coarse_weight) / combined :
        float3(0.0, 0.0, 0.0);
}

float3 VolumetricRadianceCacheSampleDetailed(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    float3 world_position,
    float3 direction,
    float directionality,
    out float resident_coverage
) {
    float3 radiance_sum = float3(0.0, 0.0, 0.0);
    float volume_weight_sum = 0.0;
    [unroll] for (uint volume_index = 0u; volume_index < Moer::RASTER_PROBE_VOLUME_MAX_COUNT; ++volume_index) {
        if (volume_index >= lighting_data.probe_system_counts.x) {
            continue;
        }
        const Moer::ProbeVolumeGpuDesc volume = ProbeGILoadVolume(lighting_data, volume_index);
        if (!ProbeGIIsInsideVolume(volume, world_position)) {
            continue;
        }
        float coverage = 0.0;
        const float3 radiance = VolumetricRadianceCacheSampleVolume(
            lighting_data,
            cache_buffer_handle,
            volume,
            world_position,
            direction,
            directionality,
            coverage
        );
        if (coverage <= 1.0e-5) {
            continue;
        }
        const float weight = ProbeGIGetVolumeBlendWeight(volume, world_position) * coverage;
        radiance_sum += radiance * max(volume.spacing_intensity.w, 0.0) * weight;
        volume_weight_sum += weight;
    }
    resident_coverage = saturate(volume_weight_sum);
    return volume_weight_sum > 1.0e-5 ? radiance_sum / volume_weight_sum : float3(0.0, 0.0, 0.0);
}

float3 VolumetricRadianceCacheSample(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    float3 world_position,
    float3 direction,
    float directionality
) {
    float resident_coverage;
    return VolumetricRadianceCacheSampleDetailed(
        lighting_data,
        cache_buffer_handle,
        world_position,
        direction,
        directionality,
        resident_coverage
    );
}

// Lightweight diagnostics for the already-selected sparse hierarchy. This intentionally avoids
// a second eight-probe interpolation; it reports the nearest resident probe that explains the
// cache sample together with brick age and adaptive level.
float4 VolumetricRadianceCacheDebugMetadata(
    Moer::LightingData lighting_data,
    uint cache_buffer_handle,
    float3 world_position,
    float resident_coverage
) {
    float best_volume_weight = 0.0;
    float resolved_level = 0.0;
    float update_age = 1.0;
    float multiple_scatter = 0.0;
    float medium_extinction = 0.0;
    [unroll] for (uint volume_index = 0u; volume_index < Moer::RASTER_PROBE_VOLUME_MAX_COUNT; ++volume_index) {
        if (volume_index >= lighting_data.probe_system_counts.x) {
            continue;
        }
        const Moer::ProbeVolumeGpuDesc volume = ProbeGILoadVolume(lighting_data, volume_index);
        if (!ProbeGIIsInsideVolume(volume, world_position)) {
            continue;
        }
        const float volume_weight = ProbeGIGetVolumeBlendWeight(volume, world_position);
        if (volume_weight <= best_volume_weight) {
            continue;
        }

        uint desired_level;
        uint transition_level;
        float transition_weight;
        ProbeGIResolveAdaptiveLevels(
            lighting_data,
            volume,
            world_position,
            desired_level,
            transition_level,
            transition_weight
        );
        uint selected_level = min(desired_level, volume.hierarchy.z);
        uint selected_brick = Moer::RASTER_PROBE_PAGE_INVALID;
        uint3 selected_coord = uint3(0u, 0u, 0u);
        [unroll] for (uint level = 0u; level <= Moer::RASTER_PROBE_MAX_SUBDIVISION_LEVEL; ++level) {
            if (level < selected_level || level > volume.hierarchy.z ||
                selected_brick != Moer::RASTER_PROBE_PAGE_INVALID) {
                continue;
            }
            const uint3 counts = ProbeGIGetLevelCounts(volume, level);
            const float3 local = clamp(
                ProbeGIGetLocalCoordAtLevel(volume, world_position, level),
                float3(0.0, 0.0, 0.0),
                float3(counts - uint3(1u, 1u, 1u))
            );
            const uint3 coord = min(uint3(round(local)), counts - uint3(1u, 1u, 1u));
            const uint brick_index = ProbeGIGetBrickIndexAtLevel(
                lighting_data,
                volume,
                coord,
                level
            );
            if (brick_index != Moer::RASTER_PROBE_PAGE_INVALID) {
                selected_brick = brick_index;
                selected_coord = coord;
                selected_level = level;
            }
        }
        if (selected_brick == Moer::RASTER_PROBE_PAGE_INVALID) {
            continue;
        }

        ArrayBuffer brick_buffer = ArrayBuffer(lighting_data.probe_system_counts.z);
        const Moer::ProbeBrickGpuDesc brick =
            brick_buffer.Load<Moer::ProbeBrickGpuDesc>(selected_brick);
        const uint probe_index = ProbeGIGetProbeIndexAtLevel(
            lighting_data,
            volume,
            selected_coord,
            selected_level
        );
        if (probe_index != Moer::RASTER_PROBE_PAGE_INVALID) {
            const Moer::VolumetricRadianceProbeData cache =
                VolumetricRadianceCacheLoad(cache_buffer_handle, probe_index);
            multiple_scatter = max(cache.l1_x.w, 0.0);
            medium_extinction = max(cache.world_position.w, 0.0);
        }
        resolved_level = float(selected_level) /
            float(max(volume.hierarchy.z, 1u));
        update_age = float(min(brick.local_counts.w, 255u)) * (1.0 / 255.0);
        best_volume_weight = volume_weight;
    }
    return float4(
        saturate(resident_coverage),
        saturate(resolved_level),
        saturate(update_age),
        max(multiple_scatter + medium_extinction * 0.01, 0.0)
    );
}

#endif
