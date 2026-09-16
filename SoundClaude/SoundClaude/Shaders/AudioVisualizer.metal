#include <metal_stdlib>
using namespace metal;

// OKLab transforms: https://bottosson.github.io/posts/oklab/
float3 srgbToOKLab(float3 color) {
    float3 linear = select(color / 12.92, pow((color + 0.055) / 1.055, 2.4),
                           color > 0.04045);
    float3 lms = float3(
        dot(linear, float3(0.4122214708, 0.5363325363, 0.0514459929)),
        dot(linear, float3(0.2119034982, 0.6806995451, 0.1073969566)),
        dot(linear, float3(0.0883024619, 0.2817188376, 0.6299787005))
    );
    lms = pow(max(lms, 0.0), 1.0 / 3.0);
    return float3(
        dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468)),
        dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099)),
        dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660))
    );
}

float3 oklabToSRGB(float3 lab) {
    float3 lms = float3(
        lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
    );
    lms = lms * lms * lms;
    // Clamp out-of-gamut results before encoding for the non-sRGB drawable.
    float3 linear = saturate(float3(
        dot(lms, float3(4.0767416621, -3.3077115913, 0.2309699292)),
        dot(lms, float3(-1.2684380046, 2.6097574011, -0.3413193965)),
        dot(lms, float3(-0.0041960863, -0.7034186147, 1.7076147010))
    ));
    return select(linear * 12.92, 1.055 * pow(linear, 1.0 / 2.4) - 0.055,
                  linear > 0.0031308);
}

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
    // Fade the cap into the bar over one bar width, mirrored in the reflection.
    float capDepth = max((height - y) * pointsPerUV, 0.0);
    float capFalloff = 1.0 - smoothstep(0.0, barWidth, capDepth);

    float bodyAlpha = amplitude * amplitude * 0.68;
    // Limit peak brightness before the fade so saturation cannot flatten it.
    float capAlpha = saturate(bodyAlpha + amplitude * 49.0);
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
    // Lift darker accents toward a lighter tint for the dark background.
    // Apply this before artwork blending and shading to preserve their depth.
    float accentBrightness = dot(accent, float3(0.2126, 0.7152, 0.0722));
    const float minimumAccentBrightness = 0.6;
    float accentLift = saturate(
        (minimumAccentBrightness - accentBrightness) / max(1.0 - accentBrightness, 0.001)
    );
    accent = mix(accent, float3(1.0), accentLift);
    // Fill the upper half with artwork, then mirror the same image below it.
    float2 artworkUV = float2(uv.x, 1.0 - 2.0 * uv.y);
    float viewAspect = viewWidth / (pointsPerUV * 0.5);
    float artworkAspect = float(artwork.get_width()) / float(artwork.get_height());
    float2 cropScale = float2(
        min(viewAspect / artworkAspect, 1.0),
        min(artworkAspect / viewAspect, 1.0)
    );
    artworkUV = (artworkUV - 0.5) * cropScale + 0.5;
    constexpr sampler artworkSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 artworkColor = artwork.sample(artworkSampler, artworkUV).rgb;
    // Screen the artwork with itself so the pulse brightens its existing colors.
    float3 screenedArtwork = 1.0 - (1.0 - artworkColor) * (1.0 - artworkColor);
    artworkColor = mix(artworkColor, screenedArtwork, saturate(pulse - 0.5) * pulse);

    float localX = (barPosition - barStride * 0.5) / barWidth;
    float leftToRight = saturate(0.95 + (centeredX < 0.0 ? localX : localX));
    // Texture sampling supplies encoded sRGB; blend in OKLab, then encode again.
    float3 color = oklabToSRGB(mix(srgbToOKLab(accent), srgbToOKLab(artworkColor), 0.5));
    color *= (1.0 - leftToRight*.5);

    // Core Animation composites the drawable using premultiplied alpha.
    return float4(color * alpha, alpha);
}
