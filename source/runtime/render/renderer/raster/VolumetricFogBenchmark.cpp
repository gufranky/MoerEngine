#include "VolumetricFogBenchmark.h"

#include "RasterConfig.h"
#include "config/ConfigManager.h"
#include "log/LogSystem.h"
#include "rhi/RHI.h"
#include "rhi/RHICommand.h"
#include "scene/camera/Camera.h"
#include "window/WindowContext.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <stb/stb_image_write.h>

namespace Moer::Render::Raster {

namespace {

constexpr std::array<std::string_view, 12> k_supported_presets = {
    "off", "mvp", "halton", "fast_xy", "fast_xyz", "no_shadows", "probe_gi", "probe_gi_high", "halton_nogi", "showcase", "highcontrast", "nocoverage"
};

std::string ReadEnvironment(const char* name) {
    const char* value = std::getenv(name);
    return value ? std::string(value) : std::string();
}

bool IsSupportedPreset(std::string_view preset) {
    return std::find(k_supported_presets.begin(), k_supported_presets.end(), preset) !=
           k_supported_presets.end();
}

float SmoothStep(float value) {
    value = std::clamp(value, 0.0f, 1.0f);
    return value * value * (3.0f - 2.0f * value);
}

byte LinearByteToSrgb(byte value) {
    const float linear = static_cast<float>(static_cast<unsigned char>(value)) / 255.0f;
    const float srgb = linear <= 0.0031308f
        ? 12.92f * linear
        : 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
    const float quantized = std::round(std::clamp(srgb, 0.0f, 1.0f) * 255.0f);
    return static_cast<byte>(static_cast<unsigned char>(quantized));
}

} // namespace

VolumetricFogBenchmark::VolumetricFogBenchmark() {
    preset = ReadEnvironment("MOER_FOG_BENCHMARK_PRESET");
    if (preset.empty()) {
        return;
    }
    if (!IsSupportedPreset(preset)) {
        LOG_ERROR(
            "[FogBenchmark] Unsupported preset '{}'. Expected off, halton, fast_xy, fast_xyz, "
            "no_shadows, probe_gi or showcase.",
            preset
        );
        return;
    }

    const std::string configured_output = ReadEnvironment("MOER_FOG_BENCHMARK_DIR");
    output_root = configured_output.empty()
        ? ConfigManager::GetInstance().GetWorkspacePath() / "saved" / "volumetric_fog_capture"
        : std::filesystem::path(configured_output);
    const std::string configured_view = ReadEnvironment("MOER_FOG_BENCHMARK_VIEW");
    if (!configured_view.empty()) {
        view = configured_view;
    }
    if (view != "corridor" && view != "sunshaft") {
        LOG_ERROR("[FogBenchmark] Unsupported view '{}'. Expected corridor or sunshaft.", view);
        return;
    }
    preset_output_dir = output_root / view / preset;
    {
        const std::string jitter_override = ReadEnvironment("MOER_FOG_JITTER");
        if (!jitter_override.empty()) {
            preset_output_dir = preset_output_dir / jitter_override;
        }
    }
    enabled = true;
}

bool VolumetricFogBenchmark::IsEnabled() const noexcept {
    return enabled;
}

uint64 VolumetricFogBenchmark::GetEffectFrameIndex(uint64 fallback_frame_index) const noexcept {
    return enabled && initialized ? static_cast<uint64>(run_frame) : fallback_frame_index;
}

void VolumetricFogBenchmark::Initialize(
    Camera& camera,
    const RasterConfig& config,
    uint2 resolution
) {
    std::error_code error;
    std::filesystem::create_directories(preset_output_dir, error);
    if (error) {
        LOG_ERROR(
            "[FogBenchmark] Cannot create output directory '{}': {}",
            preset_output_dir.string(),
            error.message()
        );
        enabled = false;
        return;
    }

    capture_resolution = resolution;
    base_position = camera.GetPosition();
    base_front    = camera.GetFront();
    base_right    = camera.GetRight();
    base_yaw      = camera.GetYaw();
    base_pitch    = camera.GetPitch();
    base_fov      = camera.GetFov();
    base_aspect   = camera.GetAspectRatio();
    base_near     = camera.GetNearClip();
    base_far      = camera.GetFarClip();

    // A second in-hall view tilts toward the skylight and arch occluders. It makes directional
    // in-scattering and volumetric CSM shadows readable without changing the medium parameters.
    if (view == "sunshaft") {
        base_position = float3(-7.0f, 3.5f, 0.0f);
        base_yaw      = 5.0f;
        base_pitch    = 10.0f;
        base_fov      = 45.0f;
        camera.Initialize(base_position, base_yaw, base_pitch, base_fov, base_aspect, base_near, base_far);
        base_front = camera.GetFront();
        base_right = camera.GetRight();
    }

    trajectory_stream.open(preset_output_dir / "trajectory.csv", std::ios::trunc);
    trajectory_stream << "preset,run_frame,trajectory_frame,u,pos_x,pos_y,pos_z,yaw,pitch,capture\n";

    std::ofstream manifest(preset_output_dir / "manifest.csv", std::ios::trunc);
    manifest << "key,value\n";
    manifest << "preset," << preset << "\n";
    manifest << "view," << view << "\n";
    manifest << "resolution," << resolution.x << "x" << resolution.y << "\n";
    manifest << "warmup_frames," << k_warmup_frames << "\n";
    manifest << "trajectory_frames," << k_trajectory_frames << "\n";
    manifest << "base_position," << base_position.x << ' ' << base_position.y << ' ' << base_position.z << "\n";
    manifest << "base_yaw_pitch," << base_yaw << ' ' << base_pitch << "\n";
    manifest << "base_fov," << base_fov << "\n";
    manifest << "fixed_timestep,0.0166667\n";
    manifest << "auto_exposure,1 (engine display path; 120-frame warmup)\n";
    manifest << "exposure_compensation_ev," << (view == "sunshaft" ? -3.2f : -2.7f) << "\n";
    manifest << "capture_frames,0 22 45 67 89\n";
    // nocoverage uses very short warmup to capture pre-convergence frames
    effective_warmup_frames = k_default_warmup_frames;
    if (preset == "nocoverage") {
        effective_warmup_frames = 10u;
        manifest << "effective_warmup_frames,10\n";
    }

    initialized = true;
    LOG_INFO(
        "[FogBenchmark] Started view='{}', preset='{}', output='{}', resolution={}x{}, base=({:.3f}, {:.3f}, "
        "{:.3f}), yaw={:.3f}, pitch={:.3f}.",
        view,
        preset,
        preset_output_dir.string(),
        resolution.x,
        resolution.y,
        base_position.x,
        base_position.y,
        base_position.z,
        base_yaw,
        base_pitch
    );
}

void VolumetricFogBenchmark::ApplyPreset(RasterConfig& config) const {
    // Hold unrelated temporal variables constant across fresh-process runs.
    config.aa_mode                       = EAaMode::FXAA_QUALITY;
    config.tonemapping_ae.enabled        = true;
    config.tonemapping_exposure_ev       = view == "sunshaft" ? -3.2f : -2.7f;
    config.tonemapping_reinhard_enabled  = true;
    // Do not inherit the editor's persisted shadow mode: it changes the volumetric-lighting
    // result far more than the quality variables this benchmark is intended to compare.
    config.shadow_map_mode               = EShadowMapMode::CSM;
    config.probe_gi_volume_bounds_enabled = false;
    config.probe_gi_gizmo_enabled         = false;
    config.probe_gi_debug_mode             = 0;
    config.volumetric_fog_debug_mode     = 0;
    config.volumetric_fog_local_volume_enabled = false;
    config.volumetric_fog_temporal_enabled     = true;
    config.volumetric_fog_shadows_enabled      = true;
    config.volumetric_fog_shadow_pcf_radius    = 1;
    config.volumetric_fog_probe_gi_enabled     = true;
    config.volumetric_fog_radiance_cache_enabled = true;
    config.volumetric_fog_reconstruction_filter_enabled  = true;
    config.volumetric_fog_reconstruction_filter_strength = 0.75f;

    if (preset == "off") {
        config.volumetric_fog_enabled = false;
        config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::OFF);
    } else if (preset == "mvp") {
        // Day 1-4 baseline: basic Froxel fog without temporal stabilization,
        // depth-aware composite, or independent shadow temporal filtering.
        // Also disables Probe GI injection and VRC to represent the true MVP.
        config.volumetric_fog_enabled              = true;
        config.volumetric_fog_jitter_mode          = static_cast<uint8>(EVolumetricFogJitterMode::OFF);
        config.volumetric_fog_temporal_enabled     = false;
        config.volumetric_fog_shadow_pcf_radius    = 0;
        config.volumetric_fog_reconstruction_filter_enabled  = false;
        config.volumetric_fog_probe_gi_enabled     = false;
        config.volumetric_fog_radiance_cache_enabled = false;
    } else if (preset == "halton") {
        config.volumetric_fog_enabled = true;
        config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::HALTON);
    } else if (preset == "fast_xy") {
        config.volumetric_fog_enabled = true;
        config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XY);
    } else {
        config.volumetric_fog_enabled = true;
        config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XYZ_OFFSET);
        if (preset == "no_shadows") {
            config.volumetric_fog_shadows_enabled = false;
        } else if (preset == "probe_gi") {
            config.volumetric_fog_probe_gi_enabled = true;
        } else if (preset == "probe_gi_high") {
            // Same as halton baseline, ONLY boosting Probe GI intensity for visibility.
            // All other parameters (temporal, PCF, jitter, density, shadows) identical to halton.
            config.volumetric_fog_enabled = true;
            config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::HALTON);
            config.volumetric_fog_probe_gi_enabled = true;
            config.volumetric_fog_radiance_cache_enabled = true;
            config.probe_gi_intensity = 0.6f;
            config.volumetric_fog_probe_gi_intensity = 4.0f;
        } else if (preset == "halton_nogi") {
            // Same as halton but with Probe GI and VRC disabled.
            // Used as the "no GI" baseline for fair comparison against probe_gi_high.
            config.volumetric_fog_enabled = true;
            config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::HALTON);
            config.volumetric_fog_probe_gi_enabled = false;
            config.volumetric_fog_radiance_cache_enabled = false;
        } else if (preset == "highcontrast") {
            // High-density, steep-gradient fog to amplify Jitter sampling differences.
            // The denser and more spatially varying the medium, the more the sampling
            // position within each Froxel matters, making FAST vs Halton visible.
            config.volumetric_fog_base_density          = 0.020f;
            config.volumetric_fog_height_falloff        = 0.35f;
            config.volumetric_fog_scattering_intensity  = 1.2f;
            config.volumetric_fog_directional_intensity  = 0.80f;
            config.volumetric_fog_phase_g               = 0.60f;
            config.volumetric_fog_local_volume_enabled  = true;
            config.volumetric_fog_local_volume_center   = float3(0.0f, 3.0f, 0.0f);
            config.volumetric_fog_local_volume_radius   = 8.0f;
            config.volumetric_fog_local_volume_density  = 0.025f;
            config.volumetric_fog_local_volume_edge_falloff = 3.0f;
            // Allow overriding jitter mode via MOER_FOG_JITTER env var
            // Supported: halton, fast_xy, fast_xyz, white, off
            {
                const std::string jitter_override = ReadEnvironment("MOER_FOG_JITTER");
                if (jitter_override == "halton") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::HALTON);
                } else if (jitter_override == "fast_xy") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XY);
                } else if (jitter_override == "fast_xyz") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XYZ_OFFSET);
                } else if (jitter_override == "white") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::WHITE_NOISE);
                } else if (jitter_override == "off") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::OFF);
                }
            }
        } else if (preset == "nocoverage") {
            // Simulates camera-cut or fast-rotation: temporal history is nearly invalid.
            // Low history_weight means each frame's sample matters much more, exposing
            // the spatial distribution difference between Halton (correlated) and FAST
            // (decorrelated) jitter during the "rebuild" period before convergence.
            config.volumetric_fog_base_density          = 0.020f;
            config.volumetric_fog_height_falloff        = 0.35f;
            config.volumetric_fog_scattering_intensity  = 1.2f;
            config.volumetric_fog_directional_intensity  = 0.80f;
            config.volumetric_fog_phase_g               = 0.60f;
            config.volumetric_fog_local_volume_enabled  = true;
            config.volumetric_fog_local_volume_center   = float3(0.0f, 3.0f, 0.0f);
            config.volumetric_fog_local_volume_radius   = 8.0f;
            config.volumetric_fog_local_volume_density  = 0.025f;
            config.volumetric_fog_local_volume_edge_falloff = 3.0f;
            // Aggressive temporal settings: low history weight = slow convergence
            config.volumetric_fog_history_weight        = 0.50f;
            config.volumetric_fog_history_motion_scale  = 0.30f;
            config.volumetric_fog_history_clamp_expansion = 0.20f;
            // Allow overriding jitter mode via MOER_FOG_JITTER env var
            {
                const std::string jitter_override = ReadEnvironment("MOER_FOG_JITTER");
                if (jitter_override == "halton") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::HALTON);
                } else if (jitter_override == "fast_xy") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XY);
                } else if (jitter_override == "fast_xyz") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::FAST_XYZ_OFFSET);
                } else if (jitter_override == "white") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::WHITE_NOISE);
                } else if (jitter_override == "off") {
                    config.volumetric_fog_jitter_mode = static_cast<uint8>(EVolumetricFogJitterMode::OFF);
                }
            }
        } else if (preset == "showcase") {
            // A presentation preset for Sponza's short, heavily exposed central aisle. These values
            // intentionally do not replace the conservative defaults used by the performance matrix.
            config.volumetric_fog_base_density          = 0.010f;
            config.volumetric_fog_ambient_intensity     = 0.12f;
            config.volumetric_fog_scattering_intensity  = 0.90f;
            config.volumetric_fog_directional_intensity = 0.75f;
            config.volumetric_fog_phase_g               = 0.45f;
            config.volumetric_fog_local_volume_enabled  = true;
            config.volumetric_fog_local_volume_center   = float3(0.0f, 2.0f, 0.0f);
            config.volumetric_fog_local_volume_radius   = 6.0f;
            config.volumetric_fog_local_volume_density  = 0.008f;
            config.volumetric_fog_local_volume_edge_falloff = 2.5f;
        }
    }
}

void VolumetricFogBenchmark::ApplyCameraPose(Camera& camera) {
    float u = 0.0f;
    if (run_frame >= effective_warmup_frames) {
        trajectory_frame = std::min(run_frame - effective_warmup_frames, k_trajectory_frames - 1u);
        u = static_cast<float>(trajectory_frame) / static_cast<float>(k_trajectory_frames - 1u);
    } else {
        trajectory_frame = 0u;
    }

    const float eased = SmoothStep(u);
    const float forward_distance = view == "sunshaft" ? 2.5f : 3.0f;
    const float pitch_rise       = view == "sunshaft" ? 16.0f : 8.0f;
    const float3 position = base_position + base_front * (forward_distance * eased);
    const float yaw   = base_yaw;
    const float pitch = base_pitch + pitch_rise * eased;

    camera.Initialize(position, yaw, pitch, base_fov, base_aspect, base_near, base_far);
}

bool VolumetricFogBenchmark::IsCaptureTrajectoryFrame(uint frame) const noexcept {
    // GIF mode: capture every trajectory frame for animation
    if (ReadEnvironment("MOER_FOG_GIF_MODE") == "1") {
        return true;
    }
    return frame == 0u || frame == 22u || frame == 45u || frame == 67u || frame == 89u;
}

void VolumetricFogBenchmark::WriteTrajectoryRow(const Camera& camera) {
    if (!trajectory_stream || run_frame < effective_warmup_frames) {
        return;
    }
    const float u = static_cast<float>(trajectory_frame) / static_cast<float>(k_trajectory_frames - 1u);
    trajectory_stream << preset << ',' << run_frame << ',' << trajectory_frame << ','
                      << std::fixed << std::setprecision(6) << u << ','
                      << camera.GetPosition().x << ',' << camera.GetPosition().y << ','
                      << camera.GetPosition().z << ',' << camera.GetYaw() << ',' << camera.GetPitch() << ','
                      << (IsCaptureTrajectoryFrame(trajectory_frame) ? 1 : 0) << '\n';
}

void VolumetricFogBenchmark::BeginFrame(Camera& camera, RasterConfig& config, uint2 resolution) {
    if (!enabled) {
        return;
    }
    if (!initialized) {
        Initialize(camera, config, resolution);
        if (!enabled) {
            return;
        }
    }

    ApplyPreset(config);
    ApplyCameraPose(camera);
    WriteTrajectoryRow(camera);

    capture_queued = false;
    close_after_capture = false;
    pending_capture_path.clear();
    if (run_frame >= effective_warmup_frames && IsCaptureTrajectoryFrame(trajectory_frame)) {
        std::ostringstream file_name;
        file_name << "frame_" << std::setw(3) << std::setfill('0') << trajectory_frame << ".png";
        pending_capture_path = preset_output_dir / file_name.str();
        close_after_capture = trajectory_frame == k_trajectory_frames - 1u;
        // In GIF mode, only close at the very last frame
        if (ReadEnvironment("MOER_FOG_GIF_MODE") == "1") {
            close_after_capture = trajectory_frame == k_trajectory_frames - 1u;
        }
    }
}

void VolumetricFogBenchmark::QueueCapture(CommandList& cmd_list, const TextureRef& texture) {
    if (!enabled || pending_capture_path.empty() || !texture) {
        return;
    }
    if (texture->GetFormat() != PF_R8G8B8A8_UNORM) {
        LOG_ERROR(
            "[FogBenchmark] Capture skipped: expected PF_R8G8B8A8_UNORM, actual format={}.",
            static_cast<int>(texture->GetFormat())
        );
        return;
    }

    capture_resolution = texture->GetExtent().xy;
    readback_pixels.resize(texture->GetMipByteSize(0u));
    cmd_list.CopyFrom(texture->GetView(), readback_pixels, "Fog Benchmark Tonemapped Readback");
    capture_queued = true;
}

void VolumetricFogBenchmark::WriteCapturePng() {
    for (size_t pixel = 0; pixel + 3 < readback_pixels.size(); pixel += 4) {
        readback_pixels[pixel + 0] = LinearByteToSrgb(readback_pixels[pixel + 0]);
        readback_pixels[pixel + 1] = LinearByteToSrgb(readback_pixels[pixel + 1]);
        readback_pixels[pixel + 2] = LinearByteToSrgb(readback_pixels[pixel + 2]);
    }

    const int result = stbi_write_png(
        pending_capture_path.string().c_str(),
        static_cast<int>(capture_resolution.x),
        static_cast<int>(capture_resolution.y),
        4,
        readback_pixels.data(),
        static_cast<int>(capture_resolution.x * 4u)
    );
    if (result != 0) {
        LOG_INFO(
            "[FogBenchmark] Captured preset='{}' trajectory_frame={} path='{}'.",
            preset,
            trajectory_frame,
            pending_capture_path.string()
        );
    } else {
        LOG_ERROR("[FogBenchmark] Failed to write '{}'.", pending_capture_path.string());
    }
}

void VolumetricFogBenchmark::EndFrame(CommandQueue& gfx_queue) {
    if (!enabled || !initialized) {
        return;
    }

    if (capture_queued) {
        // Readback storage is not populated until the Vulkan queue fence completes.
        // These five capture frames are excluded from performance aggregation.
        gfx_queue.Sync();
        WriteCapturePng();
        readback_pixels.clear();
    }

    if (close_after_capture) {
        trajectory_stream.flush();
        LOG_INFO(
            "[FogBenchmark] Completed preset='{}' after {} warmup + {} trajectory frames.",
            preset,
            effective_warmup_frames,
            k_trajectory_frames
        );
        WindowContext::RequestClose(WindowContext::GetMainWindow());
        return;
    }

    ++run_frame;
}

} // namespace Moer::Render::Raster
