#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
    float4 appearance; // shine intensity, gridline opacity, audio brightness, unused
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
    float2 uv;
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
    // Six vertices per cell, sharing the simulation's grid nodes.
    const uint columns = uint(uniforms.mesh.x), rows = uint(uniforms.mesh.y);
    float aspect = uniforms.camera.x;
    const uint corners[6] = {0, columns, 1, 1, columns, columns + 1};
    uint cell = id / 6;
    uint index = (cell / (columns - 1)) * columns + cell % (columns - 1) + corners[id % 6];
    float3 p = positions[index].xyz;
    float yaw = uniforms.camera.y, pitch = uniforms.camera.z;
    float3 world = clothCameraRotation(p, yaw, pitch);
    float distance = uniforms.camera.w - world.z;
    float scale = min(2.6, 2.6 * aspect);
    ClothVertex out;
    out.position = float4(world.x * scale / aspect, world.y * scale,
                          (distance - 0.1) * 100.0 / 99.9, distance);
    out.world = world;
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    return out;
}

fragment float4 clothVisualizerFragment(
    ClothVertex in [[stage_in]],
    texture2d<float> artwork [[texture(0)]],
    constant ClothUniforms &uniforms [[buffer(4)]],
    const device float4 *normals [[buffer(5)]]
) {
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
    float2 grid = in.uv * (uniforms.mesh.xy - 1);
    float2 edge = abs(fract(grid - 0.5) - 0.5) / max(fwidth(grid), float2(0.001));
    float weave = 1.0 - uniforms.appearance.y * (1.0 - smoothstep(0.0, 0.8, min(edge.x, edge.y)));
    float corner = length(float2(min(in.uv.x, 1.0 - in.uv.x), in.uv.y) * uniforms.mesh.zw);
    float pin = 1.0 - smoothstep(0.025, 0.055, corner);
    // A glossy satin finish: a bright key highlight, soft cool fill, and edge sheen.
    float3 lit = color * (0.3 + 0.75 * diffuse) * weave;
    float shineIntensity = uniforms.appearance.x;
    lit += float3(1.0, 0.94, 0.86) * specular * 0.85 * diffuse * shineIntensity;
    lit += float3(0.65, 0.8, 1.0) * sheen * 0.3 * max(dot(normal, fillLight), 0.0) * shineIntensity;
    lit += mix(color, float3(0.8, 0.9, 1.0), 0.65) * fresnel * 0.35 * shineIntensity;
    return float4(mix(lit, float3(0.95), pin) * uniforms.appearance.z, 1);
}
