#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
    float4 appearance; // shine intensity, unused, mesh debug, pass (cloth, mask, shadow)
    float4 shadow; // wall depth, opacity, unused, unused
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
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
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    out.barycentric = float3(id % 3 == 0, id % 3 == 1, id % 3 == 2);
    return out;
}

fragment float4 clothVisualizerFragment(
    ClothVertex in [[stage_in]],
    bool frontFacing [[front_facing]],
    texture2d<float> artwork [[texture(0)]],
    texture2d<float> shadowMask [[texture(1)]],
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
    if (uniforms.appearance.z > 0.5) {
        // Show the actual rendered triangles, including each cell's diagonal.
        // Opaque faces preserve depth occlusion when the cloth folds over itself.
        float3 edgeDistance = in.barycentric / max(fwidth(in.barycentric), float3(0.00001));
        float edge = 1.0 - smoothstep(0.5, 1.5, min(edgeDistance.x, min(edgeDistance.y, edgeDistance.z)));
        return float4(mix(float3(0.025, 0.04, 0.055), float3(0.3, 0.9, 1.0), edge) * faceBrightness, 1);
    }
    constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
    float3 normal = clothBicubicNormal(in.uv, int2(uniforms.mesh.xy), normals);
    normal = clothCameraRotation(normal, uniforms.camera.y, uniforms.camera.z);
    float3 view = normalize(float3(0, 0, uniforms.camera.w) - in.world);
    if (dot(normal, view) < 0.0) normal = -normal;
    float3 light = normalize(float3(-0.4, 0.6, 1.0));
    float3 fillLight = normalize(float3(0.8, -0.2, 0.7));
    float diffuse = max(dot(normal, light), 0.0);
    float specular = pow(max(dot(normal, normalize(light + view)), 0.0), 32.0);
    float sheen = pow(max(dot(normal, normalize(fillLight + view)), 0.0), 18.0);
    float fresnel = pow(1.0 - saturate(dot(normal, view)), 5.0);
    float3 color = artwork.sample(sampleFilter, in.uv).rgb;
    color = mix(color, float3(0.65, 0.8, 0.9), 0.18);
    // A glossy satin finish with blue ambient light and a slightly red key light.
    const float3 ambientColor = float3(0.65, 0.8, 1.0);
    const float3 keyColor = float3(1.0, 0.88, 0.86);
    float3 lit = color * (0.3 * ambientColor + 0.75 * diffuse * keyColor);
    float shineIntensity = uniforms.appearance.x;
    lit += keyColor * specular * 0.85 * diffuse * shineIntensity;
    lit += float3(0.65, 0.8, 1.0) * sheen * 0.3 * max(dot(normal, fillLight), 0.0) * shineIntensity;
    lit += mix(color, float3(0.8, 0.9, 1.0), 0.65) * fresnel * 0.35 * shineIntensity;
    return float4(lit * faceBrightness, 1);
}
