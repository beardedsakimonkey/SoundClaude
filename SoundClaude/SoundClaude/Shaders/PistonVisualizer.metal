#include <metal_stdlib>
using namespace metal;

struct PistonUniforms {
    float4 camera; // aspect, yaw, pitch, distance
    float4 heights[2];
    float4 ropes; // half thickness, strings per piston, ground height, pass (scene, mask, floor, light)
    float4 viewport; // drawable width and height, unused
    float4 stripes; // thickness, frequency, unused
    float4 stripeColor; // linear RGB, unused
    float4 metalColor; // linear RGB, unused
    float4 baseColor; // linear RGB, unused
    float4 material; // roughness, metallic, grain strength, grain density
    float4 finish; // reflection strength, edge softness, unused
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
};
static float3 pistonLightPosition(float3 p) {
    float3 light = normalize(float3(-0.4, 0.8, 1));
    float3 right = normalize(cross(float3(0, 1, 0), light));
    float3 up = cross(light, right);
    return float3(dot(p, right), dot(p, up), dot(p, light));
}
static float3 pistonRotate(float3 p, float yaw, float pitch) {
    p = float3(cos(yaw)*p.x + sin(yaw)*p.z, p.y, -sin(yaw)*p.x + cos(yaw)*p.z);
    return float3(p.x, cos(pitch)*p.y - sin(pitch)*p.z, sin(pitch)*p.y + cos(pitch)*p.z);
}
static float3 pistonGroundShadow(float3 p, constant PistonUniforms &u) {
    // Cast along the world-space light onto the simulation floor.
    float gap = max(0.0, p.y - u.ropes.z);
    p.xz -= float2(-0.4, 1.0) * (gap / 0.8);
    p.y = u.ropes.z;
    return p;
}
vertex PistonVertex pistonVisualizerVertex(
    uint id [[vertex_id]], const device float4 *points [[buffer(0)]],
    constant PistonUniforms &u [[buffer(1)]]
) {
    const uint cylinderVertices = 32 * 12;
    const uint solidVertices = cylinderVertices * 3;
    const uint stringsPerPiston = uint(u.ropes.y);
    const uint ropeVertices = stringsPerPiston * 20 * 6;
    uint piston = id / (solidVertices + ropeVertices);
    uint local = id % (solidVertices + ropeVertices);
    bool lightPass = u.ropes.w > 2.5;
    if (lightPass && local >= solidVertices) {
        // Rope ribbons viewed from the scene light.
        uint v = local - solidVertices;
        uint segment = v / 6;
        uint index = (piston * uint(u.ropes.y) + segment / 20) * 21 + segment % 20;
        float3 a = pistonLightPosition(points[index].xyz);
        float3 b = pistonLightPosition(points[index + 1].xyz);
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
    if (u.ropes.w > 1.5 && !lightPass) {
        // Cover the viewport; the fragment shader intersects an infinite plane.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(-1,1),
            float2(-1,1), float2(1,-1), float2(1,1)
        };
        PistonVertex out = {};
        out.position = float4(corners[id], 0, 1);
        return out;
    }
    // Per piston: three 32-sided cylinders, then rope ribbons.
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
        float radius = cap ? 0.65 : (base ? 0.38 : 0.22);
        float bottom = cap ? height - 0.055 : (base ? -1.65 : -1.53);
        float top = cap ? height + 0.055 : (base ? -1.41 : height);
        surface = float4(radius, bottom, top, base ? 1.0 : 0.0);
        if (corner < 6) {
            float angle = (float(sector + ends[corner])) * 2*M_PI_F/32;
            n = float3(cos(angle), 0, sin(angle));
            p = n*radius + float3(0, tops[corner] ? top : bottom, 0);
        } else {
            bool upper = corner >= 9;
            uint c = (corner-6)%3;
            float angle = float(sector + (c == 2 ? 1 : 0))*2*M_PI_F/32;
            p = float3(c == 0 ? 0 : radius*cos(angle), upper ? top : bottom,
                       c == 0 ? 0 : radius*sin(angle));
            n = float3(0, upper ? 1 : -1, 0);
        }
        // Shaft rings travel with the cap; base rings stay on the fixed base.
        stripeHeight = base ? p.y - bottom : p.y - top;
        cylinderPosition = p;
        p += center;
        color = base ? float3(0.11, 0.13, 0.16) : float3(0.32, 0.36, 0.42);
    } else {
        uint v = local - solidVertices;
        uint segment = v/6;
        uint localString = segment/20;
        uint string = piston*stringsPerPiston + localString;
        uint index = string*21 + segment%20;
        float3 a = points[index].xyz;
        float3 b = points[index+1].xyz;
        if (u.ropes.w > 0.5) {
            a = pistonGroundShadow(a, u);
            b = pistonGroundShadow(b, u);
        }
        a = pistonRotate(a-float3(0,1,0),u.camera.y,u.camera.z);
        b = pistonRotate(b-float3(0,1,0),u.camera.y,u.camera.z);
        float2 tangent = b.xy-a.xy;
        float2 side = float2(-tangent.y,tangent.x) / max(length(tangent),0.00001)*u.ropes.x;
        const uint ends[6] = {0,1,0,0,1,1};
        const float sides[6] = {-1,-1,1,1,-1,1};
        p = ends[v%6] ? b : a;
        p.xy += side*sides[v%6];
        // Smooth the lighting through segment joints using neighboring nodes.
        uint node = segment % 20 + ends[v%6];
        uint root = string * 21;
        float3 tangent3 = points[root + min(node + 1, 20u)].xyz
                       - points[root + (node > 0 ? node - 1 : 0)].xyz;
        tangent3 = pistonRotate(tangent3, u.camera.y, u.camera.z);
        ropeTangent = length(tangent3) > 0.00001 ? normalize(tangent3) : float3(0, 1, 0);
        ropeUV = float2(sides[v%6], 1);
        n = float3(0,0,1);
        // Alternate each piston's color with a neutral gray around the perimeter.
        float phase = float(piston)*0.47;
        color = localString % 2 == 0
            ? 0.55 + 0.45*cos(phase + float3(0, 2, 4))
            : float3(0.65);
    }
    float4 receiver = float4(0);
    if (local < solidVertices) {
        if (lightPass) {
            // Use the same cap geometry for the scene and its cylinder shadow.
            float3 lightPosition = pistonLightPosition(p);
            PistonVertex out = {};
            out.position = float4(lightPosition.xy / 12, (12 - lightPosition.z) / 24, 1);
            return out;
        }
        receiver = float4(p, local < cylinderVertices * 2 ? 1.0 : 0.0);
        if (u.ropes.w > 0.5) p = pistonGroundShadow(p, u);
        p = pistonRotate(p-float3(0,1,0),u.camera.y,u.camera.z);
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
    return out;
}
struct PistonFragment {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};
// Filter machining marks before they become smaller than a pixel.
static float pistonGrain(float coordinate) {
    float footprint = fwidth(coordinate);
    return sin(coordinate * 2 * M_PI_F) * (1 - smoothstep(0.2, 0.65, footprint));
}
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

// An analytic studio environment: tall cool softboxes and a warm overhead fill.
// Reflection directions are in world space so highlights move with the camera.
static float3 pistonStudio(float3 r, float roughness) {
    float blur = roughness * roughness;
    float key = exp(-pow((r.x + 0.48) / (0.15 + blur), 2.0)
                    -pow((r.y - 0.32) / (0.8 + blur), 2.0)) * smoothstep(-0.2, 0.4, r.z);
    float rim = exp(-pow((r.x - 0.8) / (0.12 + blur), 2.0)
                    -pow((r.y - 0.15) / (0.7 + blur), 2.0));
    float overhead = pow(max(r.y, 0.0), mix(12.0, 3.0, roughness));
    return mix(float3(0.035, 0.045, 0.065), float3(0.18, 0.22, 0.29), r.y * 0.5 + 0.5)
        + float3(1.65, 1.85, 2.1) * key + float3(0.7, 0.95, 1.3) * rim
        + float3(0.7, 0.57, 0.42) * overhead;
}
fragment PistonFragment pistonVisualizerFragment(
    PistonVertex in [[stage_in]],
    constant PistonUniforms &u [[buffer(4)]],
    texture2d<float> shadowMask [[texture(1)]],
    texture2d<float> ropeShadow [[texture(2)]]
) {
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
        float distance = (u.ropes.z - 1 - dot(n, origin)) / denominator;
        if (distance < 0.1) discard_fragment();
        float3 p = origin + ray * distance;
        float2 floorPosition = float2(
            dot(p, pistonRotate(float3(1, 0, 0), u.camera.y, u.camera.z)),
            dot(p, pistonRotate(float3(0, 0, 1), u.camera.y, u.camera.z)));
        // Preserve scene occlusion, while keeping the floor beyond the far clip.
        float depth = min((distance - 0.1) * 100 / (99.9 * distance), 0.999999);
        float opacity = shadowMask.sample(shadowFilter, uv).r * 0.48;
        float3 light = normalize(pistonRotate(float3(-0.4, 0.8, 1), u.camera.y, u.camera.z));
        float3 view = normalize(-ray);
        float diffuse = max(0.0, dot(n, light));
        // Keep the broad light pool fixed on the floor as the camera orbits.
        float2 poolOffset = (floorPosition - float2(-2, 1.5)) / float2(11, 7);
        float pool = exp(-dot(poolOffset, poolOffset));
        float specular = pow(max(0.0, dot(n, normalize(light + view))), 18.0);
        float3 ambient = float3(0.025, 0.033, 0.048);
        float3 diffuseColor = float3(0.19, 0.21, 0.24) * diffuse * pool;
        float3 highlight = float3(0.24, 0.26, 0.30) * specular * pool;
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
        // Fade into the artwork backdrop at the horizon. The transparent
        // Metal view expects premultiplied color for its SwiftUI composite.
        float horizonFade = smoothstep(0.015, 0.24, abs(dot(n, view)));
        float distanceFade = exp(-dot(floorPosition, floorPosition) / 900.0);
        float floorAlpha = 0.88 * horizonFade * distanceFade;
        return {float4(floorColor * floorAlpha, floorAlpha), depth};
    }
    if (u.ropes.w > 0.5) return {float4(1), in.position.z};

    float3 n = normalize(in.normal);
    bool isRope = in.uv.y > 0.5;
    if (isRope) {
        // Reconstruct a round cross-section across the camera-facing ribbon.
        float3 tangent = normalize(in.ropeTangent);
        float3 side = cross(normalize(in.eye), tangent);
        if (dot(side, side) < 0.000001) side = cross(float3(0, 1, 0), tangent);
        side = normalize(side);
        float3 front = normalize(cross(tangent, side));
        float across = clamp(in.uv.x, -1.0, 1.0);
        n = normalize(side * across + front * sqrt(max(0.0, 1.0 - across * across)));
    }
    float3 light = normalize(pistonRotate(float3(-0.4,0.8,1), u.camera.y, u.camera.z));
    float diffuse = max(0.0,dot(n,light));
    float specular = pow(max(0.0,dot(n,normalize(light+normalize(in.eye)))), isRope ? 24.0 : 48.0);
    float stripe = 0;
    float3 cylinderAxis = pistonRotate(float3(0, 1, 0), u.camera.y, u.camera.z);
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
        float3 p = pistonLightPosition(in.receiver.xyz);
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
        // base's top at y = -1.41. Fade up the shaft and across the base lip.
        float2 jointDistance = float2(
            (length(in.cylinderPosition.xz) - 0.22) / 0.085,
            (in.cylinderPosition.y + 1.41) / 0.16);
        jointVisibility -= 0.30 * exp(-dot(jointDistance, jointDistance));
    }
    float3 shaded = color * (0.28 * jointVisibility + 0.72 * diffuse * visibility
        * mix(1.0, jointVisibility, 0.65))
        + specular * (isRope ? 0.3 : 0.5) * visibility * jointVisibility;
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
        float coordinate = (endFace ? radialDistance : in.stripeHeight) * u.material.w;
        float grain = (pistonGrain(coordinate * 115) * 0.65
                    + pistonGrain(coordinate * 213) * 0.35) * u.material.z;
        float base = in.surface.w;
        float3 metalColor = mix(u.metalColor.rgb, u.baseColor.rgb, base);
        metalColor *= 1 + grain * 0.045;
        float3 tint = mix(metalColor, u.stripeColor.rgb, stripe);
        float roughness = clamp(u.material.x + mix(endFace ? 0.08 : 0.0, 0.20, base)
                                + grain * 0.035 + stripe * 0.16, 0.08, 1.0);
        float metallic = mix(u.material.y, min(u.material.y, 0.25), stripe);
        float3 view = normalize(in.eye);
        float3 reflection = reflect(-view, n);
        float3 worldReflection = float3(
            dot(reflection, pistonRotate(float3(1, 0, 0), u.camera.y, u.camera.z)),
            dot(reflection, cylinderAxis),
            dot(reflection, pistonRotate(float3(0, 0, 1), u.camera.y, u.camera.z)));
        float nv = max(dot(n, view), 0.0);
        float3 f0 = mix(float3(0.04), tint, metallic);
        float3 fresnel = f0 + (max(float3(1 - roughness), f0) - f0) * pow(1 - nv, 5.0);
        float3 environment = pistonStudio(worldReflection, roughness) * fresnel
            * (1 - 0.4 * roughness) * u.finish.x;
        float3 direct = pistonMetal(n, view, light, tint, roughness, metallic)
            * float3(2.4, 2.5, 2.7) * visibility;
        shaded = (environment + tint * (1 - metallic) * 0.18 + direct) * jointVisibility;
        // Soft highlight rolloff keeps bright reflections from clipping.
        shaded = shaded / (1 + shaded);
    }
    return {float4(shaded, 1), in.position.z};
}
