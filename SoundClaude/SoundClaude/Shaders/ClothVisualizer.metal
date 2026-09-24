#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

static float3 clothCameraRotation(float3 v, float yaw, float pitch) {
    float3 turned = float3(cos(yaw) * v.x + sin(yaw) * v.z,
                          v.y, -sin(yaw) * v.x + cos(yaw) * v.z);
    return float3(turned.x, cos(pitch) * turned.y - sin(pitch) * turned.z,
                  sin(pitch) * turned.y + cos(pitch) * turned.z);
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
    // Shared grid normals keep the shine smooth across triangle boundaries.
    uint x = index % columns, y = index / columns;
    float3 tangent = positions[y * columns + min(x + 1, columns - 1)].xyz
                   - positions[y * columns + (x > 0 ? x - 1 : x)].xyz;
    float3 bitangent = positions[min(y + 1, rows - 1) * columns + x].xyz
                     - positions[(y > 0 ? y - 1 : y) * columns + x].xyz;
    float3 surfaceNormal = cross(bitangent, tangent);
    surfaceNormal /= max(length(surfaceNormal), 0.00001);
    float yaw = uniforms.camera.y, pitch = uniforms.camera.z;
    float3 world = clothCameraRotation(p, yaw, pitch);
    float distance = uniforms.camera.w - world.z;
    float scale = min(2.6, 2.6 * aspect);
    ClothVertex out;
    out.position = float4(world.x * scale / aspect, world.y * scale,
                          (distance - 0.1) * 100.0 / 99.9, distance);
    out.world = world;
    out.normal = clothCameraRotation(surfaceNormal, yaw, pitch);
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    return out;
}

fragment float4 clothVisualizerFragment(
    ClothVertex in [[stage_in]], constant float4 &accent [[buffer(2)]],
    texture2d<float> artwork [[texture(0)]],
    constant ClothUniforms &uniforms [[buffer(4)]]
) {
    constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
    float3 normal = in.normal / max(length(in.normal), 0.00001);
    float3 view = normalize(float3(0, 0, uniforms.camera.w) - in.world);
    if (dot(normal, view) < 0.0) normal = -normal;
    float3 light = normalize(float3(-0.4, 0.6, 1.0));
    float3 fillLight = normalize(float3(0.8, -0.2, 0.7));
    float diffuse = max(dot(normal, light), 0.0);
    float specular = pow(max(dot(normal, normalize(light + view)), 0.0), 72.0);
    float sheen = pow(max(dot(normal, normalize(fillLight + view)), 0.0), 18.0);
    float fresnel = pow(1.0 - saturate(dot(normal, view)), 5.0);
    float3 color = mix(accent.rgb, artwork.sample(sampleFilter, in.uv).rgb, accent.a * 0.7);
    color = mix(color, float3(0.65, 0.8, 0.9), 0.18);
    float2 grid = in.uv * (uniforms.mesh.xy - 1);
    float2 edge = abs(fract(grid - 0.5) - 0.5) / max(fwidth(grid), float2(0.001));
    float weave = 1.0 - 0.16 * (1.0 - smoothstep(0.0, 0.8, min(edge.x, edge.y)));
    float corner = length(min(in.uv, 1.0 - in.uv) * uniforms.mesh.zw);
    float pin = 1.0 - smoothstep(0.025, 0.055, corner);
    // A glossy satin finish: a bright key highlight, soft cool fill, and edge sheen.
    float3 lit = color * (0.3 + 0.75 * diffuse) * weave;
    lit += float3(1.0, 0.94, 0.86) * specular * 0.85 * diffuse;
    lit += float3(0.65, 0.8, 1.0) * sheen * 0.3 * max(dot(normal, fillLight), 0.0);
    lit += mix(color, float3(0.8, 0.9, 1.0), 0.65) * fresnel * 0.35;
    return float4(mix(lit, float3(0.95), pin), 1);
}
