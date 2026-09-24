#ifndef SC_CLOTH_SOLVER_H
#define SC_CLOTH_SOLVER_H

#include <simd/simd.h>
#include <stdint.h>

typedef struct {
    uint32_t a;
    uint32_t b;
    float rest;
    float aWeight;
    float bWeight;
} SCClothEdge;

/// Updates exclusively owned particle storage by one fixed 1/120-second step.
void SCClothStep(simd_float4 *positions, simd_float4 *previous,
                 uint32_t columns, uint32_t rows,
                 const SCClothEdge *edges, uint32_t edgeCount,
                 float damping, float stiffness, float gravity, uint32_t iterations);

#endif
