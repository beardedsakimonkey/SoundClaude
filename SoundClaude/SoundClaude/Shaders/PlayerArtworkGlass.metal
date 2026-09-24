#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// A shallow glass lens over the cover itself. No time input or idle render loop.
[[ stitchable ]] half4 playerArtworkGlass(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float cornerRadius,
    float rimWidth,
    float refraction,
    float chromaticDispersion,
    float lightAngle,
    float edgeDarkening,
    float lipPosition,
    float lipWidth,
    float reflectionStrength,
    float causticStrength,
    float sweepStrength,
    float sweepWidth,
    float sweepPosition
) {
    half4 original = layer.sample(position);
    if (original.a <= 0.0h) return original;

    float2 center = size * 0.5;
    float radius = min(cornerRadius, min(center.x, center.y));
    float2 p = position - center;
    float2 q = abs(p) - (center - radius);
    float2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    float distance = outsideLength + min(max(q.x, q.y), 0.0) - radius;
    float depth = max(-distance, 0.0);

    // Rounded-rectangle normal, including the straight sides.
    float2 normal = outsideLength > 0.001
        ? outside / max(outsideLength, 0.001)
        : (q.x > q.y ? float2(1, 0) : float2(0, 1));
    normal *= sign(p);

    // Refraction falls to zero within the configured rim. Inward sampling
    // avoids pulling transparent pixels from outside the clipped cover.
    float rim = 1.0 - smoothstep(0.0, max(rimWidth, 0.001), depth);
    float bend = rim * rim * refraction;
    float dispersion = chromaticDispersion * rim * rim;
    half4 red = layer.sample(position - normal * (bend + dispersion));
    half4 green = layer.sample(position - normal * bend);
    half4 blue = layer.sample(position - normal * max(bend - dispersion, 0.0));
    // Work in straight RGB, then restore the original antialiased silhouette.
    half3 color = half3(
        red.r / max(red.a, 0.001h),
        green.g / max(green.a, 0.001h),
        blue.b / max(blue.a, 0.001h)
    );

    float2 light = float2(cos(lightAngle), sin(lightAngle));
    float facing = dot(normal, light);
    float highlight = pow(max(facing, 0.0), 3.0);
    float counterlight = pow(max(-facing, 0.0), 5.0);
    float lip = exp(-pow((depth - lipPosition) / max(lipWidth, 0.001), 2.0));
    float caustic = exp(-pow((depth - 4.0) / 1.5, 2.0));
    color *= half(1.0 - edgeDarkening * rim * (1.0 - highlight));
    float reflection = reflectionStrength * lip * (0.12 + 0.48 * highlight + 0.24 * counterlight)
        + caustic * counterlight * causticStrength;

    // Broad, faint reflection across the face.
    float2 uv = position / max(size, float2(1.0));
    float sweep = uv.y + 0.45 * uv.x - sweepPosition;
    reflection += sweepStrength * exp(-pow(sweep / max(sweepWidth, 0.001), 2.0));
    color = mix(color, half3(1.0), half(saturate(reflection)));
    return half4(color * original.a, original.a);
}
