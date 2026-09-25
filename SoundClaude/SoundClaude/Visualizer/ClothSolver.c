#include "ClothSolver.h"
#include <math.h>

void SCClothStep(simd_float4 *positions, simd_float4 *previous,
                 uint32_t columns, uint32_t rows,
                 const SCClothEdge *edges, uint32_t edgeCount,
                 float damping, float stiffness, float gravity, uint32_t iterations) {
    const uint32_t count = columns * rows;
    for (uint32_t i = 0; i < count; i++) {
        if (i == 0 || i == columns - 1) continue;
        const simd_float4 p = positions[i];
        positions[i] = p + (p - previous[i]) * (1.0f - damping) + (simd_float4){0, -gravity / (120.0f * 120.0f), 0, 0};
        previous[i] = p;
    }
    for (uint32_t iteration = 0; iteration < iterations; iteration++) {
        for (uint32_t i = 0; i < edgeCount; i++) {
            const SCClothEdge edge = edges[i];
            const simd_float4 offset = positions[edge.b] - positions[edge.a];
            const float length = fmaxf(0.00001f, simd_length(offset));
            const simd_float4 correction = offset * ((length - edge.rest) / length * stiffness);
            positions[edge.a] += correction * edge.aWeight;
            positions[edge.b] -= correction * edge.bWeight;
        }
    }
}
