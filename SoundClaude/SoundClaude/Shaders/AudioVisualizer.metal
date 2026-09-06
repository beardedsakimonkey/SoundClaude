#include <metal_stdlib>
using namespace metal;

struct RasterData {
    float4 position [[position]];
    float2 uv;
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
    constant float &viewWidth [[buffer(1)]]
) {
    float2 uv = input.uv;
    // Use points so bar width and spacing stay fixed across window sizes and displays.
    const float barWidth = 8.0;
    const float barSpacing = 2.0;
    const float barStride = barWidth + barSpacing;
    float x = uv.x * viewWidth;
    float bandPosition = x / barStride;
    float horizontalEdgeWidth = fwidth(x);
    if (bandPosition < 0.0 || bandPosition >= 64.0) {
        return float4(0.0);
    }
    uint bandIndex = (uint)bandPosition;
    float amplitude = saturate(bands[bandIndex]);
    float barPosition = fract(bandPosition) * barStride;
    float barMask = 1.0 - smoothstep(
        barWidth * 0.5 - horizontalEdgeWidth * 0.5,
        barWidth * 0.5 + horizontalEdgeWidth * 0.5,
        abs(barPosition - barStride * 0.5)
    );
    float height = 0.035 + amplitude * 0.86;
    float edgeWidth = fwidth(uv.y);
    float fill = barMask * (
        1.0 - smoothstep(height - edgeWidth * 0.5, height + edgeWidth * 0.5, uv.y)
    );
    float cap = barMask * exp(-140.0 * abs(uv.y - height));

    float3 low = float3(1.0, 0.20, 0.05);
    float3 high = float3(0.55, 0.18, 1.0);
    float3 accent = mix(low, high, bandPosition / 64.0);
    float alpha = saturate(
        fill * (0.10 + amplitude * 0.58)
        + cap * (0.20 + amplitude * 0.80)
    );
    // Core Animation composites the drawable using premultiplied alpha.
    return float4(accent * alpha, alpha);
}
