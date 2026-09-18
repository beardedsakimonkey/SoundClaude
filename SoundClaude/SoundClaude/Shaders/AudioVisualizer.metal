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
    if (viewWidth <= 0.0) {
        return float4(0.0);
    }
    // Fit all 64 bands on each side at every window width, preserving the gap ratio.
    const float bandCount = 64.0;
    float barStride = viewWidth / (2.0 * bandCount);
    float barWidth = barStride * (10.0 / 12.0);
    float centeredX = (uv.x - 0.5) * viewWidth;
    float x = abs(centeredX);
    float y = abs(uv.y - 0.5);
    float bandPosition = x / barStride;
    // Take derivatives before mirroring to keep edge smoothing stable at the center.
    float horizontalEdgeWidth = fwidth(centeredX);
    float verticalEdgeWidth = fwidth(uv.y);
    float pointsPerUV = horizontalEdgeWidth / verticalEdgeWidth;
    if (bandPosition >= bandCount) {
        return float4(0.0);
    }
    uint bandIndex = (uint)bandPosition;
    float amplitude = saturate(bands[bandIndex]);
    float barPosition = fract(bandPosition) * barStride;
    float height = (0.035 + amplitude * 0.86) * 0.5;
    // Measure both axes in points so the mirrored ends stay circular at any aspect ratio.
    float halfWidth = barWidth * 0.5;
    float radius = min(halfWidth, height * pointsPerUV);
    float2 capPosition = float2(
        max(abs(barPosition - barStride * 0.5) - (halfWidth - radius), 0.0),
        max((y - height) * pointsPerUV + radius, 0.0)
    );
    float distance = length(capPosition) - radius;
    float fill = 1.0 - smoothstep(
        -horizontalEdgeWidth * 0.5, horizontalEdgeWidth * 0.5, distance
    );
    // Fade the cap into the bar over one bar width, mirrored in the reflection.
    float capDepth = max((height - y) * pointsPerUV, 0.0);
    float capFalloff = 1.0 - smoothstep(0.0, barWidth, capDepth);

    float bodyAlpha = pow(amplitude, 3.) * amplitude;
    // Limit peak brightness before the fade so saturation cannot flatten it.
    float capAlpha = saturate(bodyAlpha + amplitude * 9.0);
    float alpha = fill * mix(bodyAlpha, capAlpha, capFalloff);
    float column = float(bandIndex) + (centeredX < 0.0 ? 64.0 : 0.0);
    float phase = fract(sin(column * 127.1 + 311.7) * 43758.5453);
    float speed = mix(1.2, 2.4, fract(sin(column * 269.5 + 183.3) * 43758.5453));
    float pulse = 0.5 + 0.5 * sin(elapsedTime * speed + phase * 6.28);
    // brightness pulse
    // alpha *= mix(0.65, 1.0, pulse);

    if (uv.y < 0.5) {
        float reflectionFade = 1.0 - smoothstep(0.0, 0.5, y);
        // alpha *= 0.45 * reflectionFade;
    }
    float3 accent = accentColor.rgb;
    float localX = (barPosition - barStride * 0.5) / barWidth;
    float leftToRight = saturate(0.5 + (centeredX < 0.0 ? localX : -localX));
    // Center the artwork across the full view, with its top at the top of the view.
    float2 artworkUV = float2(uv.x, 1.0 - uv.y);
    // Bend the artwork across each flute, with stronger refraction at its edges.
    // Strength is measured in bar widths so it stays consistent as the view resizes.
    const float fluteStrength = 0.5;
    float fluteSlope = (1.-leftToRight) * 2.0 - 1.0;
    artworkUV.x += fluteSlope * abs(fluteSlope) * fluteStrength * barWidth / viewWidth;
    float viewAspect = viewWidth / pointsPerUV;
    float artworkAspect = float(artwork.get_width()) / float(artwork.get_height());
    float2 cropScale = float2(
        min(viewAspect / artworkAspect, 1.0),
        min(artworkAspect / viewAspect, 1.0)
    );
    const float artworkScale = 1.0;
    artworkUV = (artworkUV - 0.5) * cropScale / artworkScale + 0.5;
    constexpr sampler artworkSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 artworkColor = artwork.sample(artworkSampler, artworkUV).rgb;
    // Screen the artwork with itself so the pulse brightens its existing colors.
    // float3 screenedArtwork = 1.0 - (1.0 - artworkColor) * (1.0 - artworkColor);
    // artworkColor = mix(artworkColor, screenedArtwork, saturate(pulse - 0.5) * pulse);

    // Texture sampling supplies encoded sRGB; blend in OKLab, then encode again.
    float3 color = (mix((accent), (artworkColor), 0.4));

    color *= (1. - leftToRight*leftToRight*.4);

    // Core Animation composites the drawable using premultiplied alpha.
    return float4(color * alpha, alpha);
}
