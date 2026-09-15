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
    constant float &viewWidth [[buffer(1)]],
    constant float4 &accentColor [[buffer(2)]]
) {
    float2 uv = input.uv;
    // Use points so bar width and spacing stay fixed across window sizes and displays.
    const float barWidth = 8.0;
    const float barSpacing = 2.0;
    const float barStride = barWidth + barSpacing;
    float centeredX = (uv.x - 0.5) * viewWidth;
    float x = abs(centeredX);
    float y = abs(uv.y - 0.5);
    float bandPosition = x / barStride;
    // Take derivatives before mirroring to keep edge smoothing stable at the center.
    float horizontalEdgeWidth = fwidth(centeredX);
    float verticalEdgeWidth = fwidth(uv.y);
    float pointsPerUV = horizontalEdgeWidth / verticalEdgeWidth;
    if (bandPosition < 0.0 || bandPosition >= 64.0) {
        return float4(0.0);
    }
    uint bandIndex = (uint)bandPosition;
    float amplitude = saturate(bands[bandIndex]);
    float barPosition = fract(bandPosition) * barStride;
    float height = (0.035 + amplitude * 0.86) * 0.5;
    // Measure both axes in points so the mirrored ends stay circular at any aspect ratio.
    float radius = barWidth * 0.5;
    float2 capPosition = float2(
        barPosition - barStride * 0.5,
        max((y - height) * pointsPerUV + radius, 0.0)
    );
    float distance = length(capPosition) - radius;
    float fill = 1.0 - smoothstep(
        -horizontalEdgeWidth * 0.5, horizontalEdgeWidth * 0.5, distance
    );
    float cap = fill * exp(-280.0 * abs(y - height));

    float alpha = saturate(
        fill * (0.10 + amplitude * 0.58)
        + cap * (0.20 + amplitude * 9.80)
    );
    float3 accent = accentColor.rgb;

    // Core Animation composites the drawable using premultiplied alpha.
    return float4(accent * alpha, alpha);
}
