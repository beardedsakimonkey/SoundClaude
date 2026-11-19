#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 signedOutBackground(float2 position, half4 edgeColor,
                                           float4 bounds, half4 centerColor) {
    float2 uv = saturate((position - bounds.xy) / max(bounds.zw, float2(1)));
    float2 falloff = 4 * uv * (1 - uv);
    float glow = pow(falloff.x * falloff.y, 0.84f);

    // Anchor the grain to the view so it stays still when the window resizes.
    uint2 pixel = uint2(floor(position * 2));
    uint hash = pixel.x * 1597334677u ^ pixel.y * 3812015801u;
    hash = (hash ^ (hash >> 16)) * 2246822519u;
    float grain = float(hash >> 16) / 65535.0f;
    return mix(edgeColor, centerColor, half(glow * (0.84f + 0.16f * grain)));
}
