#ifndef SC_PISTON_SOLVER_H
#define SC_PISTON_SOLVER_H

#include <simd/simd.h>
#include <stdint.h>

/// Advances exclusively owned rope storage by one fixed 1/120-second step.
/// Root x/z coordinates are fixed; their heights follow the owning piston.
void SCPistonStep(simd_float4 *positions, simd_float4 *previous,
                  const float *heights, const float *previousHeights, float ropeRadius, uint32_t stringCount,
                  uint32_t stringsPerPiston, uint32_t segments, float segmentLength,
                  float damping, float gravityStrength);

#endif
