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

// Signed distance to the rounded rect spanning `0...size`, with its outward normal,
// including along the straight sides.
static float roundedRectDistance(float2 point, float2 size, float cornerRadius, thread float2 &normal) {
    float2 halfSize = size * 0.5;
    float radius = min(cornerRadius, min(halfSize.x, halfSize.y));
    float2 p = point - halfSize;
    float2 q = abs(p) - (halfSize - radius);
    float2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    normal = (outsideLength > 0.001
        ? outside / outsideLength
        : (q.x > q.y ? float2(1, 0) : float2(0, 1))) * sign(p);
    return outsideLength + min(max(q.x, q.y), 0.0) - radius;
}

// The slab's side, seen when the cover turns or leans: the face swept along `slabShift`, in
// points. Each point finds the wall it sees, the nearest one along the sweep, and takes the
// print's color where that wall meets the face, so colors run straight back through the side.
// The wall is lit by its own facing: straight walls hold one even tone, since a gradient
// toward the back reads as blur, while the rounded corners turn through the light and carry
// a glint around them. `shade` sets how dark a wall turned from the light is.
static half4 slabEdge(float2 position, float2 local, SwiftUI::Layer layer, float2 size, float cornerRadius, float2 slabShift, float shade, float glint, float2 rimLight, float pixelScale) {
    float shiftLength = length(slabShift);
    if (shiftLength < 0.001) return half4(0.0h);
    float hull = sweptRoundedRectDistance(local, size, cornerRadius, slabShift);
    // Antialias across one device pixel rather than one point, which keeps a thin side crisp.
    float coverage = saturate(0.5 - hull * pixelScale);
    if (coverage <= 0.0) return half4(0.0h);

    // March back along the sweep to the wall in front: the first depth at which the face's
    // outline reaches this point. The distance bounds each step, so it never overshoots.
    float2 wallNormal = float2(0.0);
    float t = 0.0;
    for (int i = 0; i < 8; i++) {
        float d = roundedRectDistance(local - slabShift * t, size, cornerRadius, wallNormal);
        if (d <= 0.01) break;
        t += d / shiftLength;
    }
    float2 wallPoint = local - slabShift * saturate(t);
    roundedRectDistance(wallPoint, size, cornerRadius, wallNormal);

    // The print's color where the wall meets the face, softened along the edge so single
    // pixels of the print don't streak across the side.
    float2 layerOrigin = position - local;
    float2 along = float2(-wallNormal.y, wallNormal.x) * 1.5;
    half4 sample = 0.5h * layer.sample(layerOrigin + insideRoundedRect(wallPoint, size, cornerRadius, 1.5));
    sample += 0.25h * layer.sample(layerOrigin + insideRoundedRect(wallPoint - along, size, cornerRadius, 1.5));
    sample += 0.25h * layer.sample(layerOrigin + insideRoundedRect(wallPoint + along, size, cornerRadius, 1.5));
    half3 color = sample.rgb / max(sample.a, 0.001h);

    // A wall facing the light keeps more of its color than one turned away.
    float lit = saturate(dot(wallNormal, rimLight));
    color *= half(1.0 - saturate(shade) * 0.725 * (1.0 - 0.45 * lit));
    // The glint sits where a wall's normal splits the light and the view, which looks along
    // the sweep: on a straight wall it holds steady, around a corner it travels as the cover moves.
    float2 split = rimLight + slabShift / shiftLength;
    float2 halfway = split / max(length(split), 0.001);
    float sparkle = glint * pow(saturate(dot(wallNormal, halfway)), 12.0);
    color += (1.0h - color) * half(saturate(sparkle));
    return half4(color, 1.0h) * (sample.a * half(coverage));
}

// The artwork in straight RGB at `local`, kept just inside the face.
static half3 faceColor(SwiftUI::Layer layer, float2 layerOrigin, float2 local, float2 size, float cornerRadius) {
    half4 sample = layer.sample(layerOrigin + insideRoundedRect(local, size, cornerRadius, 0.75));
    return sample.rgb / max(sample.a, 0.001h);
}

// Thin-film interference: a soap-bubble hue that cycles as the optical path `t` changes.
static float3 thinFilm(float t) {
    return 0.5 + 0.5 * cos(6.2831853 * (t + float3(0.0, 0.33, 0.67)));
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
    float specularStrength,
    float specularSoftness,
    float rotation,
    float2 tilt,
    float2 origin,
    float2 slabShift,
    float slabShade,
    float slabGlint,
    float pixelScale,
    float refractionWidth,
    float refractionStrength,
    float dispersion,
    float iridescence,
    float sheenStrength,
    float sheenPosition
) {
    // `origin` places the face inside a layer padded to make room for the slab edge.
    float2 local = position - origin;
    half4 original = layer.sample(position);

    float2 center = size * 0.5;
    float2 normal;
    float distance = roundedRectDistance(local, size, cornerRadius, normal);
    float depth = max(-distance, 0.0);

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

    // The artwork brings its own antialiased silhouette.
    half faceAlpha = original.a;
    half4 edge = faceAlpha < 1.0h
        ? slabEdge(position, local, layer, size, cornerRadius, slabShift, slabShade, slabGlint, rimLight, pixelScale)
        : half4(0.0h);
    if (faceAlpha <= 0.0h) return edge;

    // Rim shading falls to zero within the configured width.
    float rim = 1.0 - smoothstep(0.0, max(rimWidth, 0.001), depth);
    // Work in straight RGB, then restore the original antialiased silhouette.
    half3 color = original.rgb / max(original.a, 0.001h);

    // The rounded bevel bends the print beneath it: each point near the edge shows the artwork
    // from a little further in, squeezing the outer band as if it wrapped over the edge. Each
    // channel bends by a different amount, which fringes the edge like a prism.
    float bevelWidth = max(refractionWidth, 0.001);
    float bevel = 1.0 - saturate(depth / bevelWidth);
    // Stay short of folding the image back on itself, whose slope would reach zero.
    float bend = min(refractionStrength, bevelWidth * 0.3) * bevel * bevel;
    if (bend > 0.02) {
        float2 layerOrigin = position - local;
        float2 inward = -normal * bend;
        float spread = saturate(dispersion);
        color = half3(
            faceColor(layer, layerOrigin, local + inward * (1.0 - 0.5 * spread), size, cornerRadius).r,
            faceColor(layer, layerOrigin, local + inward, size, cornerRadius).g,
            faceColor(layer, layerOrigin, local + inward * (1.0 + 0.5 * spread), size, cornerRadius).b
        );
    }

    float facing = dot(normal, rimLight);
    float highlight = pow(max(facing, 0.0), 3.0);
    float counterlight = pow(max(-facing, 0.0), 5.0);
    float lip = exp(-pow((depth - lipPosition) / max(lipWidth, 0.001), 2.0));
    color *= half(1.0 - edgeDarkening * rim * (1.0 - highlight));
    // The lip glints hottest where it squarely faces the light.
    float lipReflection = reflectionStrength * lip
        * (0.12 + 0.48 * highlight + 0.3 * pow(highlight, 4.0) + 0.24 * counterlight);

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
    float specular = specularStrength * pow(max(dot(surfaceNormal, halfway), 0.0), exponent);

    // A long softbox beside the light, seen in the glass: a band in the reflected view
    // direction, so it slides across the face as the cover turns or leans.
    float3 reflected = reflect(-viewDirection, surfaceNormal);
    float band = dot(reflected.xy, light) - sheenPosition;
    float sheen = sheenStrength
        * smoothstep(0.11, 0.05, abs(band))
        * (0.55 + 0.45 * smoothstep(-0.11, 0.11, band));

    // A thin coating tints the reflections. Its hue follows the viewing angle, so the
    // colors travel around the rim and through the band as the cover moves.
    float grazing = 1.0 - saturate(dot(surfaceNormal, viewDirection));
    float leanTowardLight = dot(lean, light);
    float film = saturate(iridescence);
    float3 lipTint = mix(float3(1.0), thinFilm(0.55 * facing + 1.2 * leanTowardLight + 0.1), film);
    float3 bandTint = mix(float3(1.0), thinFilm(2.0 * band + 3.0 * grazing + 0.45), film * 0.7);
    float3 reflection = saturate(lipReflection * lipTint + specular * bandTint + sheen * bandTint);
    // Screen the reflections over the print, as light added by the glass's surface.
    color += (1.0h - color) * half3(reflection);
    half4 face = half4(color * faceAlpha, faceAlpha);
    return face + edge * (1.0h - face.a);
}
