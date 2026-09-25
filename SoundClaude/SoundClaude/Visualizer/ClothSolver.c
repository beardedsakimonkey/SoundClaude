#include "ClothSolver.h"
#include <math.h>

static float inverseMass(uint32_t index, uint32_t columns, uint32_t rows) {
    const uint32_t x = index % columns, y = index / columns;
    return (x == 0 || x == columns - 1) && (y == 0 || y == rows - 1) ? 0.0f : 1.0f;
}

static simd_float3 xyz(simd_float4 p) { return (simd_float3){p.x, p.y, p.z}; }
static simd_float4 vector4(simd_float3 p) { return (simd_float4){p.x, p.y, p.z, 0}; }

static void solveBend(simd_float4 *positions, SCClothBend *bend,
                      uint32_t columns, uint32_t rows, float alpha) {
    const uint32_t ids[4] = {bend->a, bend->b, bend->c, bend->d};
    const simd_float3 a = xyz(positions[ids[0]]);
    const simd_float3 e = xyz(positions[ids[1]]) - a;
    const simd_float3 c = xyz(positions[ids[2]]) - a;
    const simd_float3 d = xyz(positions[ids[3]]) - a;
    const float e2 = simd_length_squared(e);
    const simd_float3 n1 = simd_cross(e, c), n2 = simd_cross(d, e);
    const float n12 = simd_length_squared(n1), n22 = simd_length_squared(n2);
    // An angle has no defined gradient on a collapsed edge or triangle.
    if (e2 < 1e-12f || n12 < 1e-12f || n22 < 1e-12f) return;
    const float length = sqrtf(e2);
    // Both atan2 arguments share the normal-length factor, so it cancels.
    const float angle = atan2f(simd_dot(simd_cross(n1, n2), e) / length, simd_dot(n1, n2));
    float error = angle - bend->restAngle;
    if (error > (float)M_PI) error -= 2.0f * (float)M_PI;
    if (error < -(float)M_PI) error += 2.0f * (float)M_PI;
    simd_float3 gradient[4];
    gradient[2] = -length / n12 * n1;
    gradient[3] = -length / n22 * n2;
    const float tc = simd_dot(c, e) / e2, td = simd_dot(d, e) / e2;
    gradient[0] = (tc - 1) * gradient[2] + (td - 1) * gradient[3];
    gradient[1] = -tc * gradient[2] - td * gradient[3];
    float denominator = 0;
    for (int j = 0; j < 4; j++)
        denominator += inverseMass(ids[j], columns, rows) * simd_length_squared(gradient[j]);
    if (denominator <= 0) return;
    const float delta = (-error - alpha * bend->lambda) / (denominator + alpha);
    bend->lambda += delta;
    for (int j = 0; j < 4; j++)
        positions[ids[j]] += vector4(gradient[j] * (inverseMass(ids[j], columns, rows) * delta));
}

void SCClothStep(simd_float4 *positions, simd_float4 *previous,
                 uint32_t columns, uint32_t rows,
                 SCClothEdge *edges, uint32_t edgeCount,
                 SCClothBend *bends, uint32_t bendCount,
                 float damping, float compliance, float bendCompliance, float gravity, uint32_t iterations) {
    const uint32_t count = columns * rows;
    const float inverseDtSquared = 120.0f * 120.0f;
    const float alpha = fmaxf(0, compliance) * inverseDtSquared;
    const float bendAlpha = fmaxf(0, bendCompliance) * inverseDtSquared;
    for (uint32_t i = 0; i < count; i++) {
        if (inverseMass(i, columns, rows) == 0) continue;
        const simd_float4 p = positions[i];
        positions[i] = p + (p - previous[i]) * (1.0f - damping) + (simd_float4){0, -gravity / inverseDtSquared, 0, 0};
        previous[i] = p;
    }
    // XPBD multipliers persist across solver passes, but reset each time step.
    // Macklin et al., 2016: https://mmacklin.com/xpbd.pdf (Eq. 18).
    for (uint32_t i = 0; i < edgeCount; i++) edges[i].lambda = 0;
    for (uint32_t i = 0; i < bendCount; i++) bends[i].lambda = 0;
    for (uint32_t iteration = 0; iteration < iterations; iteration++) {
        for (uint32_t i = 0; i < edgeCount; i++) {
            SCClothEdge *edge = &edges[i];
            const simd_float4 offset = positions[edge->b] - positions[edge->a];
            const float length = simd_length(offset);
            const float weight = edge->aWeight + edge->bWeight;
            if (length < 1e-8f || weight == 0) continue;
            const float delta = (-(length - edge->rest) - alpha * edge->lambda) / (weight + alpha);
            edge->lambda += delta;
            const simd_float4 correction = offset * (delta / length);
            positions[edge->a] -= correction * edge->aWeight;
            positions[edge->b] += correction * edge->bWeight;
        }
        for (uint32_t i = 0; i < bendCount; i++)
            solveBend(positions, &bends[i], columns, rows, bendAlpha);
    }
}
