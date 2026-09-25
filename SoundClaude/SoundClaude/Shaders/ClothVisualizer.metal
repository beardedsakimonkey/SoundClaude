#include <metal_stdlib>
using namespace metal;

struct ClothRipple {
    float4 hit; // origin x/y, normalized age, strength
    float4 shape; // impulse radius, treble flag, trail fade progress, age in seconds
};

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
    float4 appearance; // shine intensity, ripple count, mesh debug, pass (cloth, mask, shadow)
    float4 shadow; // wall depth, opacity, unused, unused
    float4 optics; // chromatic aberration, iridescence, ripple thickness, unused
    ClothRipple ripples[64];
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
    float2 simulationXY;
    float2 uv;
    float3 barycentric;
};

static float3 clothCameraRotation(float3 v, float yaw, float pitch) {
    float3 turned = float3(cos(yaw) * v.x + sin(yaw) * v.z,
                          v.y, -sin(yaw) * v.x + cos(yaw) * v.z);
    return float3(turned.x, cos(pitch) * turned.y - sin(pitch) * turned.z,
                  sin(pitch) * turned.y + cos(pitch) * turned.z);
}

// Catmull-Rom weights preserve node normals and keep the normal field smooth
// across cell boundaries. Clamp the sample coordinates at the cloth edges.
static float4 clothCubicWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t + t2 - 0.5 * t3,
                  1.0 - 2.5 * t2 + 1.5 * t3,
                  0.5 * t + 2.0 * t2 - 1.5 * t3,
                  -0.5 * t2 + 0.5 * t3);
}

static float3 clothBicubicNormal(float2 uv, int2 size,
                                const device float4 *normals) {
    float2 grid = saturate(uv) * float2(size - 1);
    int2 cell = int2(floor(grid));
    float4 wx = clothCubicWeights(fract(grid.x));
    float4 wy = clothCubicWeights(fract(grid.y));
    float3 normal = float3(0);
    for (int y = 0; y < 4; ++y) {
        int row = clamp(cell.y + y - 1, 0, size.y - 1);
        for (int x = 0; x < 4; ++x) {
            int column = clamp(cell.x + x - 1, 0, size.x - 1);
            normal += normals[row * size.x + column].xyz * wx[x] * wy[y];
        }
    }
    // Opposing normals can cancel in a tight fold; use the nearest node then.
    if (dot(normal, normal) < 0.00000001) {
        int2 nearest = clamp(int2(floor(grid + 0.5)), int2(0), size - 1);
        normal = normals[nearest.y * size.x + nearest.x].xyz;
    }
    return normalize(normal);
}

vertex ClothVertex clothVisualizerVertex(
    uint id [[vertex_id]], const device float4 *positions [[buffer(0)]],
    constant ClothUniforms &uniforms [[buffer(1)]]
) {
    if (uniforms.appearance.w > 1.5) {
        float2 corner = float2((id << 1) & 2, id & 2);
        ClothVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.999, 1);
        out.world = float3(0);
        out.simulationXY = float2(0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        out.barycentric = float3(0);
        return out;
    }
    // Six vertices per cell, sharing the simulation's grid nodes.
    const uint columns = uint(uniforms.mesh.x), rows = uint(uniforms.mesh.y);
    float aspect = uniforms.camera.x;
    const uint corners[6] = {0, columns, 1, 1, columns, columns + 1};
    uint cell = id / 6;
    uint index = (cell / (columns - 1)) * columns + cell % (columns - 1) + corners[id % 6];
    float3 p = positions[index].xyz;
    float yaw = uniforms.camera.y, pitch = uniforms.camera.z;
    float3 world = clothCameraRotation(p, yaw, pitch);
    if (uniforms.appearance.w > 0.5) {
        // Offset the wall shadow up and right.
        float gap = max(0.0, world.z - uniforms.shadow.x);
        world.xy += float2(0.4, 0.6) * gap;
        world.z = uniforms.shadow.x;
    }
    float distance = uniforms.camera.w - world.z;
    float scale = min(2.6, 2.6 * aspect);
    ClothVertex out;
    out.position = float4(world.x * scale / aspect, world.y * scale,
                          (distance - 0.1) * 100.0 / 99.9, distance);
    out.world = world;
    out.simulationXY = p.xy;
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    out.barycentric = float3(id % 3 == 0, id % 3 == 1, id % 3 == 2);
    return out;
}

fragment float4 clothVisualizerFragment(
    ClothVertex in [[stage_in]],
    bool frontFacing [[front_facing]],
    texture2d<float> artwork [[texture(0)]],
    texture2d<float> shadowMask [[texture(1)]],
    constant float4 &accentColor [[buffer(2)]],
    constant ClothUniforms &uniforms [[buffer(4)]],
    const device float4 *normals [[buffer(5)]]
) {
    if (uniforms.appearance.w > 1.5) {
        constexpr sampler shadowFilter(filter::linear, address::clamp_to_zero);
        float opacity = shadowMask.sample(shadowFilter, in.uv).r * uniforms.shadow.y;
        // Premultiplied black darkens the SwiftUI wall through the transparent view.
        return float4(0, 0, 0, opacity);
    }
    if (uniforms.appearance.w > 0.5) return float4(1);
    // Triangle winding identifies the material side even inside tight folds.
    float faceBrightness = frontFacing ? 1.0 : 0.45;
    float3 normal = clothBicubicNormal(in.uv, int2(uniforms.mesh.xy), normals);
    normal = clothCameraRotation(normal, uniforms.camera.y, uniforms.camera.z);
    float3 view = normalize(float3(0, 0, uniforms.camera.w) - in.world);
    if (dot(normal, view) < 0.0) normal = -normal;
    // Material coordinates let the ripples bend and stretch with the cloth.
    float2 materialXY = (in.uv - 0.5) * uniforms.mesh.zw * float2(1, -1);
    float2 rippleOffset = float2(0);
    float rippleShine = 0.0;
    float3 rippleTint = float3(0);
    for (int i = 0; i < min(int(uniforms.appearance.y), 64); ++i) {
        ClothRipple ripple = uniforms.ripples[i];
        float age = ripple.hit.z;
        float2 offset = materialXY - ripple.hit.xy;
        float scale = max(0.3, ripple.shape.x);
        float width = min(scale * 0.82, min(uniforms.mesh.z, uniforms.mesh.w) * 0.24);
        if (ripple.shape.y < 0.5) {
            width *= mix(0.35, 1.6, saturate(ripple.hit.w));
        } else {
            width *= 0.25;
        }
        width *= max(0.01, uniforms.optics.z);
        // Approximate cloth propagation with steady travel across a diagonal in 1.5 s.
        // Every hit has the same speed, independent of its origin or band width.
        float radius = ripple.shape.w * length(uniforms.mesh.zw) / 1.5;
        float distance = length(offset) - radius;
        float2 direction = offset / max(length(offset), 0.0001);
        // Keep the artwork still ahead of the wave.
        float edgeWidth = max(width * 0.06, fwidth(distance));
        float frontier = 1.0 - smoothstep(-edgeWidth, edgeWidth, distance);
        // Alternating displacement compresses and stretches the artwork in the wake.
        float phase = distance / width;
        float wave = sin(phase * M_PI_F) * exp(-phase * phase * 0.5);
        // Reduce distortion as the ripple travels, then clear the remaining trail.
        float ageFade = exp2(-2.0 * age);
        float trailFade = 1.0 - smoothstep(0.0, 1.0, ripple.shape.z);
        float amount = wave * frontier * ageFade * trailFade * mix(0.55, 1.0, ripple.hit.w);
        rippleOffset += direction * amount * width * 0.45;
        // A narrow highlight follows the strongest distortion and shares its fade.
        rippleShine += amount * amount;
        // A thin-film-inspired hue shift follows the wave and the viewing angle.
        float filmPhase = phase * 2.0 + ripple.shape.w * 0.8
                        + (1.0 - saturate(dot(normal, view))) * 6.0;
        float3 filmColor = 0.55 + 0.45 * cos(filmPhase + float3(0, 2.094395, 4.188790));
        rippleTint += filmColor * amount * amount;
    }
    if (uniforms.appearance.z > 0.5) {
        // Show the actual rendered triangles, including each cell's diagonal.
        // Opaque faces preserve depth occlusion when the cloth folds over itself.
        float3 edgeDistance = in.barycentric / max(fwidth(in.barycentric), float3(0.00001));
        float edge = 1.0 - smoothstep(0.5, 1.5, min(edgeDistance.x, min(edgeDistance.y, edgeDistance.z)));
        float3 meshColor = mix(float3(0.025, 0.04, 0.055), float3(0.3, 0.9, 1.0), edge);
        return float4(meshColor * faceBrightness, 1);
    }
    constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
    float3 light = normalize(float3(-0.4, 0.6, 1.0));
    float3 fillLight = normalize(float3(0.8, -0.2, 0.7));
    float diffuse = max(dot(normal, light), 0.0);
    // Broad, low-intensity highlights give the cloth a rough fabric finish.
    float specular = pow(max(dot(normal, normalize(light + view)), 0.0), 12.0);
    float sheen = pow(max(dot(normal, normalize(fillLight + view)), 0.0), 8.0);
    float fresnel = pow(1.0 - saturate(dot(normal, view)), 5.0);
    float2 uvOffset = rippleOffset / uniforms.mesh.zw * float2(1, -1);
    // Limit overlapping waves and anchor the image at the cloth edges.
    uvOffset *= 0.04 / max(0.04, length(uvOffset));
    float2 edgeDistance = min(in.uv, 1.0 - in.uv);
    float edgeFade = smoothstep(0.0, 0.05, min(edgeDistance.x, edgeDistance.y));
    float2 artworkUV = in.uv + uvOffset * edgeFade;
    // Separate red and blue slightly along the distortion; still areas stay aligned.
    float2 dispersion = uvOffset * edgeFade * uniforms.optics.x;
    float3 color = float3(artwork.sample(sampleFilter, artworkUV + dispersion).r,
                          artwork.sample(sampleFilter, artworkUV).g,
                          artwork.sample(sampleFilter, artworkUV - dispersion).b);
    color = mix(color, float3(0.65, 0.8, 0.9), 0.18);
    // A rough fabric finish with blue ambient light and a slightly red key light.
    const float3 ambientColor = float3(0.65, 0.8, 1.0);
    const float3 keyColor = float3(1.0, 0.88, 0.86);
    float3 lit = color * (0.3 * ambientColor + 0.75 * diffuse * keyColor);
    float shineIntensity = uniforms.appearance.x;
    lit += keyColor * specular * 0.4 * diffuse * shineIntensity;
    lit += float3(0.65, 0.8, 1.0) * sheen * 0.18 * max(dot(normal, fillLight), 0.0) * shineIntensity;
    lit += mix(color, float3(0.8, 0.9, 1.0), 0.65) * fresnel * 0.2 * shineIntensity;
    // Average overlapping hues and limit their brightness to keep the sheen subtle.
    float waveShine = saturate(rippleShine) * edgeFade * 0.18
                    * saturate(shineIntensity * 2.0) * (0.35 + 0.65 * diffuse);
    float3 shineColor = mix(float3(1), rippleTint / max(rippleShine, 0.0001), uniforms.optics.y);
    lit += max(float3(0), 1.0 - lit) * waveShine * shineColor;
    return float4(lit * faceBrightness, 1);
}
