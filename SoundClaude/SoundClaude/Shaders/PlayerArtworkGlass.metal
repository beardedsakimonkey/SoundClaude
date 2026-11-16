#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Signed distance to the rounded rect spanning `0...size`, swept along `shift`.
static float sweptRoundedRectDistance(float2 point, float2 size, float cornerRadius, float2 shift) {
    float2 halfSize = size * 0.5;
    float radius = min(cornerRadius, min(halfSize.x, halfSize.y));
    float2 b = halfSize - radius;
    float2 p = point - halfSize;
    float2 v = shift;
    // Mirror so the sweep always heads toward +x, +y.
    if (v.x < 0.0) { p.x = -p.x; v.x = -v.x; }
    if (v.y < 0.0) { p.y = -p.y; v.y = -v.y; }

    // The corner centers sweep out a hexagon; the corner radius rounds it.
    float2 vertices[6] = {
        float2(-b.x, -b.y), float2(b.x, -b.y), float2(b.x, -b.y) + v,
        float2(b.x, b.y) + v, float2(-b.x, b.y) + v, float2(-b.x, b.y)
    };
    float nearest = 1e20;
    bool inside = true;
    for (int i = 0; i < 6; i++) {
        float2 edge = vertices[(i + 1) % 6] - vertices[i];
        float2 w = p - vertices[i];
        float2 offset = w - edge * saturate(dot(w, edge) / max(dot(edge, edge), 1e-6));
        nearest = min(nearest, dot(offset, offset));
        inside = inside && (edge.x * w.y - edge.y * w.x >= 0.0);
    }
    return (inside ? -sqrt(nearest) : sqrt(nearest)) - radius;
}

// The nearest point at least `inset` inside the rounded rect spanning `0...size`.
static float2 insideRoundedRect(float2 point, float2 size, float cornerRadius, float inset) {
    float radius = min(cornerRadius, min(size.x, size.y) * 0.5);
    float2 cornerCenter = clamp(point, float2(radius), size - radius);
    float2 offset = point - cornerCenter;
    float limit = max(radius - inset, 0.0);
    float offsetLength = length(offset);
    return offsetLength > limit ? cornerCenter + offset * (limit / max(offsetLength, 0.001)) : point;
}

// The slab's side, seen when the cover turns or leans: the face swept along `slabShift`, in
// points. The print's edge colors run straight back through the side, which is shaded one even
// tone, as a surface turned away from the light: `shade` sets how dark. A gradient toward the
// back reads as blur.
static half4 slabEdge(float2 position, float2 local, SwiftUI::Layer layer, float2 size, float cornerRadius, float2 slabShift, float shade, float pixelScale) {
    float shiftLength = length(slabShift);
    if (shiftLength < 0.001) return half4(0.0h);
    float hull = sweptRoundedRectDistance(local, size, cornerRadius, slabShift);
    // Antialias across one device pixel rather than one point, which keeps a thin side crisp.
    float coverage = saturate(0.5 - hull * pixelScale);
    if (coverage <= 0.0) return half4(0.0h);

    // Extend the face's nearest edge color, softened along the edge so single
    // pixels of the print don't streak across the side.
    float2 layerOrigin = position - local;
    float2 nearest = clamp(local, float2(0.0), size);
    float2 along = float2(-slabShift.y, slabShift.x) * (1.5 / shiftLength);
    half4 sample = 0.5h * layer.sample(layerOrigin + insideRoundedRect(nearest, size, cornerRadius, 1.5));
    sample += 0.25h * layer.sample(layerOrigin + insideRoundedRect(nearest - along, size, cornerRadius, 1.5));
    sample += 0.25h * layer.sample(layerOrigin + insideRoundedRect(nearest + along, size, cornerRadius, 1.5));
    half3 color = sample.rgb / max(sample.a, 0.001h);

    color *= half(1.0 - saturate(shade) * 0.725);
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
    float specularStrength,
    float specularSoftness,
    float rotation,
    float2 tilt,
    float2 origin,
    float2 slabShift,
    float slabShade,
    float pixelScale
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

    // The artwork brings its own antialiased silhouette.
    half faceAlpha = original.a;
    half4 edge = faceAlpha < 1.0h
        ? slabEdge(position, local, layer, size, cornerRadius, slabShift, slabShade, pixelScale)
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

    // The glass plane: `rotation` turns it about the vertical, and `tilt` leans it further,
    // toward any side. Together they are the sideways part of its normal.
    float2 light = float2(cos(lightAngle), sin(lightAngle));
    float3 lightDirection = normalize(float3(light * 0.45, 1.0));
    float2 lean = float2(sin(rotation), 0.0) + tilt;
    float sine = min(length(lean), 0.99);
    float cosine = sqrt(1.0 - sine * sine);
    // The plane turns about the in-plane axis square to its lean.
    float2 axis = sine > 0.0001 ? float2(-lean.y, lean.x) / length(lean) : float2(0.0, 1.0);
    float3 surfaceNormal = float3(axis.y * sine, -axis.x * sine, cosine);

    // The rim is lit from wherever the light sits relative to the leaning plane, so its
    // highlight travels around the edge as the cover turns.
    // The lean counts for half, which keeps a turned cover's side edge from outshining the rest.
    float2 rimLight = (lightDirection.xy - surfaceNormal.xy * (0.5 * lightDirection.z)) / length(lightDirection.xy);
    // Shorten rather than clamp the result: clamping flattens a whole edge to full brightness,
    // which then drops off sharply around the corner.
    rimLight /= max(length(rimLight), 1.0);
    float facing = dot(normal, rimLight);
    float highlight = pow(max(facing, 0.0), 3.0);
    float counterlight = pow(max(-facing, 0.0), 5.0);
    float lip = exp(-pow((depth - lipPosition) / max(lipWidth, 0.001), 2.0));
    float caustic = exp(-pow((depth - 4.0) / 1.5, 2.0));
    color *= half(1.0 - edgeDarkening * rim * (1.0 - highlight));
    // The lip glints hottest where it squarely faces the light.
    float reflection = reflectionStrength * lip
        * (0.12 + 0.48 * highlight + 0.3 * pow(highlight, 4.0) + 0.24 * counterlight)
        + caustic * counterlight * causticStrength;

    // A fixed light above and to the left reflects off the rotating glass plane.
    // A finite eye position gives the reflection a soft local highlight.
    float2 facePosition = (local - center) / max(min(size.x, size.y), 1.0);
    float along = dot(axis, facePosition);
    float3 surfacePosition = float3(
        facePosition * cosine + axis * along * (1.0 - cosine),
        (axis.x * facePosition.y - axis.y * facePosition.x) * sine
    );
    float3 viewDirection = normalize(float3(0.0, 0.0, 2.5) - surfacePosition);
    float3 halfway = normalize(lightDirection + viewDirection);
    float exponent = 2.0 / pow(max(specularSoftness, 0.02), 2.0);
    float specular = pow(max(dot(surfaceNormal, halfway), 0.0), exponent);
    reflection += specularStrength * specular;
    color = mix(color, half3(1.0), half(saturate(reflection)));
    half4 face = half4(color * faceAlpha, faceAlpha);
    return face + edge * (1.0h - face.a);
}
