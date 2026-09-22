#include <metal_stdlib>
using namespace metal;

struct RibbonRasterData {
    float4 position [[position]];
    float2 uv;
};

vertex RibbonRasterData ribbonVisualizerVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0),
    };
    RibbonRasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

// Interpolate the spectrum so the surface stays continuous between bands.
static float ribbonBand(constant float *bands, float position) {
    float index = saturate(position) * 63.0;
    uint lower = uint(index);
    float blend = smoothstep(0.0, 1.0, fract(index));
    return mix(saturate(bands[lower]), saturate(bands[min(lower + 1, 63u)]), blend);
}

fragment float4 ribbonVisualizerFragment(
    RibbonRasterData input [[stage_in]],
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

    float bass = 0.0;
    float mids = 0.0;
    float treble = 0.0;
    for (uint i = 0; i < 64; ++i) {
        float level = saturate(bands[i]);
        if (i < 16) bass += level / 16.0;
        else if (i < 44) mids += level / 28.0;
        else treble += level / 20.0;
    }
    float energy = saturate(bass * 0.5 + mids * 0.35 + treble * 0.15);
    float activity = smoothstep(0.0, 0.12, energy);
    float time = elapsedTime * 0.55;
    float x = uv.x * 2.0 - 1.0;
    // Taper the ribbon into fine threads at the sides of the view.
    float envelope = pow(max(1.0 - x * x, 0.0), 0.65);
    float spectrum = ribbonBand(bands, abs(x));
    float fold = sin(x * 4.8 - time);
    float secondaryFold = sin(x * 8.0 + time * 0.73 + 1.4);
    float ripple = sin(x * 36.0 - time * 2.1 + spectrum * 2.0);
    float center = 0.5 + envelope * (
        fold * (0.018 * activity + bass * 0.14)
        + secondaryFold * mids * 0.045
        + ripple * treble * 0.012
    );
    // Turning the sheet toward its edge produces narrow, bright folds.
    float turn = 0.5 + 0.5 * sin(x * 5.5 - time * 0.82 + 0.8);
    float halfHeight = 0.0025 + envelope * (
        0.014 * activity + bass * 0.14 + mids * 0.06 + spectrum * 0.035
    ) * mix(0.24, 1.0, turn);
    float offset = uv.y - center;
    float surface = offset / halfHeight;
    float edgeDistance = abs(offset) - halfHeight;
    float antialias = max(fwidth(edgeDistance), 0.00001);
    float fill = 1.0 - smoothstep(-antialias, antialias, edgeDistance);
    float edge = exp(-abs(edgeDistance) / max(fwidth(uv.y) * 1.3, 0.0012));
    float halo = exp(-max(edgeDistance, 0.0) / 0.012) * (1.0 - fill);

    // A rounded cross section bends the artwork most strongly at the rim.
    float crossSection = clamp(surface, -1.0, 1.0);
    float lens = sqrt(max(1.0 - crossSection * crossSection, 0.0));
    float2 artworkUV = float2(uv.x, 1.0 - uv.y);
    float aspect = abs(dfdx(uv.x) / dfdy(uv.y));
    float artworkAspect = float(artwork.get_width()) / float(artwork.get_height());
    float viewAspect = 1.0 / max(aspect, 0.00001);
    float2 cropScale = float2(
        min(viewAspect / artworkAspect, 1.0),
        min(artworkAspect / viewAspect, 1.0)
    );
    artworkUV += float2(fold * lens * 0.045, crossSection * 0.12 + lens * 0.035);
    artworkUV = (artworkUV - 0.5) * cropScale + 0.5;
    constexpr sampler artworkSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 artworkColor = artwork.sample(artworkSampler, artworkUV).rgb;
    float3 accent = accentColor.rgb;
    float3 glassColor = mix(artworkColor, artworkColor, 0.72 * saturate(accentColor.a));
    glassColor *= 0.72 + lens * 0.35;

    // A broad reflection across the sheet gives it depth between the fine rims.
    float reflection = exp(-pow((crossSection - 0.32 - fold * 0.22) * 7.0, 2.0));
    float3 highlight = mix(accent, float3(1.0), 0.82);
    glassColor = mix(glassColor, highlight, reflection * 0.38);
    float rimLight = edge * (0.55 + energy * 0.35);
    float3 color = mix(glassColor, highlight, saturate(rimLight));
    float bodyAlpha = fill * (0.22 + energy * 0.38 + reflection * 0.12);
    float alpha = max(bodyAlpha, rimLight) + halo * energy * 0.12;
    alpha = saturate(alpha) * smoothstep(0.0, 0.08, 1.0 - abs(x));

    // Core Animation composites the drawable using premultiplied alpha.
    return float4(color * alpha, alpha);
}
