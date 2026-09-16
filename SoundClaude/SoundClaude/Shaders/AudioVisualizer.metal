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
    constant float4 &accentColor [[buffer(2)]],
    constant float &elapsedTime [[buffer(3)]],
    texture2d<float> artwork [[texture(0)]]
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
    float cap = fill * exp(-480.0 * abs(y - height));

    float alpha = saturate(
        fill * (0.0 + amplitude * 0.68)
        + cap * (amplitude * 9.0)
    );
    float column = float(bandIndex) + (centeredX < 0.0 ? 64.0 : 0.0);
    float phase = fract(sin(column * 127.1 + 311.7) * 43758.5453);
    float speed = mix(1.2, 2.4, fract(sin(column * 269.5 + 183.3) * 43758.5453));
    float pulse = 0.5 + 0.5 * sin(elapsedTime * speed + phase * 6.28);
    alpha *= mix(0.45, 1.0, pulse);

    if (uv.y < 0.5) {
        float reflectionFade = 1.0 - smoothstep(0.0, 0.5, y);
        alpha *= 0.45 * reflectionFade;
    }
    float3 accent = accentColor.rgb;
    // Fill the upper half with artwork, then mirror the same image below it.
    float2 artworkUV = float2(uv.x, 1.0 - 2.0 * y);
    float viewAspect = viewWidth / (pointsPerUV * 0.5);
    float artworkAspect = float(artwork.get_width()) / float(artwork.get_height());
    float2 cropScale = float2(
        min(viewAspect / artworkAspect, 1.0),
        min(artworkAspect / viewAspect, 1.0)
    );
    artworkUV = (artworkUV - 0.5) * cropScale + 0.5;
    constexpr sampler artworkSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 artworkColor = artwork.sample(artworkSampler, artworkUV).rgb;
    accent = mix(accent, artworkColor, accentColor.a);

    // Core Animation composites the drawable using premultiplied alpha.
    return float4(accent * alpha, alpha);
}
