#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Signed distance to a rounded rect spanning `minX...maxX` horizontally and `0...height`.
static float roundedRectDistance(float2 point, float minX, float maxX, float height, float cornerRadius) {
    float2 halfSize = float2(maxX - minX, height) * 0.5;
    float radius = min(cornerRadius, min(halfSize.x, halfSize.y));
    float2 q = abs(point - float2(minX, 0) - halfSize) - (halfSize - radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// The slab's side, seen when the cover turns: the face swept `slabShift` points sideways.
// The layer holds artwork past the face, so the side shows the artwork continuing
// beyond the face's edge, darkened toward the back.
static half4 slabEdge(float2 position, float2 local, float faceDistance, SwiftUI::Layer layer, float2 size, float cornerRadius, float slabShift, float2 slabDarkening) {
    if (slabShift == 0.0) return half4(0.0h);
    float hull = roundedRectDistance(local, min(slabShift, 0.0), size.x + max(slabShift, 0.0), size.y, cornerRadius);
    float coverage = saturate(0.5 - hull);
    if (coverage <= 0.0) return half4(0.0h);

    half4 sample = layer.sample(position);
    half3 color = sample.rgb / max(sample.a, 0.001h);
    float back = saturate(faceDistance / abs(slabShift));
    color *= half(1.0 - mix(slabDarkening.x, slabDarkening.y, back));
    return half4(color, 1.0h) * (sample.a * half(coverage));
}

// A shallow glass lens over the cover itself. No time input or idle render loop.
[[ stitchable ]] half4 playerArtworkGlass(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float cornerRadius,
    float rimWidth,
    float lightAngle,
    float edgeDarkening,
    float lipPosition,
    float lipWidth,
    float reflectionStrength,
    float causticStrength,
    float sweepStrength,
    float sweepWidth,
    float sweepPosition,
    float2 origin,
    float masksFace,
    float slabShift,
    float2 slabDarkening
) {
    // `origin` places the face inside a layer padded to make room for the slab edge.
    float2 local = position - origin;
    half4 original = layer.sample(position);

    float2 center = size * 0.5;
    float radius = min(cornerRadius, min(center.x, center.y));
    float2 p = local - center;
    float2 q = abs(p) - (center - radius);
    float2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    float distance = outsideLength + min(max(q.x, q.y), 0.0) - radius;
    float depth = max(-distance, 0.0);

    // Unclipped artwork is masked to the face here; clipped artwork brings its own silhouette.
    half faceAlpha = masksFace > 0.0 ? original.a * half(saturate(0.5 - distance)) : original.a;
    half4 edge = faceAlpha < 1.0h
        ? slabEdge(position, local, distance, layer, size, cornerRadius, slabShift, slabDarkening)
        : half4(0.0h);
    if (faceAlpha <= 0.0h) return edge;

    // Rounded-rectangle normal, including the straight sides.
    float2 normal = outsideLength > 0.001
        ? outside / max(outsideLength, 0.001)
        : (q.x > q.y ? float2(1, 0) : float2(0, 1));
    normal *= sign(p);

    // Rim shading falls to zero within the configured width.
    float rim = 1.0 - smoothstep(0.0, max(rimWidth, 0.001), depth);
    // Work in straight RGB, then restore the original antialiased silhouette.
    half3 color = original.rgb / max(original.a, 0.001h);

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
    float2 uv = local / max(size, float2(1.0));
    float sweep = uv.y + 0.45 * uv.x - sweepPosition;
    reflection += sweepStrength * exp(-pow(sweep / max(sweepWidth, 0.001), 2.0));
    color = mix(color, half3(1.0), half(saturate(reflection)));
    half4 face = half4(color * faceAlpha, faceAlpha);
    return face + edge * (1.0h - face.a);
}
