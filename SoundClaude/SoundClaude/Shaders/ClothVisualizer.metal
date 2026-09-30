#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
    float4 appearance; // shine intensity, unused, mesh debug, pass (cloth, mask, shadow, supports, support mask)
    float4 shadow; // unused, opacity, ground depth, unused
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
    float2 uv;
    float3 barycentric;
    float3 supportNormal;
};

static float3 clothGroundProjection(float3 p, float groundDepth) {
    float gap = max(0.0, p.z - groundDepth);
    return float3(p.xy + float2(0.18, 0.24) * gap, groundDepth);
}

static float3 clothCameraRotation(float3 v, float yaw, float pitch) {
    // Orbit around the ground normal (Z), then tilt around the camera's right
    // axis. The same basis applies to fabric, supports, shadows and normals.
    float3 turned = float3(cos(yaw) * v.x - sin(yaw) * v.y,
                          sin(yaw) * v.x + cos(yaw) * v.y, v.z);
    return float3(turned.x, cos(pitch) * turned.y + sin(pitch) * turned.z,
                  -sin(pitch) * turned.y + cos(pitch) * turned.z);
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

// Solid supports share the cloth projection and depth buffer.
static ClothVertex clothSupportVertex(uint id, const device float4 *positions,
                                      constant ClothUniforms &u) {
    uint columns = uint(u.mesh.x), rows = uint(u.mesh.y);
    float3 p, normal;
    float material = 0;
    const uint supportVertices = 3 * 12 * 12;
    if (id >= 4 * supportVertices) {
        const float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                                  float2(-1,1), float2(1,-1), float2(1,1)};
        p = float3(corners[id - 4 * supportVertices] * (u.mesh.zw * 0.5 + 1.7), u.shadow.z);
        normal = float3(0,0,1);
        material = 2;
    } else {
        uint support = id / supportVertices;
        uint part = (id % supportVertices) / (12 * 12);
        uint face = (id % (12 * 12)) / 12, localVertex = id % 12;
        const uint cornerIndices[4] = {0, columns - 1, (rows - 1) * columns, rows * columns - 1};
        float3 anchor = positions[columns * rows + support].xyz;
        float3 start = float3(anchor.xy, u.shadow.z), end = anchor;
        float radius = 0.11;
        if (part == 1) { radius = 0.27; end = start + float3(0,0,0.10); }
        if (part == 2) { start = anchor; end = positions[cornerIndices[support]].xyz; radius = 0.028; material = 1; }
        float3 axis = normalize(end - start);
        float3 tangent = normalize(cross(axis, abs(axis.z) < 0.9 ? float3(0,0,1) : float3(0,1,0)));
        float3 bitangent = cross(axis, tangent);
        const uint ring[6] = {0,1,0,0,1,1};
        const uint top[6] = {0,0,1,1,0,1};
        uint side = localVertex < 6 ? ring[localVertex] : (localVertex % 3 == 2 ? 1 : 0);
        float angle = (float(face + side) / 12.0) * 2.0 * M_PI_F;
        float3 radial = tangent * cos(angle) + bitangent * sin(angle);
        if (localVertex < 6) {
            p = mix(start, end, float(top[localVertex])) + radial * radius;
            normal = radial;
        } else {
            bool capTop = localVertex >= 9;
            p = (capTop ? end : start) + (localVertex % 3 == 0 ? float3(0) : radial * radius);
            normal = capTop ? axis : -axis;
        }
    }
    if (u.appearance.w > 3.5) p = clothGroundProjection(p, u.shadow.z);
    float3 world = clothCameraRotation(p, u.camera.y, u.camera.z);
    float distance = u.camera.w - world.z;
    float scale = min(2.6, 2.6 * u.camera.x);
    ClothVertex out;
    out.position = float4(world.x * scale / u.camera.x, world.y * scale,
                          (distance - 0.1) * 100.0 / 99.9, distance);
    out.world = world;
    out.uv = float2(material, 0);
    out.barycentric = float3(0);
    out.supportNormal = clothCameraRotation(normal, u.camera.y, u.camera.z);
    return out;
}

vertex ClothVertex clothVisualizerVertex(
    uint id [[vertex_id]], const device float4 *positions [[buffer(0)]],
    constant ClothUniforms &uniforms [[buffer(1)]]
) {
    if (uniforms.appearance.w > 2.5) return clothSupportVertex(id, positions, uniforms);
    if (uniforms.appearance.w > 1.5) {
        float2 corner = float2((id << 1) & 2, id & 2);
        ClothVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.999, 1);
        out.world = float3(0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        out.supportNormal = float3(0);
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
    if (uniforms.appearance.w > 0.5) {
        p = clothGroundProjection(p, uniforms.shadow.z);
    }
    float3 world = clothCameraRotation(p, yaw, pitch);
    float distance = uniforms.camera.w - world.z;
    float scale = min(2.6, 2.6 * aspect);
    ClothVertex out;
    out.position = float4(world.x * scale / aspect, world.y * scale,
                          (distance - 0.1) * 100.0 / 99.9, distance);
    out.world = world;
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    out.supportNormal = float3(0);
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
    if (uniforms.appearance.w > 3.5) return float4(1);
    if (uniforms.appearance.w > 2.5) {
        float light = 0.35 + 0.65 * abs(dot(normalize(in.supportNormal), normalize(float3(-0.4, 0.6, 1))));
        float3 color = in.uv.x > 1.5 ? float3(0.085, 0.09, 0.10)
                    : in.uv.x > 0.5 ? float3(0.72, 0.65, 0.50) : float3(0.28, 0.31, 0.35);
        return float4(color * light, 1);
    }
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
    float3 color = artwork.sample(sampleFilter, in.uv).rgb;
    color = mix(color, float3(0.65, 0.8, 0.9), 0.18);
    // A rough fabric finish with blue ambient light and a slightly red key light.
    const float3 ambientColor = float3(0.65, 0.8, 1.0);
    const float3 keyColor = float3(1.0, 0.88, 0.86);
    float3 lit = color * (0.3 * ambientColor + 0.75 * diffuse * keyColor);
    float shineIntensity = uniforms.appearance.x;
    lit += keyColor * specular * 0.4 * diffuse * shineIntensity;
    lit += float3(0.65, 0.8, 1.0) * sheen * 0.18 * max(dot(normal, fillLight), 0.0) * shineIntensity;
    lit += mix(color, float3(0.8, 0.9, 1.0), 0.65) * fresnel * 0.2 * shineIntensity;
    return float4(lit * faceBrightness, 1);
}
