#include <metal_stdlib>
using namespace metal;

// Matches the Swift InkPoolSettings layout (11 consecutive 32-bit floats).
struct InkPoolSettings {
    float speed;
    float flowScale;
    float warpStrength;
    float bassResponse;
    float rippleFrequency;
    float rippleStrength;
    float surfaceDepth;
    float artworkScale;
    float refraction;
    float sheen;
    float glints;
};

struct InkPoolRasterData {
    float4 position [[position]];
    float2 uv;
};

vertex InkPoolRasterData inkPoolVisualizerVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    InkPoolRasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

fragment float4 inkPoolVisualizerFragment(
    InkPoolRasterData input [[stage_in]],
    constant float *bands [[buffer(0)]],
    constant float &viewWidth [[buffer(1)]],
    constant float4 &accentColor [[buffer(2)]],
    constant float &elapsedTime [[buffer(3)]],
    constant InkPoolSettings &settings [[buffer(4)]],
    texture2d<float> artwork [[texture(0)]]
) {
    if (viewWidth <= 0.0) return float4(0.0);
    float bass = 0.0, treble = 0.0;
    for (uint i = 0; i < 20; ++i) bass += saturate(bands[i]) / 20.0;
    for (uint i = 44; i < 64; ++i) treble += saturate(bands[i]) / 20.0;
    bass *= settings.bassResponse;
    float2 uv = input.uv;
    float aspect = abs(dfdy(uv.y)) / max(abs(dfdx(uv.x)), 0.00001);
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float time = elapsedTime * settings.speed;
    float2 flow = p * settings.flowScale;
    // Domain warp
    for (uint i = 0; i < 3; ++i) {
        float phase = time * (0.7 + float(i) * 0.17);
        flow += float2(sin(flow.y * 1.8 + phase), cos(flow.x * 1.6 - phase))
            * (settings.warpStrength + bass * 0.13);
    }
    float radius = length(p * float2(0.85, 1.0));
    float ripple = sin(radius * settings.rippleFrequency - time * 9.0 + flow.x * 1.7);
    float height = sin(flow.x * 2.3 + flow.y * 1.6) * 0.12
        + cos(flow.y * 3.1 - flow.x) * 0.08
        + ripple * bass * settings.rippleStrength * exp(-radius * 1.6);
    float2 slope = float2(
        dfdx(height) / max(abs(dfdx(p.x)), 0.00001),
        dfdy(height) / min(dfdy(p.y), -0.00001)
    );
    float3 normal = normalize(float3(-slope * settings.surfaceDepth, 1.0));
    float2 artworkUV = float2(0.5 + flow.x * settings.artworkScale, 0.5 - flow.y * settings.artworkScale);
    artworkUV += slope * (0.018 + bass * 0.035) * settings.refraction;
    constexpr sampler artworkSampler(coord::normalized, address::mirrored_repeat, filter::linear);
    float3 pigment = artwork.sample(artworkSampler, artworkUV).rgb * 0.5;
    pigment += artwork.sample(artworkSampler, artworkUV + float2(0.045, 0.025)).rgb * 0.25;
    pigment += artwork.sample(artworkSampler, artworkUV - float2(0.045, 0.025)).rgb * 0.25;
    float3 color = mix(accentColor.rgb, pigment, saturate(accentColor.a));
    float diffuse = saturate(dot(normal, normalize(float3(-0.4, 0.6, 1.0))));
    color *= 0.5 + diffuse * 0.5;
    float sheen = pow(saturate(dot(normal, normalize(float3(0.3, 0.4, 1.0)))), 24.0);
    // Crossing capillary waves break the reflection into tiny treble glints.
    float capillary = sin(flow.x * 47.0 + flow.y * 23.0 + time * 4.0)
        * sin(flow.y * 53.0 - flow.x * 19.0 - time * 3.0);
    float resolvable = 1.0 - smoothstep(0.5, 1.5, fwidth(flow.x * 47.0 + flow.y * 53.0));
    float glints = smoothstep(0.88, 0.99, capillary) * sheen * treble * resolvable;
    color = mix(color, float3(0.94, 0.98, 1.0), saturate(sheen * settings.sheen + glints * settings.glints));
    // Cover the full viewport while preserving the surface translucency.
    float alpha = 0.78 + sheen * 0.12;
    return float4(color * alpha, alpha);
}
