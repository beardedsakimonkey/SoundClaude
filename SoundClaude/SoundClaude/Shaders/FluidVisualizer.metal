// Solver adapted from WebGL-Fluid-Simulation by Pavel Dobryakov.
// Copyright (c) 2017 Pavel Dobryakov. MIT license: Resources/Fluid-LICENSE.txt.
#include <metal_stdlib>
using namespace metal;

struct FluidUniforms {
    float4 step; // dt, dissipation, curl, aspect
    float4 splat; // position, radius squared, operation
    float4 value;
};
constexpr sampler fluidSampler(coord::normalized, address::clamp_to_edge, filter::linear);

kernel void fluidStep(texture2d<float, access::sample> source [[texture(0)]],
                      texture2d<float, access::sample> other [[texture(1)]],
                      texture2d<float, access::write> target [[texture(2)]],
                      constant FluidUniforms &u [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) return;
    float2 size = float2(target.get_width(), target.get_height());
    float2 uv = (float2(id) + 0.5) / size;
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    int op = int(u.splat.w);
    if (op == 0) { target.write(float4(0), id); return; }
    float4 C = source.sample(fluidSampler, uv);
    float4 result = C;
    if (op == 8) {
        result = C * 0.8;
    } else if (op == 1) {
        float2 p = uv - u.splat.xy;
        p.x *= u.step.w;
        result = C + exp(-dot(p, p) / max(u.splat.z, 0.000001)) * u.value;
    } else if (op == 7) {
        float2 velocitySize = float2(other.get_width(), other.get_height());
        float2 coord = uv - u.step.x * other.sample(fluidSampler, uv).xy / velocitySize;
        result = source.sample(fluidSampler, coord) / (1 + u.step.y * u.step.x);
    } else {
        float4 L = source.sample(fluidSampler, uv - float2(texel.x, 0));
        float4 R = source.sample(fluidSampler, uv + float2(texel.x, 0));
        float4 T = source.sample(fluidSampler, uv + float2(0, texel.y));
        float4 B = source.sample(fluidSampler, uv - float2(0, texel.y));
        if (op == 2) {
            result = float4(0.5 * (R.y - L.y - T.x + B.x), 0, 0, 0);
        } else if (op == 3) {
            float l = other.sample(fluidSampler, uv - float2(texel.x, 0)).x;
            float r = other.sample(fluidSampler, uv + float2(texel.x, 0)).x;
            float t = other.sample(fluidSampler, uv + float2(0, texel.y)).x;
            float b = other.sample(fluidSampler, uv - float2(0, texel.y)).x;
            float c = other.sample(fluidSampler, uv).x;
            float2 force = 0.5 * float2(abs(t) - abs(b), abs(r) - abs(l));
            force *= u.step.z * c / (length(force) + 0.0001);
            force.y *= -1;
            result = float4(clamp(C.xy + force * u.step.x, -1000.0, 1000.0), 0, 0);
        } else if (op == 4) {
            if (id.x == 0) L.x = -C.x;
            if (id.x == uint(size.x) - 1) R.x = -C.x;
            if (id.y == 0) B.y = -C.y;
            if (id.y == uint(size.y) - 1) T.y = -C.y;
            result = float4(0.5 * (R.x - L.x + T.y - B.y), 0, 0, 0);
        } else if (op == 5) {
            result = float4((L.x + R.x + B.x + T.x - other.sample(fluidSampler, uv).x) * 0.25, 0, 0, 0);
        } else if (op == 6) {
            result = float4(other.sample(fluidSampler, uv).xy - float2(R.x - L.x, T.x - B.x), 0, 0);
        }
    }
    target.write(result, id);
}

// Bloom and sunrays follow the reference pass order and constants.
kernel void fluidPost(texture2d<float, access::sample> source [[texture(0)]],
                      texture2d<float, access::sample> other [[texture(1)]],
                      texture2d<float, access::write> target [[texture(2)]],
                      constant float4 &params [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) return;
    float2 uv = (float2(id) + 0.5) / float2(target.get_width(), target.get_height());
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float4 c = source.sample(fluidSampler, uv);
    int op = int(params.x);
    if (op == 0) {
        const float threshold = 0.6;
        const float knee = threshold * 0.7 + 0.0001;
        float br = max(c.r, max(c.g, c.b));
        float rq = clamp(br - (threshold - knee), 0.0, knee * 2);
        rq = 0.25 / knee * rq * rq;
        c = float4(c.rgb * (max(rq, br - threshold) / max(br, 0.0001)), 0);
    } else if (op == 1 || op == 2) {
        c = (source.sample(fluidSampler, uv - float2(texel.x, 0))
           + source.sample(fluidSampler, uv + float2(texel.x, 0))
           + source.sample(fluidSampler, uv - float2(0, texel.y))
           + source.sample(fluidSampler, uv + float2(0, texel.y))) * 0.25 * params.y;
        if (op == 2) c += other.sample(fluidSampler, uv);
    } else if (op == 3) {
        float br = max(c.r, max(c.g, c.b));
        c.a = 1 - min(max(br * 20, 0.0), 0.8);
    } else if (op == 4) {
        float2 coord = uv;
        float2 dir = (uv - 0.5) * (0.3 / 16.0);
        float decay = 1;
        float value = c.a;
        for (int i = 0; i < 16; i++) {
            coord -= dir;
            value += source.sample(fluidSampler, coord).a * decay;
            decay *= 0.95;
        }
        c = float4(value * 0.7, 0, 0, 1);
    } else {
        float2 offset = (op == 5 ? float2(texel.x, 0) : float2(0, texel.y)) * 1.33333333;
        c = c * 0.29411764 + (source.sample(fluidSampler, uv - offset)
                            + source.sample(fluidSampler, uv + offset)) * 0.35294117;
    }
    target.write(c, id);
}

struct FluidVertex { float4 position [[position]]; float2 uv; };
vertex FluidVertex fluidVisualizerVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };
}
fragment float4 fluidVisualizerFragment(FluidVertex in [[stage_in]],
                                        texture2d<float> dye [[texture(0)]],
                                        texture2d<float> bloomTexture [[texture(1)]],
                                        texture2d<float> raysTexture [[texture(2)]],
                                        constant float4 *display [[buffer(0)]]) {
    float2 texel = display[0].xy;
    float3 c = dye.sample(fluidSampler, in.uv).rgb;
    if (display[0].w > 0) {
        float l = length(dye.sample(fluidSampler, in.uv - float2(texel.x, 0)).rgb);
        float r = length(dye.sample(fluidSampler, in.uv + float2(texel.x, 0)).rgb);
        float b = length(dye.sample(fluidSampler, in.uv - float2(0, texel.y)).rgb);
        float t = length(dye.sample(fluidSampler, in.uv + float2(0, texel.y)).rgb);
        float3 n = normalize(float3(r - l, t - b, length(texel)));
        c *= clamp(n.z + 0.7, 0.7, 1.0);
    }
    float3 bloom = bloomTexture.sample(fluidSampler, in.uv).rgb;
    if (display[1].x > 0) {
        float rays = raysTexture.sample(fluidSampler, in.uv).r;
        c *= rays;
        bloom *= rays;
    }
    // Sub-byte dithering suppresses bloom banding, as in the reference.
    if (display[1].y > 0) {
        float noise = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
        bloom += (noise * 2 - 1) / 255.0;
        bloom = max(1.055 * pow(max(bloom, 0.0), float3(0.416666667)) - 0.055, 0.0);
        c += bloom;
    }
    // The reference writes directly to an SDR canvas; preserve its luminous clipping.
    return float4(c * display[0].z, 1);
}
