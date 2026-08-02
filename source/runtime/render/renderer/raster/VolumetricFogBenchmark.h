#pragma once

#include "misc/STL.h"
#include "rhi/RHIResource.h"

#include <filesystem>
#include <fstream>
#include <string>

namespace Moer {
class Camera;
struct RasterConfig;
}

namespace Moer::Render {
class CommandList;
class CommandQueue;
}

namespace Moer::Render::Raster {

/**
 * Opt-in, deterministic volumetric-fog visual benchmark.
 *
 * Enable with MOER_FOG_BENCHMARK_PRESET. Supported presets are:
 * off, halton, fast_xy, fast_xyz, no_shadows, probe_gi and showcase.
 * Each preset is intentionally run in a fresh process so temporal history and
 * stochastic sequences begin from the same state.
 */
class VolumetricFogBenchmark {
public:
    VolumetricFogBenchmark();

    bool IsEnabled() const noexcept;
    uint64 GetEffectFrameIndex(uint64 fallback_frame_index) const noexcept;

    void BeginFrame(Camera& camera, RasterConfig& config, uint2 resolution);
    void QueueCapture(CommandList& cmd_list, const TextureRef& texture);
    void EndFrame(CommandQueue& gfx_queue);

private:
    void Initialize(Camera& camera, const RasterConfig& config, uint2 resolution);
    void ApplyPreset(RasterConfig& config) const;
    void ApplyCameraPose(Camera& camera);
    void WriteTrajectoryRow(const Camera& camera);
    void WriteCapturePng();
    bool IsCaptureTrajectoryFrame(uint frame) const noexcept;

    bool enabled             = false;
    bool initialized         = false;
    bool capture_queued      = false;
    bool close_after_capture = false;

    std::string preset;
    std::string view = "corridor";
    std::filesystem::path output_root;
    std::filesystem::path preset_output_dir;
    std::filesystem::path pending_capture_path;
    std::ofstream trajectory_stream;

    uint2 capture_resolution = uint2(0u);
    uint  run_frame          = 0u;
    uint  trajectory_frame   = 0u;

    float3 base_position = float3(0.0f);
    float3 base_front    = float3(1.0f, 0.0f, 0.0f);
    float3 base_right    = float3(0.0f, 0.0f, 1.0f);
    float  base_yaw      = 0.0f;
    float  base_pitch    = 0.0f;
    float  base_fov      = 60.0f;
    float  base_aspect   = 16.0f / 9.0f;
    float  base_near     = 0.1f;
    float  base_far      = 1000.0f;

    Array<byte> readback_pixels;

    static constexpr uint k_warmup_frames     = 120u;
    static constexpr uint k_trajectory_frames = 90u;
};

} // namespace Moer::Render::Raster
