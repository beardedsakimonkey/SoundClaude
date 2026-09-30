#include "ClothSolver.h"
#include <math.h>
#include <stdlib.h>

static simd_float3 xyz(simd_float4 p) { return (simd_float3){p.x, p.y, p.z}; }
static simd_float4 vector4(simd_float3 p) { return (simd_float4){p.x, p.y, p.z, 0}; }

typedef struct {
    simd_float3 minimum, maximum;
    uint32_t index;
} ClothBounds;

static int compareBounds(const void *a, const void *b) {
    const ClothBounds *aa = a, *bb = b;
    if (aa->minimum.x < bb->minimum.x) return -1;
    if (aa->minimum.x > bb->minimum.x) return 1;
    return (aa->index > bb->index) - (aa->index < bb->index);
}

static int adjacent(uint32_t a, uint32_t b, uint32_t columns) {
    return abs((int)(a % columns) - (int)(b % columns)) <= 1 &&
           abs((int)(a / columns) - (int)(b / columns)) <= 1;
}

static simd_float3 barycentric(simd_float3 p, simd_float3 a,
                               simd_float3 b, simd_float3 c) {
    const simd_float3 u = b - a, v = c - a, w = p - a;
    const float uu = simd_dot(u, u), uv = simd_dot(u, v), vv = simd_dot(v, v);
    const float denominator = uu * vv - uv * uv;
    if (denominator < 1e-12f) return (simd_float3){-1, -1, -1};
    const float y = (vv * simd_dot(w, u) - uv * simd_dot(w, v)) / denominator;
    const float z = (uu * simd_dot(w, v) - uv * simd_dot(w, u)) / denominator;
    return (simd_float3){1 - y - z, y, z};
}

void SCClothCollide(simd_float4 *positions, const simd_float4 *previous,
                    uint32_t columns, uint32_t rows, float thickness) {
    if (columns < 2 || rows < 2 || thickness <= 0) return;
    const uint32_t count = columns * rows;
    ClothBounds *bounds = malloc(count * sizeof(*bounds));
    if (!bounds) return;
    for (uint32_t i = 0; i < count; i++) {
        bounds[i] = (ClothBounds){simd_min(xyz(positions[i]), xyz(previous[i])),
                                  simd_max(xyz(positions[i]), xyz(previous[i])), i};
    }
    qsort(bounds, count, sizeof(*bounds), compareBounds);
    for (uint32_t y = 0; y + 1 < rows; y++) {
        for (uint32_t x = 0; x + 1 < columns; x++) {
            const uint32_t a = y * columns + x;
            const uint32_t triangles[2][3] = {{a, a + columns, a + 1},
                                             {a + 1, a + columns, a + columns + 1}};
            for (int t = 0; t < 2; t++) {
                const uint32_t *ids = triangles[t];
                simd_float3 lo = xyz(positions[ids[0]]), hi = lo;
                for (int k = 0; k < 3; k++) {
                    lo = simd_min(lo, simd_min(xyz(positions[ids[k]]), xyz(previous[ids[k]])));
                    hi = simd_max(hi, simd_max(xyz(positions[ids[k]]), xyz(previous[ids[k]])));
                }
                lo -= thickness; hi += thickness;
                for (uint32_t j = 0; j < count && bounds[j].minimum.x <= hi.x; j++) {
                    const ClothBounds box = bounds[j];
                    if (box.maximum.x < lo.x || box.maximum.y < lo.y || box.minimum.y > hi.y ||
                        box.maximum.z < lo.z || box.minimum.z > hi.z) continue;
                    const uint32_t i = box.index;
                    // Exclude the local mesh patch so flat fabric is not inflated.
                    if (adjacent(i, ids[0], columns) || adjacent(i, ids[1], columns) ||
                        adjacent(i, ids[2], columns)) continue;
                    simd_float3 p[3], old[3];
                    for (int k = 0; k < 3; k++) {
                        p[k] = xyz(positions[ids[k]]); old[k] = xyz(previous[ids[k]]);
                    }
                    simd_float3 n = simd_cross(p[1] - p[0], p[2] - p[0]);
                    simd_float3 oldN = simd_cross(old[1] - old[0], old[2] - old[0]);
                    const float n2 = simd_length_squared(n), oldN2 = simd_length_squared(oldN);
                    if (n2 < 1e-12f || oldN2 < 1e-12f) continue;
                    n /= sqrtf(n2); oldN /= sqrtf(oldN2);
                    const float before = simd_dot(xyz(previous[i]) - old[0], oldN);
                    const float after = simd_dot(xyz(positions[i]) - p[0], n);
                    const float side = before < 0 ? -1 : 1;
                    if (side * after >= thickness) continue;
                    // Approximate time of impact for a moving vertex and face.
                    // This also catches a vertex that crosses the entire face in one step.
                    const float time = before * after < 0 ? before / (before - after) : 1;
                    const simd_float3 hit = xyz(previous[i]) + time * xyz(positions[i] - previous[i]);
                    const simd_float3 weights = barycentric(hit, old[0] + time * (p[0] - old[0]),
                        old[1] + time * (p[1] - old[1]), old[2] + time * (p[2] - old[2]));
                    if (weights.x < 0 || weights.y < 0 || weights.z < 0) continue;
                    const float distance = simd_dot(xyz(positions[i]) -
                        (p[0] * weights.x + p[1] * weights.y + p[2] * weights.z), n);
                    const float correction = thickness - side * distance;
                    if (correction <= 0) continue;
                    const simd_float4 push = vector4(n * (side * correction /
                                                        (1 + simd_length_squared(weights))));
                    positions[i] += push;
                    for (int k = 0; k < 3; k++) positions[ids[k]] -= push * weights[k];
                }
            }
        }
    }
    free(bounds);
}

static void solveBend(simd_float4 *positions, SCClothBend *bend,
                      float alpha) {
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
        denominator += simd_length_squared(gradient[j]);
    if (denominator <= 0) return;
    const float delta = (-error - alpha * bend->lambda) / (denominator + alpha);
    bend->lambda += delta;
    for (int j = 0; j < 4; j++)
        positions[ids[j]] += vector4(gradient[j] * delta);
}

void SCClothStep(simd_float4 *positions, simd_float4 *previous,
                 uint32_t columns, uint32_t rows,
                 SCClothEdge *edges, uint32_t edgeCount,
                 SCClothBend *bends, uint32_t bendCount,
                 const simd_float4 *attachments, float groundDepth,
                 float damping, float compliance, float bendCompliance, float gravity, uint32_t iterations) {
    const uint32_t count = columns * rows;
    const float inverseDtSquared = 120.0f * 120.0f;
    const float alpha = fmaxf(0, compliance) * inverseDtSquared;
    const float bendAlpha = fmaxf(0, bendCompliance) * inverseDtSquared;
    for (uint32_t i = 0; i < count; i++) {
        const simd_float4 p = positions[i];
        // The ground is below the cloth along negative Z.
        positions[i] = p + (p - previous[i]) * (1.0f - damping) + (simd_float4){0, 0, -gravity / inverseDtSquared, 0};
        previous[i] = p;
    }
    // XPBD multipliers persist across solver passes, but reset each time step.
    // Macklin et al., 2016: https://mmacklin.com/xpbd.pdf (Eq. 18).
    for (uint32_t i = 0; i < edgeCount; i++) edges[i].lambda = 0;
    for (uint32_t i = 0; i < bendCount; i++) bends[i].lambda = 0;
    float thickness = INFINITY;
    for (uint32_t i = 0; i < edgeCount; i++)
        if (edges[i].rest > 0) thickness = fminf(thickness, edges[i].rest * 0.2f);
    // Isolated constraints (without a cloth mesh) have no collision surface.
    const int selfCollision = edgeCount >= count && isfinite(thickness);
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
            solveBend(positions, &bends[i], bendAlpha);
        if (selfCollision) SCClothCollide(positions, previous, columns, rows, thickness);
        // Ropes resist tension only: a slack rope must not push the cloth.
        if (attachments) {
            const uint32_t corners[4] = {0, columns - 1, (rows - 1) * columns, count - 1};
            for (uint32_t i = 0; i < 4; i++) {
                simd_float3 offset = xyz(positions[corners[i]]) - xyz(attachments[i]);
                float length = simd_length(offset);
                if (length > attachments[i].w && length > 1e-8f)
                    positions[corners[i]] -= vector4(offset * (1 - attachments[i].w / length));
            }
        }
    }
    // Prevent the fabric from passing through the ground during strong beats.
    for (uint32_t i = 0; i < count; i++) {
        if (positions[i].z < groundDepth + 0.025f) {
            positions[i].z = groundDepth + 0.025f;
            previous[i].z = fmaxf(previous[i].z, positions[i].z);
        }
    }
}
