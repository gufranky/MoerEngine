#include "shared/raster/ShaderParameters.h"

[[vk::binding(0, 0)]] RWStructuredBuffer<Moer::VolumetricRadianceProbeData> rw_radiance_cache;

[numthreads(64, 1, 1)]
void main(uint dispatch_thread_id : SV_DispatchThreadID) {
    if (dispatch_thread_id >= Moer::RASTER_PROBE_MAX_COUNT) {
        return;
    }

    Moer::VolumetricRadianceProbeData value = (Moer::VolumetricRadianceProbeData)0;
    rw_radiance_cache[dispatch_thread_id] = value;
}
