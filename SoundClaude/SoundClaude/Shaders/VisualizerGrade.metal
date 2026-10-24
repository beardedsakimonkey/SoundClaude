#include <metal_stdlib>
using namespace metal;

struct VisualizerGradeUniforms {
    float4 viewport; // drawable width and height, backdrop glow radius in pixels (0 for flat), grain seed
    float4 backdrop; // sRGB-encoded backdrop color
    float4 glow; // sRGB-encoded backdrop glow color at the center
    float4 tone; // amount, contrast, saturation, vignette
    float4 shadowTint; // linear RGB, grain
    float4 highlightTint; // linear RGB, unused
};
struct VisualizerGradeVertex {
    float4 position [[position]];
};
vertex VisualizerGradeVertex visualizerGradeVertex(uint id [[vertex_id]]) {
    const float2 corners[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return {float4(corners[id], 0, 1)};
}
static float3 gradeDecode(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}
static float3 gradeEncode(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}
static float gradeHash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}
fragment float4 visualizerGradeFragment(VisualizerGradeVertex in [[stage_in]],
                                        texture2d<float> scene [[texture(0)]],
                                        constant VisualizerGradeUniforms &u [[buffer(0)]]) {
    const float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float2 pixel = in.position.xy;
    float4 surface = scene.read(uint2(pixel));
    // Recreate the SwiftUI backdrop behind the transparent scene so the grade
    // covers the floor's horizon fade continuously. Match its gradient stops.
    float3 backdrop = u.backdrop.rgb;
    if (u.viewport.z > 0) {
        float t = length(pixel - u.viewport.xy * 0.5) / u.viewport.z;
        float opacity = t < 0.35 ? mix(1.0, 0.55, t / 0.35)
            : (t < 0.7 ? mix(0.55, 0.12, (t - 0.35) / 0.35) : 0.12 * (1 - saturate((t - 0.7) / 0.3)));
        backdrop = mix(backdrop, u.glow.rgb, opacity);
    }
    // The 8-bit drawable used to clip each channel; keep that look.
    float3 original = saturate(saturate(surface.rgb) + backdrop * (1 - saturate(surface.a)));

    float3 linear = gradeDecode(original);
    float luma = dot(linear, lumaWeights);
    // Tints are normalized to unit luminance, so they shift hue without exposure.
    float3 shadowGain = u.shadowTint.rgb / max(dot(u.shadowTint.rgb, lumaWeights), 0.0001);
    float3 highlightGain = u.highlightTint.rgb / max(dot(u.highlightTint.rgb, lumaWeights), 0.0001);
    linear *= mix(shadowGain, highlightGain, smoothstep(0.02, 0.5, luma));
    linear = max(mix(float3(dot(linear, lumaWeights)), linear, u.tone.z), 0.0);
    float aspect = u.viewport.x / max(u.viewport.y, 1.0);
    float2 centered = (pixel / u.viewport.xy - 0.5) * float2(aspect, 1);
    float radius = length(centered) / length(float2(aspect, 1) * 0.5);
    linear *= 1 - u.tone.w * smoothstep(0.35, 1.1, radius);

    // Per-channel S-curve through 0, the pivot and 1, applied to encoded values.
    float3 graded = saturate(gradeEncode(linear));
    const float pivot = 0.4;
    float slope = max(u.tone.y, 0.01);
    graded = select(1 - (1 - pivot) * pow((1 - graded) / (1 - pivot), slope),
                    pivot * pow(graded / pivot, slope), graded < pivot);
    float lightness = dot(graded, lumaWeights);
    float2 seed = pixel + u.viewport.w * float2(37.0, 17.0);
    graded += (gradeHash(seed) - 0.5) * u.shadowTint.w * 4 * lightness * (1 - lightness);

    float3 color = mix(original, graded, u.tone.x);
    // Triangular dither hides 8-bit banding in the dark backdrop gradient.
    color += (gradeHash(seed + 0.5) + gradeHash(seed + 71.3) - 1) / 255.0;
    return float4(saturate(color), 1);
}
