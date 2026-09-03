#include <metal_stdlib>
using namespace metal;

struct RasterData {
    float4 position [[position]];
    float2 uv;
};

struct VisualizerUniforms {
    float2 resolution;
    float time;
    float energy;
};

vertex RasterData visualizerVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0),
    };
    RasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

fragment float4 visualizerFragment(
    RasterData input [[stage_in]],
    constant float *bands [[buffer(0)]],
    constant VisualizerUniforms &uniforms [[buffer(1)]]
) {
    float2 uv = input.uv;
    float bandPosition = saturate(uv.x) * 64.0;
    uint bandIndex = min((uint)bandPosition, 63u);
    float amplitude = saturate(bands[bandIndex]);
    float barPosition = fract(bandPosition);
    float barMask = 1.0 - smoothstep(
        0.36,
        0.47,
        abs(barPosition - 0.5)
    );
    float height = 0.035 + amplitude * 0.86;
    float fill = barMask * (
        1.0 - smoothstep(height, height + 0.012, uv.y)
    );
    float cap = barMask * exp(-70.0 * abs(uv.y - height));

    float3 low = float3(1.0, 0.20, 0.05);
    float3 high = float3(0.55, 0.18, 1.0);
    float3 accent = mix(low, high, uv.x);
    float3 background = float3(0.018, 0.023, 0.05);
    background += accent * uniforms.energy * 0.025 * (1.0 - uv.y);
    float3 color = background;
    color += accent * fill * (0.10 + amplitude * 0.58);
    color += accent * cap * (0.20 + amplitude * 0.80);
    return float4(color, 1.0);
}
