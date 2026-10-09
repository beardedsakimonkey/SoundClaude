#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float4 mesh; // columns, rows, width, height
    float4 camera; // aspect, yaw, pitch, distance
    float4 appearance; // shine intensity, ground brightness, mesh debug, pass (cloth, mask, ground, supports, support mask)
    float4 shadow; // viewport width, opacity, ground depth, viewport height
    float4 track; // progress, has track, ground tile size, unused
    float4 bass; // impulse origin XY, radius, flash intensity
};

struct ClothVertex {
    float4 position [[position]];
    float3 world;
    float3 scenePosition;
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
    // Pole sides and bottom, foot and rope cylinders, then four dome bands.
    const uint poleVertices = 12 * 9;
    const uint cylinderVertices = poleVertices + 2 * 12 * 12;
    const uint supportVertices = cylinderVertices + 12 * 4 * 6;
    {
        uint support = id / supportVertices;
        uint supportVertex = id % supportVertices;
        bool dome = supportVertex >= cylinderVertices;
        uint part = supportVertex < poleVertices || dome ? 0 : 1 + (supportVertex - poleVertices) / (12 * 12);
        uint partVertex = part == 0 ? supportVertex : (supportVertex - poleVertices) % (12 * 12);
        uint face = partVertex / (part == 0 ? 9 : 12);
        uint localVertex = partVertex % (part == 0 ? 9 : 12);
        const uint cornerIndices[4] = {0, columns - 1, (rows - 1) * columns, rows * columns - 1};
        float3 anchor = positions[columns * rows + support].xyz;
        // Keep the rope attachment recessed below the pillar's top.
        float3 start = float3(anchor.xy, u.shadow.z), end = anchor + float3(0, 0, 0.15);
        float radius = 0.11;
        if (part == 0) end.z -= radius;
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
        if (dome) {
            uint domeVertex = supportVertex - cylinderVertices;
            uint band = domeVertex / (12 * 6);
            uint segment = (domeVertex / 6) % 12;
            uint corner = domeVertex % 6;
            float longitude = float(segment + ring[corner]) / 12.0 * 2.0 * M_PI_F;
            float latitude = float(band + top[corner]) / 4.0 * 0.5 * M_PI_F;
            float3 domeRadial = tangent * cos(longitude) + bitangent * sin(longitude);
            normal = domeRadial * cos(latitude) + axis * sin(latitude);
            p = end + normal * radius;
        } else if (localVertex < 6) {
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
    out.scenePosition = p;
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
        out.scenePosition = float3(0);
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
    out.scenePosition = p;
    out.uv = float2(index % columns, index / columns) / float2(columns - 1, rows - 1);
    out.supportNormal = float3(0);
    out.barycentric = float3(id % 3 == 0, id % 3 == 1, id % 3 == 2);
    return out;
}

static float clothSpeckleHash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float clothStoneNoise(float2 p, float footprint) {
    float2 cell = floor(p);
    float2 blend = fract(p);
    blend = blend * blend * (3.0 - 2.0 * blend);
    float value = mix(mix(clothSpeckleHash(cell), clothSpeckleHash(cell + float2(1, 0)), blend.x),
                      mix(clothSpeckleHash(cell + float2(0, 1)), clothSpeckleHash(cell + 1.0), blend.x),
                      blend.y);
    return mix(value, 0.5, smoothstep(0.25, 0.8, footprint));
}

static float3 clothSpeckledFloor(float2 p, float3 accentColor) {
    float2 grid = p * 2.5;
    float2 cell = floor(grid);
    float seed = clothSpeckleHash(cell);
    float2 center = 0.2 + 0.6 * float2(clothSpeckleHash(cell + 17.3),
                                      clothSpeckleHash(cell + 41.7));
    float2 offset = fract(grid) - center;
    float angle = clothSpeckleHash(cell + 9.2) * 6.283185;
    float2 local = float2(cos(angle) * offset.x - sin(angle) * offset.y,
                         sin(angle) * offset.x + cos(angle) * offset.y);
    local.y *= mix(1.2, 2.4, clothSpeckleHash(cell + 63.1));
    float radius = mix(0.04, 0.13, clothSpeckleHash(cell + 28.6));
    // Slightly uneven, elongated flecks, scattered across an otherwise flat base.
    float distance = length(local) + 0.2 * local.x - radius;
    float aa = max(fwidth(distance), 0.001);
    float footprint = max(length(dfdx(grid)), length(dfdy(grid)));
    float fleck = (1.0 - smoothstep(-aa, aa, distance)) * step(0.68, seed);
    // Fade flecks smaller than a pixel to prevent sparkle while orbiting.
    fleck *= 1.0 - smoothstep(radius * 0.5, radius * 2.0, footprint);
    float3 tint = clothSpeckleHash(cell + 82.4) < 0.65
        ? accentColor * 0.78 : mix(accentColor, float3(1), 0.12);
    return mix(accentColor, tint, fleck);
}

static float2 clothTileSite(float2 cell) {
    return cell + 0.15 + 0.7 * float2(clothSpeckleHash(cell + 103.7),
                                     clothSpeckleHash(cell + 251.9));
}

static float clothTileGroutExtra(float2 cell) {
    float seed = clothSpeckleHash(cell + 487.3);
    // Roughly one in ten tiles has wider joints around its perimeter.
    return seed > 0.9 ? mix(0.006, 0.012, (seed - 0.9) * 10.0) : 0.0;
}

static float3 clothTiledFloor(float2 p, float3 accentColor, float tileSize) {
    // Soften the tile tint while preserving the accent's luminance.
    float luminance = dot(accentColor, float3(0.2126, 0.7152, 0.0722));
    accentColor = mix(float3(luminance), accentColor, 0.4);
    float2 grid = p / tileSize;
    float2 cell = floor(grid);
    float2 nearestCell = cell;
    float2 nearest = float2(0);
    float nearestDistance = 1e10;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float2 candidate = cell + float2(x, y);
            float2 offset = clothTileSite(candidate) - grid;
            float distance = dot(offset, offset);
            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearestCell = candidate;
                nearest = offset;
            }
        }
    }
    // Start with the geometric edge, then weather the grout and tile lip below.
    float edge = 1e10;
    float2 edgeNormal = float2(0);
    float groutExtra = clothTileGroutExtra(nearestCell);
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            if (x == 0 && y == 0) continue;
            float2 neighborCell = nearestCell + float2(x, y);
            float2 neighbor = clothTileSite(neighborCell) - grid;
            float2 separation = neighbor - nearest;
            float2 normal = normalize(separation);
            float distance = dot(0.5 * (nearest + neighbor), normal);
            // Both tiles agree on the shared joint width. Compare inset edges
            // so wider joints also meet cleanly at corners.
            distance -= max(groutExtra, clothTileGroutExtra(neighborCell));
            if (distance < edge) {
                edge = distance;
                edgeNormal = normal;
            }
        }
    }
    float footprint = max(length(dfdx(grid)), length(dfdy(grid)));
    float aa = max(footprint * 0.5, 0.0001);
    float detail = 1.0 - smoothstep(0.025, 0.15, footprint);
    float worldFootprint = footprint * tileSize;
    float wear = clothStoneNoise(p * 1.7 + 7.4, worldFootprint * 1.7);
    float roughness = clothStoneNoise(p * 18.0, worldFootprint * 18.0);
    float groutWidth = 0.004 + 0.005 * roughness;
    float seam = (1.0 - smoothstep(groutWidth - aa, groutWidth + aa, edge)) * detail;
    float lip = edge - groutWidth;
    float bevelWidth = mix(0.009, 0.022, wear);
    float bevel = (1.0 - smoothstep(0.0, bevelWidth + aa, lip)) * detail;
    float dirt = (1.0 - smoothstep(0.0, 0.045 + aa, lip)) * detail;
    // Keep each tile close to the accent, with sparse flecks across its face.
    float shade = mix(0.91, 1.0, clothSpeckleHash(nearestCell + 379.1));
    float3 base = accentColor * mix(0.955, shade, detail);
    float3 color = clothSpeckledFloor(p, base);
    // Restrained surface wear; beveled edges and recessed grout carry most of
    // the texture. Light the bevels from the same side as the cloth and poles.
    float grain = clothStoneNoise(p * 65.0 + 51.3, worldFootprint * 65.0);
    color *= 1.0 + 0.045 * (wear - 0.5) + 0.025 * (grain - 0.5);
    color *= 1.0 - dirt * (0.04 + 0.09 * wear);
    float bevelLight = dot(edgeNormal, normalize(float2(-0.4, 0.6)));
    color *= 1.0 + bevel * bevelLight * 0.16;
    float3 grout = accentColor * (0.50 + 0.10 * roughness + 0.06 * wear);
    return mix(color, grout, seam);
}

static float3 clothFloor(float2 p, const device float4 *positions,
                         constant ClothUniforms &u, float3 accentColor) {
    float3 color = clothTiledFloor(p, accentColor, max(u.track.z, 0.5));
    float occlusion = 0.0;
    for (uint support = 0; support < 4; ++support) {
        float3 anchor = positions[uint(u.mesh.x * u.mesh.y) + support].xyz;
        float distance = length(p - anchor.xy);
        // Broad ambient occlusion plus a tight contact shadow around each foot.
        float contact = 0.42 * exp(-max(distance - 0.23, 0.0) * 9.0)
                      + 0.18 * exp(-distance * distance / 0.65);
        occlusion = max(occlusion, contact);
    }
    return color * (1.0 - occlusion);
}

static float4 clothSurface(
    ClothVertex in,
    bool frontFacing,
    texture2d<float> artwork,
    texture2d<float> shadowMask,
    constant float4 &accentColor,
    constant ClothUniforms &uniforms,
    const device float4 *normals,
    const device float4 *positions
) {
    if (uniforms.appearance.w > 3.5) return float4(1);
    if (uniforms.appearance.w > 1.5) {
        if (uniforms.appearance.w < 2.5) {
            constexpr sampler shadowFilter(filter::linear, address::clamp_to_zero);
            float2 screenUV = in.position.xy / uniforms.shadow.xw;
            float shadow = shadowMask.sample(shadowFilter, screenUV).r * uniforms.shadow.y;
            float3 floor = clothFloor(in.scenePosition.xy, positions, uniforms, accentColor.rgb) * (1.0 - shadow);
            floor *= uniforms.appearance.y;
            if (uniforms.track.y > 0.5) {
                float2 local = in.scenePosition.xy + float2(0, uniforms.mesh.w * 0.5 + 1.8);
                float railDistance = length(float2(local.x - clamp(local.x, -2.88, 2.88), local.y)) - 0.12;
                float aa = max(fwidth(railDistance), 0.008);
                float rail = 1.0 - smoothstep(-aa, aa, railDistance);
                float fill = uniforms.track.x <= 0 ? 0 : (uniforms.track.x >= 1 ? 1
                    : 1.0 - smoothstep(-3.0 + 6.0 * uniforms.track.x - aa,
                                      -3.0 + 6.0 * uniforms.track.x + aa, local.x));
                // Screen the filled portion for contrast while preserving the floor texture.
                float3 filledRail = 1.0 - (1.0 - floor) * (1.0 - 0.35);
                floor = mix(floor, mix(floor * 0.50, filledRail, fill), rail);
                for (int direction = -1; direction <= 1; direction += 2) {
                    float2 button = local - float2(float(direction) * 4.0, 0);
                    float radius = length(button);
                    float feather = max(fwidth(radius), 0.008);
                    float disk = 1.0 - smoothstep(0.5 - feather, 0.5 + feather, radius);
                    float2 icon = float2(button.x * float(direction), button.y);
                    float triangle = max(-0.15 - icon.x, abs(icon.y) - (0.30 - icon.x) * 0.6);
                    float cutout = 1.0 - smoothstep(-feather, feather, triangle);
                    floor *= mix(1.0, 0.55, disk * (1.0 - cutout));
                }
            }
            return float4(floor, 1);
        }
        float light = 0.35 + 0.65 * abs(dot(normalize(in.supportNormal), normalize(float3(-0.4, 0.6, 1))));
        float3 color = in.uv.x > 1.5 ? float3(0.085, 0.09, 0.10)
                    : in.uv.x > 0.5 ? float3(0.72, 0.65, 0.50) : float3(0.23, 0.26, 0.29);
        float contact = 0.65 + 0.35 * smoothstep(0.0, 0.65, in.scenePosition.z - uniforms.shadow.z);
        return float4(color * light * contact, 1);
    }
    if (uniforms.appearance.w > 0.5) return float4(1);
    // Triangle winding identifies the material side even inside tight folds.
    float faceBrightness = frontFacing ? 1.0 : 0.25;
    float3 normal = clothBicubicNormal(in.uv, int2(uniforms.mesh.xy), normals);
    normal = clothCameraRotation(normal, uniforms.camera.y, uniforms.camera.z);
    float3 view = normalize(float3(0, 0, uniforms.camera.w) - in.world);
    if (dot(normal, view) < 0.0) normal = -normal;
    // Match the impulse's scene-space falloff, independent of camera rotation.
    float2 impulseOffset = in.scenePosition.xy - uniforms.bass.xy;
    float radiusSquared = max(uniforms.bass.z * uniforms.bass.z, 0.0001);
    float flash = frontFacing
        ? exp(-dot(impulseOffset, impulseOffset) / radiusSquared) * uniforms.bass.w
        : 0.0;
    float3 flashColor = float3(0.85, 0.94, 1.0) * flash;
    if (uniforms.appearance.z > 0.5) {
        // Show the actual rendered triangles, including each cell's diagonal.
        // Opaque faces preserve depth occlusion when the cloth folds over itself.
        float3 edgeDistance = in.barycentric / max(fwidth(in.barycentric), float3(0.00001));
        float edge = 1.0 - smoothstep(0.5, 1.5, min(edgeDistance.x, min(edgeDistance.y, edgeDistance.z)));
        float3 meshColor = mix(float3(0.025, 0.04, 0.055), float3(0.3, 0.9, 1.0), edge);
        return float4(meshColor * faceBrightness + flashColor, 1);
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
    return float4(lit * faceBrightness + flashColor, 1);
}

struct ClothFragment {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

static float3 clothInverseCameraRotation(float3 p, float yaw, float pitch) {
    float3 q = float3(p.x, cos(pitch) * p.y - sin(pitch) * p.z,
                     sin(pitch) * p.y + cos(pitch) * p.z);
    return float3(cos(yaw) * q.x + sin(yaw) * q.y,
                  -sin(yaw) * q.x + cos(yaw) * q.y, q.z);
}

fragment ClothFragment clothVisualizerFragment(
    ClothVertex in [[stage_in]], bool frontFacing [[front_facing]],
    texture2d<float> artwork [[texture(0)]],
    texture2d<float> shadowMask [[texture(1)]],
    constant float4 &accentColor [[buffer(2)]],
    constant ClothUniforms &uniforms [[buffer(4)]],
    const device float4 *normals [[buffer(5)]],
    const device float4 *positions [[buffer(6)]]
) {
    float depth = in.position.z;
    if (uniforms.appearance.w > 1.5 && uniforms.appearance.w < 2.5) {
        // Intersect a full-screen view ray with the floor: no finite mesh edge
        // or far-plane cutoff can appear as the camera zooms out.
        float2 ndc = in.uv * float2(2, -2) + float2(-1, 1);
        float scale = min(2.6, 2.6 * uniforms.camera.x);
        float3 origin = clothInverseCameraRotation(float3(0, 0, uniforms.camera.w),
                                                    uniforms.camera.y, uniforms.camera.z);
        float3 ray = clothInverseCameraRotation(float3(ndc.x * uniforms.camera.x / scale, ndc.y / scale, -1),
                                                 uniforms.camera.y, uniforms.camera.z);
        if (abs(ray.z) < 0.000001) discard_fragment();
        float distance = (uniforms.shadow.z - origin.z) / ray.z;
        if (distance < 0.1) discard_fragment();
        in.scenePosition = origin + ray * distance;
        in.world = clothCameraRotation(in.scenePosition, uniforms.camera.y, uniforms.camera.z);
        depth = min(0.9999999, (distance - 0.1) * 100.0 / (99.9 * distance));
    }
    float4 color = clothSurface(in, frontFacing, artwork, shadowMask, accentColor, uniforms, normals, positions);
    bool isShadowMask = (uniforms.appearance.w > 0.5 && uniforms.appearance.w < 1.5)
                     || uniforms.appearance.w > 3.5;
    if (!isShadowMask) {
        // Distance fog starts just behind the subject. Anchor the clear
        // zone to the orbit distance so zooming out does not bury the cloth.
        float distance = length(float3(0, 0, uniforms.camera.w) - in.world);
        float fogDistance = max(0.0, distance - uniforms.camera.w - 2.0);
        float density = fogDistance * 0.06;
        float fog = 1.0 - exp(-density * density);
        // Match the SwiftUI sky backdrop so the horizon disappears into fog.
        color.rgb = mix(color.rgb, float3(0.035, 0.045, 0.06), fog);
    }
    return {color, depth};
}
