#include "shared/raster/ShaderParameters.h"

[[vk::binding(0, 0)]] StructuredBuffer<Moer::VolumetricRadianceProbeData> source_cache;
[[vk::binding(1, 0)]] RWStructuredBuffer<Moer::VolumetricRadianceProbeData> destination_cache;

[numthreads(64, 1, 1)]
void main(uint dispatch_thread_id : SV_DispatchThreadID) {
    if (dispatch_thread_id < Moer::RASTER_PROBE_MAX_COUNT) {
        destination_cache[dispatch_thread_id] = source_cache[dispatch_thread_id];
    }
}
