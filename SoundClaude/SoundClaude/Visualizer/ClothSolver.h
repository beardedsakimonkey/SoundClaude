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
    float lambda;
} SCClothEdge;

// Oriented shared edge (a, b), with opposite vertices c and d.
typedef struct {
    uint32_t a, b, c, d;
    float restAngle;
    float lambda;
} SCClothBend;

/// Separates nonadjacent vertices and triangle faces, using the start of the
/// step to preserve the side of contact. Thickness is in world units.
void SCClothCollide(simd_float4 *positions, const simd_float4 *previous,
                    uint32_t columns, uint32_t rows, float thickness);

/// Updates exclusively owned particle storage by one fixed 1/120-second step.
void SCClothStep(simd_float4 *positions, simd_float4 *previous,
                 uint32_t columns, uint32_t rows,
                 SCClothEdge *edges, uint32_t edgeCount,
                 SCClothBend *bends, uint32_t bendCount,
                 const simd_float4 *attachments, float groundDepth,
                 float damping, float compliance, float bendCompliance, float gravity, uint32_t iterations);

#endif
