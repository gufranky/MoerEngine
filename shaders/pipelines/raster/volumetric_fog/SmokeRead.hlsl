// Day-1 RHI smoke test: sample the 3D SRV and write representative slices into a 2D UAV.

[[vk::binding(0, 0)]] Texture3D<float4>   volume_texture;
[[vk::binding(1, 0)]] RWTexture2D<float4> debug_output;

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

    uint3 load_coord = uint3(
        min(dispatch_thread_id.x * volume_width / output_width, volume_width - 1),
        min(dispatch_thread_id.y * volume_height / output_height, volume_height - 1),
        min((dispatch_thread_id.x + dispatch_thread_id.y) * volume_depth /
                max(output_width + output_height - 2, 1),
            volume_depth - 1)
    );
    debug_output[dispatch_thread_id.xy] = volume_texture.Load(int4(load_coord, 0));
}
