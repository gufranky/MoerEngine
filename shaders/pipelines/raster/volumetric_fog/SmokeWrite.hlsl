// Day-1 RHI smoke test: write a deterministic XYZ gradient into a 3D UAV.

[[vk::binding(0, 0)]] RWTexture3D<float4> volume_texture;

[numthreads(4, 4, 4)]
void main(uint3 dispatch_thread_id : SV_DispatchThreadID) {
    uint width;
    uint height;
    uint depth;
    volume_texture.GetDimensions(width, height, depth);

    if (any(dispatch_thread_id >= uint3(width, height, depth))) {
        return;
    }

    float3 uvw = (float3(dispatch_thread_id) + 0.5) / float3(width, height, depth);
    volume_texture[dispatch_thread_id] = float4(uvw, 1.0);
}
