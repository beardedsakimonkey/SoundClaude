#include <metal_stdlib>
using namespace metal;

struct PistonUniforms {
    float4 camera; // aspect, yaw, pitch, distance
    float4 heights[2];
    float4 ropes; // half thickness, strings per piston, ground height, pass (scene, mask, floor, light, glow, sky; -1 mirrors the scene in the floor)
    float4 viewport; // drawable width and height, resting rope brightness, resting rope glow
    float4 stripes; // thickness, frequency, full-rise head twist (radians), travel
    float4 stripeColor; // linear RGB, unused
    float4 metalColor; // linear RGB, roughness
    float4 baseColor; // linear RGB, metallic
    float4 finish; // reflection strength, edge softness, neutral rope glow, bloom strength
    float4 groundColor; // linear RGB, unused
    float4 skyAccentColor; // linear RGB artwork hue, unused
    float4 lightColor; // linear RGB scene light tint with unit luminance, unused
    float4 groundAppearance; // highlight strength, softness, fog start, fog density
    float4 fogColor; // encoded RGB matching the sky backdrop, unused
    float4 lightDirection; // world-space direction toward the scene light, unused
    float4 target; // world-space point the camera orbits, unused
    float4 sky; // horizon glow, star brightness, nebula strength, time in seconds
    float4 groundDetail; // reflection strength, rope light strength, tile seam strength, rope length
};
struct PistonVertex {
    float4 position [[position]];
    float3 normal;
    float3 eye;
    float3 color;
    float2 uv;
    float3 ropeTangent;
    float4 receiver; // world position, cylinder flag
    float3 cylinderPosition; // position relative to this piston's axis
    float4 surface; // radius, bottom, top, base flag
    float stripeHeight;
    float ropeLift;
};
// Zero while a piston rests, rising to one over the lower part of its travel.
static float pistonRopeLift(uint piston, constant PistonUniforms &u) {
    float height = u.heights[piston / 4][piston % 4];
    float level = u.stripes.w > 0 ? saturate((height - 0.8) / u.stripes.w) : 0;
    return smoothstep(0.0, 0.1, level);
}
static float pistonRopeBrightness(uint piston, constant PistonUniforms &u) {
    return mix(u.viewport.z, 1.0, pistonRopeLift(piston, u));
}
static float3 pistonLightPosition(float3 p, constant PistonUniforms &u) {
    float3 light = normalize(u.lightDirection.xyz);
    float3 right = cross(float3(0, 1, 0), light);
    // A light straight overhead has no horizontal heading; pick one.
    right = length(right) > 0.0001 ? normalize(right) : float3(1, 0, 0);
    float3 up = cross(light, right);
    return float3(dot(p, right), dot(p, up), dot(p, light));
}
static float3 pistonRotate(float3 p, float yaw, float pitch) {
    p = float3(cos(yaw)*p.x + sin(yaw)*p.z, p.y, -sin(yaw)*p.x + cos(yaw)*p.z);
    return float3(p.x, cos(pitch)*p.y - sin(pitch)*p.z, sin(pitch)*p.y + cos(pitch)*p.z);
}
static float3 pistonWorldDirection(float3 p, constant PistonUniforms &u) {
    return float3(dot(p, pistonRotate(float3(1, 0, 0), u.camera.y, u.camera.z)),
                  dot(p, pistonRotate(float3(0, 1, 0), u.camera.y, u.camera.z)),
                  dot(p, pistonRotate(float3(0, 0, 1), u.camera.y, u.camera.z)));
}
static float pistonHash(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}
static float pistonNoise(float3 p) {
    float3 cell = floor(p);
    float3 f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(mix(pistonHash(cell), pistonHash(cell + float3(1, 0, 0)), f.x),
                   mix(pistonHash(cell + float3(0, 1, 0)), pistonHash(cell + float3(1, 1, 0)), f.x), f.y),
               mix(mix(pistonHash(cell + float3(0, 0, 1)), pistonHash(cell + float3(1, 0, 1)), f.x),
                   mix(pistonHash(cell + float3(0, 1, 1)), pistonHash(cell + float3(1, 1, 1)), f.x), f.y), f.z);
}
// Mean rise of the eight pistons: zero at rest, one at full travel.
static float pistonEnergy(constant PistonUniforms &u) {
    if (u.stripes.w <= 0) return 0;
    float4 low = saturate((u.heights[0] - 0.8) / u.stripes.w);
    float4 high = saturate((u.heights[1] - 0.8) / u.stripes.w);
    return (dot(low, float4(1)) + dot(high, float4(1))) / 8;
}
// A night sky for a world-space direction, added over the backdrop color:
// an afterglow behind the pistons in the artwork's hue, a drifting nebula
// lane and stars. Like the scene lighting, it fades out without an accent.
// The floor reflects and fogs toward the plain version, without `detailed`.
static float3 pistonSky(float3 d, bool detailed, constant PistonUniforms &u) {
    float presence = dot(u.lightColor.rgb, float3(0.2126, 0.7152, 0.0722));
    if (presence <= 0 || u.sky.x + u.sky.y + u.sky.z <= 0) return float3(0);
    float3 accent = u.skyAccentColor.rgb;
    float3 companion = mix(accent.gbr, accent, 0.45);
    float elevation = max(d.y, 0.0);
    // Brightest behind the pistons, so orbiting reveals a darker side.
    float2 heading = d.xz / max(length(d.xz), 0.0001);
    float facing = 0.5 - 0.5 * heading.y;
    float pulse = 0.8 + 0.45 * pistonEnergy(u);
    float3 color = float3(0.012, 0.017, 0.034) * (1 - 0.7 * elevation);
    color += mix(companion, accent, facing) * exp(-elevation * mix(9.0, 4.5, facing))
        * mix(0.06, 0.17, facing) * pulse;
    color += mix(accent, float3(1), 0.3) * exp(-elevation * 30.0) * mix(0.03, 0.08, facing) * pulse;
    color *= u.sky.x;
    if (detailed) {
        float clearSky = smoothstep(0.02, 0.3, elevation);
        // A tilted lane of slowly drifting cloud crosses the sky.
        float lane = exp(-pow(dot(d, normalize(float3(-0.5, 0.8, 0.25))) * 2.4, 2.0));
        float3 q = d * 2.6 + float3(0.013, 0.004, 0.009) * u.sky.w;
        float cloud = pistonNoise(q) * 0.5 + pistonNoise(q * 2.1 + 5.2) * 0.27
            + pistonNoise(q * 4.3 + 9.7) * 0.15 + pistonNoise(q * 8.9 + 2.3) * 0.08;
        float wisps = smoothstep(0.36, 0.8, cloud);
        float3 cloudColor = mix(companion, accent, pistonNoise(q * 0.8 + 13.1));
        color += cloudColor * wisps * (0.3 * lane + 0.03) * clearSky * u.sky.z;
        // One star at most per cell of a lattice crossed by the unit sphere.
        // Stars off the sphere show only their dimmer edge, varying their size.
        float3 p = d * 64.0;
        float3 cell = floor(p);
        float3 center = cell + 0.2 + 0.6 * float3(
            pistonHash(cell), pistonHash(cell + 17.3), pistonHash(cell + 41.9));
        // Keep each star at least a pixel wide, at constant total brightness.
        float pixel = 64.0 * 0.952 / max(u.viewport.y, 1.0);
        float radius = max(0.055, pixel * 1.1);
        float3 offset = p - center;
        float star = exp(-dot(offset, offset) / (radius * radius)) * pow(0.055 / radius, 2.0);
        float seed = pistonHash(cell + 73.1);
        float magnitude = 0.18 + 1.6 * pow(seed, 7.0);
        float twinkle = 0.72 + 0.28 * sin(u.sky.w * (0.7 + 2.6 * seed) + seed * 40.0);
        float3 starColor = mix(float3(1), mix(float3(0.7, 0.82, 1), float3(1, 0.84, 0.7), seed), 0.6);
        color += starColor * star * magnitude * twinkle * (0.6 + 0.9 * lane * wisps) * clearSky * u.sky.y;
    }
    return color * presence;
}
static float3 pistonGroundShadow(float3 p, constant PistonUniforms &u) {
    // Cast along the world-space light onto the simulation floor.
    float gap = max(0.0, p.y - u.ropes.z);
    p.xz -= u.lightDirection.xz * (gap / u.lightDirection.y);
    p.y = u.ropes.z;
    return p;
}
// The floor's reflection pass draws the scene upside down below the floor.
static float3 pistonMirror(float3 p, constant PistonUniforms &u) {
    if (u.ropes.w < -0.5) p.y = 2 * u.ropes.z - p.y;
    return p;
}
vertex PistonVertex pistonVisualizerVertex(
    uint id [[vertex_id]], const device float4 *points [[buffer(0)]],
    constant PistonUniforms &u [[buffer(1)]]
) {
    if (u.ropes.w > 4.5) {
        const float2 corners[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        PistonVertex out = {};
        out.position = float4(corners[id], 1, 1);
        return out;
    }
    const uint cylinderVertices = 32 * 12;
    const uint solidVertices = cylinderVertices * 3;
    const uint stringsPerPiston = uint(u.ropes.y);
    const uint ropeVertices = stringsPerPiston * 20 * 6;
    const uint bobVertices = 12 * 8 * 6;
    const uint verticesPerPiston = solidVertices + ropeVertices + stringsPerPiston * bobVertices;
    uint piston = id / verticesPerPiston;
    uint local = id % verticesPerPiston;
    bool isBob = local >= solidVertices + ropeVertices;
    bool glowPass = u.ropes.w > 3.5;
    bool lightPass = u.ropes.w > 2.5 && !glowPass;
    if (lightPass && local >= solidVertices && !isBob) {
        // Rope ribbons viewed from the scene light.
        uint v = local - solidVertices;
        uint segment = v / 6;
        uint index = (piston * uint(u.ropes.y) + segment / 20) * 21 + segment % 20;
        float3 a = pistonLightPosition(points[index].xyz, u);
        float3 b = pistonLightPosition(points[index + 1].xyz, u);
        float2 tangent = b.xy - a.xy;
        float2 side = float2(-tangent.y, tangent.x) / max(length(tangent), 0.00001) * u.ropes.x;
        const uint ends[6] = {0, 1, 0, 0, 1, 1};
        const float sides[6] = {-1, -1, 1, 1, -1, 1};
        float3 p = ends[v % 6] ? b : a;
        p.xy += side * sides[v % 6];
        PistonVertex out = {};
        out.position = float4(p.xy / 12, (12 - p.z) / 24, 1);
        return out;
    }
    if (u.ropes.w > 1.5 && !lightPass && !glowPass) {
        // Cover the viewport; the fragment shader intersects an infinite plane.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(-1,1),
            float2(-1,1), float2(1,-1), float2(1,1)
        };
        PistonVertex out = {};
        out.position = float4(corners[id], 0, 1);
        return out;
    }
    // Per piston: three cylinders, rope ribbons, then spherical tip bobs.
    float height = u.heights[piston / 4][piston % 4];
    float3 center = float3((float(piston)-3.5)*1.85, 0, 0);
    float3 p, n;
    float3 color = float3(0.32, 0.36, 0.42);
    float2 ropeUV = float2(0);
    float3 ropeTangent = float3(0, 1, 0);
    float stripeHeight = 0;
    float3 cylinderPosition = float3(0);
    float4 surface = float4(0);
    if (local < solidVertices) {
        bool base = local < cylinderVertices;
        bool cap = local >= cylinderVertices * 2;
        uint v = local % cylinderVertices;
        uint sector = v / 12, corner = v % 12;
        const uint ends[6] = {0, 1, 0, 0, 1, 1};
        const uint tops[6] = {0, 0, 1, 1, 0, 1};
        // A low, wide base; it stays inside the ropes, which hang at radius 0.57.
        float radius = cap ? 0.65 : (base ? 0.50 : 0.22);
        float bottom = cap ? height - 0.055 : (base ? -1.65 : -1.60);
        float top = cap ? height + 0.055 : (base ? -1.57 : height);
        surface = float4(radius, bottom, top, base ? 1.0 : 0.0);
        float twist = cap && u.stripes.w > 0
            ? clamp((height - 0.8) / u.stripes.w, 0.0, 1.0) * u.stripes.z : 0;
        if (corner < 6) {
            float angle = (float(sector + ends[corner])) * 2*M_PI_F/32 + twist;
            n = float3(cos(angle), 0, sin(angle));
            p = n*radius + float3(0, tops[corner] ? top : bottom, 0);
        } else {
            bool upper = corner >= 9;
            uint c = (corner-6)%3;
            float angle = float(sector + (c == 2 ? 1 : 0))*2*M_PI_F/32 + twist;
            p = float3(c == 0 ? 0 : radius*cos(angle), upper ? top : bottom,
                       c == 0 ? 0 : radius*sin(angle));
            n = float3(0, upper ? 1 : -1, 0);
        }
        // Shaft rings travel with the cap; base rings stay on the fixed base.
        stripeHeight = base ? p.y - bottom : p.y - top;
        cylinderPosition = p;
        p += center;
        color = base ? float3(0.11, 0.13, 0.16) : float3(0.32, 0.36, 0.42);
    } else if (isBob) {
        uint v = local - solidVertices - ropeVertices;
        uint string = piston * stringsPerPiston + v / bobVertices;
        uint cell = (v % bobVertices) / 6;
        uint corner = v % 6;
        const uint columns[6] = {0, 1, 0, 0, 1, 1};
        const uint rows[6] = {0, 0, 1, 1, 0, 1};
        float longitude = float(cell % 12 + columns[corner]) * 2 * M_PI_F / 12;
        float latitude = float(cell / 12 + rows[corner]) * M_PI_F / 8;
        n = float3(sin(latitude) * cos(longitude), cos(latitude), sin(latitude) * sin(longitude));
        // Keep the small bob visible at thin rope settings.
        float radius = max(0.045, u.ropes.x * 2.5);
        float3 tip = points[string * 21 + 20].xyz;
        // Rest the bob on the floor while the rope tip stays inside it.
        tip.y = max(tip.y, u.ropes.z + radius);
        if (glowPass) {
            // A camera-facing disc lets the bob's halo fade softly like the ropes'.
            // Only the first quad is drawn; the remaining vertices collapse.
            const float2 quad[6] = {
                float2(-1,-1), float2(1,-1), float2(-1,1),
                float2(-1,1), float2(1,-1), float2(1,1)
            };
            float2 offset = v % bobVertices < 6 ? quad[v % 6] : float2(0);
            p = pistonRotate(tip - u.target.xyz, u.camera.y, u.camera.z);
            // Sit on the bob's front so its own depth cannot hide the halo.
            p += float3(offset * radius * 2.5, radius);
            n = float3(offset, 0);
        } else {
            p = tip + n * radius;
        }
        surface.w = -1; // Preserve the sphere normal when shading the rope color.
        uint localString = string % stringsPerPiston;
        ropeUV = float2(0, localString % 2 == 0 ? 2.0 : 1.0);
        color = localString % 2 == 0
            ? 0.55 + 0.45 * cos(float(piston) * 0.47 + float3(0, 2, 4))
            : float3(0.65);
    } else {
        uint v = local - solidVertices;
        uint segment = v/6;
        uint localString = segment/20;
        uint string = piston*stringsPerPiston + localString;
        uint index = string*21 + segment%20;
        float3 a = points[index].xyz;
        float3 b = points[index+1].xyz;
        if (u.ropes.w > 0.5 && !glowPass) {
            a = pistonGroundShadow(a, u);
            b = pistonGroundShadow(b, u);
        }
        a = pistonMirror(a, u);
        b = pistonMirror(b, u);
        a = pistonRotate(a-u.target.xyz,u.camera.y,u.camera.z);
        b = pistonRotate(b-u.target.xyz,u.camera.y,u.camera.z);
        float2 tangent = b.xy-a.xy;
        float2 side = float2(-tangent.y,tangent.x) / max(length(tangent),0.00001)*u.ropes.x;
        const uint ends[6] = {0,1,0,0,1,1};
        const float sides[6] = {-1,-1,1,1,-1,1};
        p = ends[v%6] ? b : a;
        p.xy += side*sides[v%6] * (glowPass ? 5.0 : 1.0);
        // Smooth the lighting through segment joints using neighboring nodes.
        uint node = segment % 20 + ends[v%6];
        uint root = string * 21;
        float3 tangent3 = points[root + min(node + 1, 20u)].xyz
                       - points[root + (node > 0 ? node - 1 : 0)].xyz;
        if (u.ropes.w < -0.5) tangent3.y = -tangent3.y;
        tangent3 = pistonRotate(tangent3, u.camera.y, u.camera.z);
        ropeTangent = length(tangent3) > 0.00001 ? normalize(tangent3) : float3(0, 1, 0);
        ropeUV = float2(sides[v%6], localString % 2 == 0 ? 2.0 : 1.0);
        n = float3(0,0,1);
        // Alternate each piston's color with a neutral gray around the perimeter.
        float phase = float(piston)*0.47;
        color = localString % 2 == 0
            ? 0.55 + 0.45*cos(phase + float3(0, 2, 4))
            : float3(0.65);
    }
    float4 receiver = float4(0);
    if (local < solidVertices || (isBob && !glowPass)) {
        if (lightPass) {
            // Use the same cap geometry for the scene and its cylinder shadow.
            float3 lightPosition = pistonLightPosition(p, u);
            PistonVertex out = {};
            out.position = float4(lightPosition.xy / 12, (12 - lightPosition.z) / 24, 1);
            return out;
        }
        receiver = float4(p, local < cylinderVertices * 2 ? 1.0 : 0.0);
        if (u.ropes.w > 0.5 && !glowPass) p = pistonGroundShadow(p, u);
        // Shade the mirror image with its real position, kept in the receiver.
        p = pistonMirror(p, u);
        if (u.ropes.w < -0.5) n.y = -n.y;
        p = pistonRotate(p-u.target.xyz,u.camera.y,u.camera.z);
        n = pistonRotate(n,u.camera.y,u.camera.z);
    }
    float depth = u.camera.w-p.z;
    PistonVertex out;
    out.position = float4(p.x*2.1/u.camera.x,p.y*2.1,depth*100/(100-0.1)-100*0.1/(100-0.1),depth);
    out.normal = n;
    out.eye = float3(-p.x,-p.y,depth);
    out.color = color;
    out.uv = ropeUV;
    out.ropeTangent = ropeTangent;
    out.receiver = receiver;
    out.cylinderPosition = cylinderPosition;
    out.surface = surface;
    out.stripeHeight = stripeHeight;
    out.ropeLift = pistonRopeLift(piston, u);
    return out;
}
struct PistonFragment {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};
static float3 pistonMetal(float3 n, float3 view, float3 light, float3 tint,
                          float roughness, float metallic) {
    float3 h = normalize(light + view);
    float nv = max(dot(n, view), 0.001);
    float nl = max(dot(n, light), 0.0);
    float nh = max(dot(n, h), 0.0);
    float vh = max(dot(view, h), 0.0);
    float a = roughness * roughness;
    float a2 = a * a;
    float d = nh * nh * (a2 - 1) + 1;
    float distribution = a2 / max(M_PI_F * d * d, 0.00001);
    float k = (roughness + 1) * (roughness + 1) / 8;
    float geometry = nv / (nv * (1 - k) + k) * nl / (nl * (1 - k) + k);
    float3 f0 = mix(float3(0.04), tint, metallic);
    float3 fresnel = f0 + (1 - f0) * pow(1 - vh, 5.0);
    return ((1 - fresnel) * (1 - metallic) * tint / M_PI_F
        + distribution * geometry * fresnel / max(4 * nv * nl, 0.001)) * nl;
}

// An analytic studio environment: tall softboxes and an overhead fill, all
// tinted by the scene light. Reflection directions are in world space so
// highlights move with the camera.
static float3 pistonStudio(float3 r, float roughness, float3 light) {
    float blur = roughness * roughness;
    float key = exp(-pow((r.x + 0.48) / (0.15 + blur), 2.0)
                    -pow((r.y - 0.32) / (0.8 + blur), 2.0)) * smoothstep(-0.2, 0.4, r.z);
    float rim = exp(-pow((r.x - 0.8) / (0.12 + blur), 2.0)
                    -pow((r.y - 0.15) / (0.7 + blur), 2.0));
    float overhead = pow(max(r.y, 0.0), mix(12.0, 3.0, roughness));
    return (mix(0.044, 0.216, r.y * 0.5 + 0.5) + 1.82 * key + 0.92 * rim + 0.59 * overhead)
        * light;
}
// Approximate each rope with ten segments for a soft local reflection.
// Sample simulation positions so the reflected streaks follow the moving ropes.
static float3 pistonRopeReflection(float3 origin, float3 direction, float roughness,
                                   uint piston, constant PistonUniforms &u,
                                   const device float4 *points) {
    float2 energy = float2(0);
    uint strings = uint(u.ropes.y);
    float footprint = max(length(dfdx(origin)), length(dfdy(origin)));
    for (uint string = 0; string < strings; ++string) {
        uint root = (piston * strings + string) * 21;
        float ropeEnergy = 0;
        for (uint node = 0; node < 20; node += 2) {
            float3 a = points[root + node].xyz - origin;
            float3 segment = points[root + node + 2].xyz - points[root + node].xyz;
            // Closest point on the segment to the reflected view ray.
            float projection = dot(segment, direction);
            float denominator = max(dot(segment, segment) - projection * projection, 0.000001);
            float t = saturate((projection * dot(a, direction) - dot(a, segment)) / denominator);
            float3 offset = a + segment * t;
            float along = dot(offset, direction);
            if (along <= 0.001) continue;
            float3 separation = offset - direction * along;
            float width = u.ropes.x + along * roughness * roughness * 0.6 + footprint;
            float response = exp(-dot(separation, separation) / (width * width));
            response *= u.ropes.x / width / (1 + along * along * 0.12);
            // Avoid bright seams where adjacent segments meet.
            ropeEnergy = max(ropeEnergy, response);
        }
        energy[string % 2] += ropeEnergy;
    }
    float3 color = 0.55 + 0.45 * cos(float(piston) * 0.47 + float3(0, 2, 4));
    return (color * min(energy.x * 3.0, 4.0)
        + float3(0.65) * min(energy.y * 3.0, 4.0) * saturate(u.finish.z))
        * pistonRopeBrightness(piston, u);
}
fragment PistonFragment pistonVisualizerFragment(
    PistonVertex in [[stage_in]],
    constant PistonUniforms &u [[buffer(4)]],
    const device float4 *points [[buffer(6)]],
    texture2d<float> shadowMask [[texture(1)]],
    texture2d<float> ropeShadow [[texture(2)]],
    texture2d<float> floorReflection [[texture(3)]]
) {
    if (u.ropes.w > 4.5) {
        float2 ndc = in.position.xy / u.viewport.xy * float2(2, -2) + float2(-1, 1);
        float3 direction = pistonWorldDirection(
            normalize(float3(ndc.x * u.camera.x / 2.1, ndc.y / 2.1, -1)), u);
        float3 sky = pistonSky(direction, true, u);
        // A disabled sky leaves the pass transparent over the backdrop.
        float cover = any(sky > 0) ? 1.0 : 0.0;
        float4 surface = float4(saturate(u.fogColor.rgb + sky) * cover, cover);
        return {surface, 1};
    }
    if (u.ropes.w > 3.5) {
        if (in.uv.y < 0.5) discard_fragment();
        float glowStrength = in.uv.y > 1.5 ? 1.0 : saturate(u.finish.z);
        // Bob discs carry their corner offset in the normal for a radial falloff.
        float across = in.surface.w < 0 ? length(in.normal.xy) : abs(in.uv.x);
        float halo = exp(-across * across * 6.0) * (1 - smoothstep(0.65, 1.0, across));
        // Resting ropes keep a faint halo; it fades in with their brightness.
        float3 emission = in.color * halo * 0.28 * glowStrength * mix(u.viewport.w, 1.0, in.ropeLift) * u.finish.w;
        float alpha = max(emission.r, max(emission.g, emission.b));
        // The wider halo rasterizes the rope's plane again. Its interpolated
        // depth can round behind the opaque rope, causing speckles in both
        // the visible halo and bloom source. Bias only the glow depth slightly
        // forward; depth writes stay disabled so scene occlusion is preserved.
        return {float4(emission, alpha), max(0.0, in.position.z - 0.000002)};
    }
    if (u.ropes.w > 2.5) return {float4(float3(in.position.z), 1), in.position.z};
    if (u.ropes.w > 1.5) {
        constexpr sampler shadowFilter(filter::linear, address::clamp_to_zero);
        // The mask uses this same camera projection; sample at the floor pixel.
        float2 uv = in.position.xy / u.viewport.xy;
        float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
        float3 ray = float3(ndc.x * u.camera.x / 2.1, ndc.y / 2.1, -1);
        float3 n = pistonRotate(float3(0, 1, 0), u.camera.y, u.camera.z);
        float3 origin = float3(0, 0, u.camera.w);
        float denominator = dot(n, ray);
        if (abs(denominator) < 0.000001) discard_fragment();
        float distance = (u.ropes.z - u.target.y - dot(n, origin)) / denominator;
        if (distance < 0.1) discard_fragment();
        float3 p = origin + ray * distance;
        float2 floorPosition = float2(
            dot(p, pistonRotate(float3(1, 0, 0), u.camera.y, u.camera.z)),
            dot(p, pistonRotate(float3(0, 0, 1), u.camera.y, u.camera.z))) + u.target.xz;
        // Preserve scene occlusion, while keeping the floor beyond the far clip.
        float depth = min((distance - 0.1) * 100 / (99.9 * distance), 0.999999);
        float opacity = shadowMask.sample(shadowFilter, uv).r * 0.48;
        float3 light = normalize(pistonRotate(u.lightDirection.xyz, u.camera.y, u.camera.z));
        float3 view = normalize(-ray);
        float diffuse = max(0.0, dot(n, light));
        // Keep the broad light pool fixed on the floor as the camera orbits,
        // shifted toward the light's side of the scene.
        float2 poolCenter = u.lightDirection.xz / u.lightDirection.y * 1.2;
        float2 poolOffset = (floorPosition - poolCenter) / float2(11, 7);
        float pool = exp(-dot(poolOffset, poolOffset));
        float exponent = mix(64.0, 4.0, saturate(u.groundAppearance.y));
        float specular = pow(max(0.0, dot(n, normalize(light + view))), exponent);
        float3 groundTint = u.groundColor.rgb / float3(0.19, 0.21, 0.24);
        float3 ambient = 0.032 * groundTint * u.lightColor.rgb;
        float3 diffuseColor = u.groundColor.rgb * diffuse * pool * u.lightColor.rgb;
        float3 highlight = u.groundAppearance.x * groundTint * specular * pool * u.lightColor.rgb;
        // Approximate each cap's ambient occlusion with a soft footprint.
        // Raised caps cast a wider, weaker patch; low caps darken contact areas.
        float occlusion = 0;
        for (uint piston = 0; piston < 8; ++piston) {
            float height = u.heights[piston / 4][piston % 4];
            float gap = max(0.0, height - 0.055 - u.ropes.z);
            float2 offset = floorPosition - float2((float(piston) - 3.5) * 1.85, 0);
            float radius = 0.75 + gap * 0.4;
            float footprint = exp(-dot(offset, offset) / (radius * radius));
            occlusion += footprint * 0.72 / (1.0 + gap * gap * 0.65);
        }
        float visibility = exp(-occlusion);
        float3 floorColor = ambient * visibility
            + (diffuseColor * mix(1.0, visibility, 0.65) + highlight * visibility)
            * (1.0 - opacity);
        // Large slabs, one per piston, with thin seams that fade once a
        // pixel spans several of them. Each slab has its own polish.
        float2 tile = floorPosition / 1.85 - float2(0, 0.5);
        float2 tileFootprint = max(fwidth(tile), 0.00001);
        float2 seamDistance = 0.5 - abs(fract(tile) - 0.5);
        float2 seams = 1 - smoothstep(float2(0.004), 0.004 + tileFootprint, seamDistance);
        float tileDetail = (1 - smoothstep(0.08, 0.45, max(tileFootprint.x, tileFootprint.y)))
            * saturate(u.groundDetail.z);
        float seam = max(seams.x, seams.y) * tileDetail;
        float polish = 1 - (0.35 * pistonHash(float3(floor(tile), 3.7)) + 0.6 * seam) * tileDetail;
        floorColor *= 1 - 0.6 * seam;
        // Each ring of glowing ropes lights the floor below it. Raised ropes
        // spread a wider, fainter pool.
        float3 ropeLight = float3(0);
        for (uint piston = 0; piston < 8; ++piston) {
            float top = u.heights[piston / 4][piston % 4] - 0.055;
            float gap = max(0.0, top - u.groundDetail.w - u.ropes.z);
            float3 ropeColor = (0.36 * (0.55 + 0.45 * cos(float(piston) * 0.47 + float3(0, 2, 4)))
                + 0.12 * saturate(u.finish.z)) * pistonRopeBrightness(piston, u);
            float2 offset = floorPosition - float2((float(piston) - 3.5) * 1.85, 0);
            float spread = max(0.0, length(offset) - 0.57) / (0.5 + 0.8 * gap);
            ropeLight += ropeColor / ((1 + spread * spread) * (1 + spread * spread) * (1 + 0.9 * gap));
        }
        floorColor += ropeLight * groundTint * u.groundDetail.y * (1 - 0.4 * seam)
            * mix(1.0, visibility, 0.5);
        // A polished floor mirrors the sky and the scene, most at grazing angles.
        float3 worldRay = pistonWorldDirection(normalize(ray), u);
        float mirror = (0.04 + 0.96 * pow(1 - saturate(-worldRay.y), 5.0))
            * saturate(u.groundDetail.x * polish);
        float3 reflection = pistonSky(float3(worldRay.x, -worldRay.y, worldRay.z), false, u);
        if (u.groundDetail.x > 0) {
            constexpr sampler reflectionFilter(filter::linear, address::clamp_to_edge);
            // Smear the blurred mirror image vertically, like a wet street.
            float4 mirrored = float4(0);
            const float weights[5] = {0.12, 0.23, 0.3, 0.23, 0.12};
            for (int tap = 0; tap < 5; ++tap) {
                mirrored += weights[tap] * floorReflection.sample(
                    reflectionFilter, uv + float2(0, float(tap - 2) * 0.007));
            }
            reflection = reflection * (1 - saturate(mirrored.a)) + mirrored.rgb;
        }
        floorColor = floorColor * (1 - mirror) + reflection * mirror;
        // Distance fog converges to the exact sky color, rather than fading the
        // floor by viewing angle. A clear near region preserves its material.
        float fogDistance = max(0.0, distance * length(ray) - u.groundAppearance.z);
        // The haze lies in a low layer over the floor. A camera above it looks
        // through less of it, so the floor clears when seen from overhead.
        float cameraHeight = pistonWorldDirection(float3(0, 0, u.camera.w), u).y + u.target.y - u.ropes.z;
        float opticalDepth = fogDistance * max(0.0, u.groundAppearance.w)
            * min(1.0, 1.5 / max(cameraHeight, 0.01));
        float transmission = exp(-opticalDepth);
        const float floorAlpha = 0.88;
        float4 clearFloor = float4(floorColor * floorAlpha, floorAlpha);
        // The sky at this pixel's heading on the horizon, as its own pass draws it.
        float3 horizon = normalize(float3(worldRay.x, 0, worldRay.z) + float3(0, 0, 0.000001));
        float4 fog = float4(saturate(u.fogColor.rgb + pistonSky(horizon, false, u)), 1);
        float4 foggedFloor = mix(fog, clearFloor, transmission);
        return {foggedFloor, depth};
    }
    if (u.ropes.w > 0.5) return {float4(1), in.position.z};

    float3 n = normalize(in.normal);
    bool isRope = in.uv.y > 0.5;
    // Keep rope lighting independent of camera distance.
    float3 lightingView = isRope ? float3(0, 0, 1) : normalize(in.eye);
    if (isRope && in.surface.w >= 0) {
        // Reconstruct a round cross-section across the camera-facing ribbon.
        float3 tangent = normalize(in.ropeTangent);
        float3 side = cross(lightingView, tangent);
        if (dot(side, side) < 0.000001) side = cross(float3(0, 1, 0), tangent);
        side = normalize(side);
        float3 front = normalize(cross(tangent, side));
        float across = clamp(in.uv.x, -1.0, 1.0);
        n = normalize(side * across + front * sqrt(max(0.0, 1.0 - across * across)));
    }
    // The mirror image is lit by a mirrored world.
    float3 up = float3(1, u.ropes.w < -0.5 ? -1 : 1, 1);
    float3 light = normalize(pistonRotate(u.lightDirection.xyz * up, u.camera.y, u.camera.z));
    float diffuse = max(0.0,dot(n,light));
    float specular = pow(max(0.0,dot(n,normalize(light+lightingView))), isRope ? 24.0 : 48.0);
    float stripe = 0;
    float3 cylinderAxis = pistonRotate(float3(0, up.y, 0), u.camera.y, u.camera.z);
    if (in.receiver.w > 0.5 && abs(dot(n, cylinderAxis)) < 0.5 && u.stripes.x > 0) {
        // Fixed spacing around cylinder walls, with filtered edges at any zoom.
        float phase = in.stripeHeight * u.stripes.y;
        float coverage = clamp(u.stripes.x * u.stripes.y, 0.0, 1.0);
        float distance = abs(fract(phase + 0.5) - 0.5);
        float footprint = max(fwidth(phase), 0.0001);
        stripe = 1.0 - smoothstep((coverage - footprint) * 0.5,
                                  (coverage + footprint) * 0.5, distance);
        // Unresolved rings blend into their average coverage instead of flickering.
        stripe = mix(stripe, coverage, smoothstep(0.5, 1.0, footprint));
    }
    float3 color = mix(in.color, u.stripeColor.rgb, stripe);
    specular *= mix(1.0, 0.35, stripe);
    float visibility = 1;
    if (in.receiver.w > 0.5 && diffuse > 0) {
        float3 p = pistonLightPosition(in.receiver.xyz, u);
        float2 uv = float2(p.x / 24 + 0.5, 0.5 - p.y / 24);
        float depth = (12 - p.z) / 24 - 0.00015;
        constexpr sampler comparison(filter::nearest, address::clamp_to_edge);
        float2 texel = 1.0 / float2(ropeShadow.get_width(), ropeShadow.get_height());
        float lit = 0;
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x)
                lit += depth <= ropeShadow.sample(comparison, uv + float2(x, y) * texel).r ? 1.0 : 0.0;
        visibility = mix(0.18, 1.0, lit / 9);
    }
    float jointVisibility = 1;
    if (in.receiver.w > 0.5) {
        // Fake crevice occlusion where the shaft (radius 0.22) enters the
        // base's top at y = -1.57. Fade up the shaft and across the base lip.
        float2 jointDistance = float2(
            (length(in.cylinderPosition.xz) - 0.22) / 0.085,
            (in.cylinderPosition.y + 1.57) / 0.16);
        jointVisibility -= 0.30 * exp(-dot(jointDistance, jointDistance));
    }
    float3 shaded = color * (0.28 * jointVisibility + 0.72 * diffuse * visibility
        * mix(1.0, jointVisibility, 0.65))
        + specular * (isRope ? 0.3 : 0.5) * visibility * jointVisibility;
    if (isRope) {
        // Emissive color and a pale core stay bright on the unlit side.
        float core = in.surface.w < 0 ? pow(max(0.0, n.z), 8.0)
            : pow(max(0.0, 1.0 - in.uv.x * in.uv.x), 3.0);
        float3 emissive = in.color * (0.8 + 0.2 * diffuse) + float3(0.24) * core;
        shaded = mix(shaded, emissive, in.uv.y > 1.5 ? 1.0 : saturate(u.finish.z));
        shaded *= mix(u.viewport.z, 1.0, in.ropeLift);
    }
    if (!isRope) {
        float radialDistance = length(in.cylinderPosition.xz);
        float3 radial = float3(in.cylinderPosition.x, 0, in.cylinderPosition.z)
            / max(radialDistance, 0.0001);
        radial = pistonRotate(radial, u.camera.y, u.camera.z);
        bool endFace = abs(dot(n, cylinderAxis)) > 0.5;
        // Small normal bevels catch the light along the machined edges.
        float bevel = max(u.finish.y, 0.00001);
        if (u.finish.y > 0 && endFace) {
            float edge = smoothstep(in.surface.x - bevel, in.surface.x, radialDistance);
            n = normalize(mix(n, normalize(n + radial), edge));
        } else if (u.finish.y > 0) {
            float topEdge = 1 - smoothstep(0.0, bevel, in.surface.z - in.cylinderPosition.y);
            float bottomEdge = 1 - smoothstep(0.0, bevel, in.cylinderPosition.y - in.surface.y);
            n = normalize(n + cylinderAxis * (topEdge - bottomEdge));
        }
        float base = in.surface.w;
        float3 metalColor = mix(u.metalColor.rgb, u.baseColor.rgb, base);
        float3 tint = mix(metalColor, u.stripeColor.rgb, stripe);
        float roughness = clamp(u.metalColor.w + mix(endFace ? 0.08 : 0.0, 0.20, base)
                                + stripe * 0.16, 0.08, 1.0);
        float metallic = mix(u.baseColor.w, min(u.baseColor.w, 0.25), stripe);
        float3 view = normalize(in.eye);
        float3 reflection = reflect(-view, n);
        float3 worldReflection = float3(
            dot(reflection, pistonRotate(float3(1, 0, 0), u.camera.y, u.camera.z)),
            dot(reflection, cylinderAxis),
            dot(reflection, pistonRotate(float3(0, 0, 1), u.camera.y, u.camera.z)));
        float nv = max(dot(n, view), 0.0);
        float3 f0 = mix(float3(0.04), tint, metallic);
        float3 fresnel = f0 + (max(float3(1 - roughness), f0) - f0) * pow(1 - nv, 5.0);
        float3 environment = pistonStudio(worldReflection, roughness, u.lightColor.rgb) * fresnel
            * (1 - 0.4 * roughness) * u.finish.x;
        float centerX = in.receiver.x - in.cylinderPosition.x;
        uint piston = uint(clamp(round(centerX / 1.85 + 3.5), 0.0, 7.0));
        if (u.finish.x > 0) {
            environment += pistonRopeReflection(in.receiver.xyz, worldReflection, roughness,
                                                 piston, u, points) * fresnel * u.finish.x;
        }
        float3 direct = pistonMetal(n, view, light, tint, roughness, metallic)
            * 2.49 * u.lightColor.rgb * visibility;
        shaded = (environment + tint * (1 - metallic) * 0.18 + direct) * jointVisibility;
        // Soft highlight rolloff keeps bright reflections from clipping.
        shaded = shaded / (1 + shaded);
    }
    return {float4(shaded, 1), in.position.z};
}

struct PistonBloomVertex {
    float4 position [[position]];
    float2 uv;
};
vertex PistonBloomVertex pistonBloomVertex(uint id [[vertex_id]]) {
    const float2 corners[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    float2 p = corners[id];
    return {float4(p, 0, 1), float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5)};
}
fragment float4 pistonBloomFragment(PistonBloomVertex in [[stage_in]],
                                    texture2d<float> bloom [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    // Keep RGB within alpha, including where the floor fades into the backdrop.
    float3 emission = saturate(bloom.sample(linearSampler, in.uv).rgb * 2.0);
    float alpha = max(emission.r, max(emission.g, emission.b));
    return float4(emission, alpha);
}
