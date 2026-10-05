#include <metal_stdlib>
using namespace metal;

// grid: width, height, dt, decay. flow: drag, swirl, diffusion, buoyancy.
// shape: puff size, force, turbulence. color: hue shift, hue spread, saturation.
struct SmokeUniforms { float4 grid; float4 flow; float4 shape; float4 color; float4 puff[16]; };
constexpr sampler smokeSampler(coord::pixel, address::clamp_to_edge, filter::linear);
float4 smokeSample(texture2d<float> t, float2 p) { return t.sample(smokeSampler, p); }
float3 smokeColor(int band, constant SmokeUniforms &u) {
    return 0.55 + 0.45 * u.color.z * cos(float(band) * u.color.y + u.color.x + float3(0, 2, 4));
}

kernel void smokeClear(texture2d<float, access::write> output [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    output.write(float4(0), p);
}

kernel void smokeVelocity(texture2d<float> source [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          texture2d<float> dye [[texture(2)]],
                          constant SmokeUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    float2 pos = float2(p) + 0.5;
    float dt = u.grid.z, size = min(u.grid.x, u.grid.y);
    float2 v = smokeSample(source, pos).xy;
    v = smokeSample(source, pos - v * dt).xy * exp(-dt * u.flow.x);
    // Dense smoke rises; grid y points down the screen.
    v.y -= u.flow.w * min(dye.read(p).a, 4.0) * size * 0.25 * dt;
    for (int i = 0; i < 8; ++i) {
        float4 puff = u.puff[i * 2];
        float strength = u.puff[i * 2 + 1].x;
        float radius = size * (0.022 + 0.025 * strength) * u.shape.x;
        float force = size * strength * u.shape.y, turbulence = force * u.shape.z;
        float2 q = (pos - puff.xy) / radius;
        float g = exp(-dot(q, q) * 1.5);
        // A directed jet with counter-rotating lobes rolls into a plume.
        float2 direction = puff.zw, side = float2(-direction.y, direction.x);
        float lateral = dot(q, side), forward = dot(q, direction);
        v += force * g * (direction * 1.8 + side * lateral * 1.5);
        // Small eddies seed fine folds; pressure projection removes divergence.
        float phase = u.puff[i * 2 + 1].y;
        float2 eddies = float2(cos(q.y * 9 + phase) * sin(q.x * 7),
                              -cos(q.x * 7) * sin(q.y * 9 + phase));
        v += turbulence * 0.32 * exp(-dot(q, q) * 0.8) * eddies;
        v += turbulence * 0.7 * exp(-dot(q, q) * 0.6)
            * (side * sin(forward * 3 + u.puff[i * 2 + 1].y));
    }
    float speed = length(v);
    v *= min(1.0, size * 2.0 / max(speed, 0.001));
    if (p.x < 2 || p.x + 2 >= uint(u.grid.x)) v.x = 0;
    if (p.y < 2 || p.y + 2 >= uint(u.grid.y)) v.y = 0;
    output.write(float4(v, 0, 0), p);
}

// Restore rotational motion lost to grid interpolation, keeping wisps alive.
float smokeCurl(texture2d<float> v, float2 p) {
    return (smokeSample(v, p + float2(1, 0)).y - smokeSample(v, p - float2(1, 0)).y
          - smokeSample(v, p + float2(0, 1)).x + smokeSample(v, p - float2(0, 1)).x) * 0.5;
}
kernel void smokeVorticity(texture2d<float> source [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant SmokeUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    float2 q = float2(p) + 0.5;
    float2 gradient = float2(abs(smokeCurl(source, q + float2(1, 0))) - abs(smokeCurl(source, q - float2(1, 0))),
                             abs(smokeCurl(source, q + float2(0, 1))) - abs(smokeCurl(source, q - float2(0, 1))));
    gradient /= max(length(gradient), 0.0001);
    float2 v = source.read(p).xy + float2(gradient.y, -gradient.x) * smokeCurl(source, q) * u.flow.y * u.grid.z;
    v *= min(1.0, min(u.grid.x, u.grid.y) * 2 / max(length(v), 0.001));
    if (p.x < 2 || p.x + 2 >= uint(u.grid.x)) v.x = 0;
    if (p.y < 2 || p.y + 2 >= uint(u.grid.y)) v.y = 0;
    output.write(float4(v, 0, 0), p);
}

kernel void smokeDivergence(texture2d<float> velocity [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    float2 q = float2(p) + 0.5;
    float d = (smokeSample(velocity, q + float2(1, 0)).x - smokeSample(velocity, q - float2(1, 0)).x
             + smokeSample(velocity, q + float2(0, 1)).y - smokeSample(velocity, q - float2(0, 1)).y) * 0.5;
    output.write(float4(d, 0, 0, 0), p);
}

kernel void smokePressure(texture2d<float> pressure [[texture(0)]], texture2d<float> divergence [[texture(1)]],
                          texture2d<float, access::write> output [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    float2 q = float2(p) + 0.5;
    float sum = smokeSample(pressure, q + float2(1, 0)).x + smokeSample(pressure, q - float2(1, 0)).x
              + smokeSample(pressure, q + float2(0, 1)).x + smokeSample(pressure, q - float2(0, 1)).x;
    output.write(float4((sum - divergence.read(p).x) * 0.25, 0, 0, 0), p);
}

kernel void smokeProject(texture2d<float> velocity [[texture(0)]], texture2d<float> pressure [[texture(1)]],
                         texture2d<float, access::write> output [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    float2 q = float2(p) + 0.5;
    float2 gradient = float2(smokeSample(pressure, q + float2(1, 0)).x - smokeSample(pressure, q - float2(1, 0)).x,
                             smokeSample(pressure, q + float2(0, 1)).x - smokeSample(pressure, q - float2(0, 1)).x) * 0.5;
    output.write(float4(velocity.read(p).xy - gradient, 0, 0), p);
}

kernel void smokeDye(texture2d<float> source [[texture(0)]], texture2d<float> velocity [[texture(1)]],
                     texture2d<float, access::write> output [[texture(2)]],
                     constant SmokeUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    float2 pos = float2(p) + 0.5, back = pos - velocity.read(p).xy * u.grid.z;
    float4 dye = smokeSample(source, back);
    float4 neighbors = (smokeSample(source, back + float2(1, 0)) + smokeSample(source, back - float2(1, 0))
                      + smokeSample(source, back + float2(0, 1)) + smokeSample(source, back - float2(0, 1))) * 0.25;
    dye = mix(dye, neighbors, 1 - exp(-u.grid.z * u.flow.z)) * exp(-u.grid.z * u.grid.w);
    for (int i = 0; i < 8; ++i) {
        float strength = u.puff[i * 2 + 1].x;
        float2 q = (pos - u.puff[i * 2].xy) / (min(u.grid.x, u.grid.y) * (0.018 + 0.025 * strength) * u.shape.x);
        float angle = atan2(q.y, q.x);
        float lobes = 1 + 0.18 * sin(angle * 5 + u.puff[i * 2 + 1].y);
        float density = exp(-dot(q, q) * lobes * 1.8) * strength * 3.5;
        dye += float4(smokeColor(i, u) * density, density);
    }
    output.write(min(dye, float4(20)), p);
}

struct SmokeVertex { float4 position [[position]]; float2 uv; };
vertex SmokeVertex smokeVisualizerVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}
kernel void smokeBloom(texture2d<float, access::read> dye [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant float4 &settings [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    float3 color = max(dye.read(p).rgb * settings.x, 0.0);
    float peak = max(color.r, max(color.g, color.b));
    // Preserve hue while extracting only energy above the threshold.
    color *= max(peak - settings.y, 0.0) / max(peak, 0.0001);
    output.write(float4(color, 0), p);
}

kernel void smokeBloomCombine(texture2d<float, access::read> tight [[texture(0)]],
                              texture2d<float, access::read> wide [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant float &wideStrength [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    float3 color = tight.read(p).rgb;
    if (wideStrength > 0) color += wide.read(p).rgb * wideStrength;
    output.write(float4(color, 0), p);
}

fragment float4 smokeVisualizerFragment(SmokeVertex in [[stage_in]], texture2d<float> dye [[texture(3)]],
                                        texture2d<float> bloom [[texture(4)]],
                                        constant float4 &display [[buffer(3)]],
                                        constant float &hotCores [[buffer(4)]]) {
    float2 p = in.uv * float2(dye.get_width(), dye.get_height());
    float3 color = smokeSample(dye, p).rgb;
    // Use local smoke brightness so diffuse glow and bloom keep their color.
    float corePeak = max(color.r, max(color.g, color.b)) * display.y;
    // Reach full heat early and taper across dimmer smoke so cores linger as puffs fade.
    float heat = smoothstep(0.1, 1.0, corePeak) * saturate(hotCores);
    float3 halo = float3(0);
    for (int i = 0; i < 12; ++i) {
        float angle = float(i) * 6.2831853 / 12;
        halo += smokeSample(dye, p + float2(cos(angle), sin(angle)) * display.z).rgb / 12;
    }
    color = color * display.y + halo * display.x * 0.35;
    if (display.w > 0) color += smokeSample(bloom, p).rgb * display.w;
    // Preserve hue through tone mapping, then let only hot cores approach white.
    float peak = max(color.r, max(color.g, color.b));
    color *= (1 - exp(-peak)) / max(peak, 0.0001);
    color = mix(color, float3(1 - exp(-peak)), heat);
    color = pow(max(color, 0.0), float3(0.8));
    return float4(color + float3(0.002, 0.003, 0.008), 1);
}
