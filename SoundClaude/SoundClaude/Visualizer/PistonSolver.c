#include "PistonSolver.h"
#include <math.h>
#include <stdbool.h>

typedef struct {
    simd_float3 center, previousCenter, extent, previousExtent;
    bool cylinder;
    bool cap;
} PistonCollider;

// Intersect a segment with a unit box or a unit-radius, unit-half-height cylinder.
static bool colliderHit(simd_float3 a, simd_float3 b, bool cylinder, float *entry) {
    if (simd_any(simd_min(a, b) >= 1) || simd_any(simd_max(a, b) <= -1)) return false;
    simd_float3 d = b - a;
    float lo = 0, hi = 1;
    for (int axis = 0; axis < 3; ++axis) {
        if (cylinder && axis != 1) continue;
        if (fabsf(d[axis]) < 1e-7f) {
            if (fabsf(a[axis]) >= 1) return false;
        } else {
            float t0 = (-1 - a[axis]) / d[axis];
            float t1 = (1 - a[axis]) / d[axis];
            lo = fmaxf(lo, fminf(t0, t1));
            hi = fminf(hi, fmaxf(t0, t1));
        }
    }
    if (cylinder) {
        float aa = d.x*d.x + d.z*d.z;
        float bb = a.x*d.x + a.z*d.z;
        float cc = a.x*a.x + a.z*a.z - 1;
        if (aa < 1e-12f) {
            if (cc >= 0) return false;
        } else {
            float discriminant = bb*bb - aa*cc;
            if (discriminant <= 0) return false;
            float root = sqrtf(discriminant);
            lo = fmaxf(lo, (-bb - root) / aa);
            hi = fminf(hi, (-bb + root) / aa);
        }
    }
    *entry = lo;
    return hi > lo && hi > 0 && lo < 1;
}

// Return a supporting surface in world space. Points inside use the nearest exit.
static void colliderSurface(PistonCollider c, simd_float3 local,
                            simd_float3 *normal, simd_float3 *surface) {
    simd_float3 n = {0, 0, 0};
    if (c.cylinder) {
        float radius = hypotf(local.x, local.z);
        // The shaft meets the cap underside; that internal face is not an exit.
        float shaftRadius = c.extent.x - 0.65f + 0.22f;
        bool blockedBottom = c.cap && local.y < 0 && radius * c.extent.x < shaftRadius;
        float verticalDistance = (blockedBottom ? 1 - local.y : 1 - fabsf(local.y)) * c.extent.y;
        if (verticalDistance < (1 - radius) * c.extent.x) {
            n.y = local.y < 0 && !blockedBottom ? -1 : 1;
            local.y = n.y;
        } else {
            n = radius > 1e-7f ? (simd_float3){local.x/radius, 0, local.z/radius}
                               : (simd_float3){1, 0, 0};
            local.x = n.x;
            local.z = n.z;
        }
    } else {
        simd_float3 distance = (1 - simd_abs(local)) * c.extent;
        // The shaft meets the cap underside; that internal face is not an exit.
        float shaftRadius = c.extent.x - 0.65f + 0.22f;
        bool blockedBottom = local.y < 0 && hypotf(local.x * c.extent.x, local.z * c.extent.z) < shaftRadius;
        if (blockedBottom) distance.y = (1 - local.y) * c.extent.y;
        int axis = distance.x < distance.y ? 0 : 1;
        if (distance.z < distance[axis]) axis = 2;
        n[axis] = local[axis] < 0 ? -1 : 1;
        if (axis == 1 && blockedBottom) n.y = 1;
        local[axis] = n[axis];
    }
    *normal = n;
    *surface = c.center + local * c.extent;
}

static void collideNode(simd_float4 *point, simd_float4 *previous, PistonCollider c, simd_float3 startPoint) {
    simd_float3 end = (point->xyz - c.center) / c.extent;
    simd_float3 start = (startPoint - c.previousCenter) / c.previousExtent;
    float entry;
    if (!colliderHit(start, end, c.cylinder, &entry)) return;
    simd_float3 local = start + (end - start) * entry;
    simd_float3 normal, surface;
    colliderSurface(c, local, &normal, &surface);
    float penetration = simd_dot(surface - point->xyz, normal);
    if (penetration <= 0) return;
    point->xyz += normal * (penetration + 0.00001f);
    // Remove inward relative velocity, retaining sliding and collider motion.
    simd_float3 motion = surface - (c.previousCenter + local * c.previousExtent);
    float velocity = simd_dot(point->xyz - previous->xyz - motion, normal);
    if (velocity < 0) previous->xyz += normal * velocity;
}

static void collideEdge(simd_float4 *a, simd_float4 *b, PistonCollider c) {
    simd_float3 start = (a->xyz - c.center) / c.extent;
    simd_float3 end = (b->xyz - c.center) / c.extent;
    float entry;
    if (!colliderHit(start, end, c.cylinder, &entry)) return;
    simd_float3 normal, surface;
    colliderSurface(c, start + (end - start) * entry, &normal, &surface);
    // Keep the whole straight rope segment outside, not just its nodes.
    a->xyz += normal * fmaxf(0, simd_dot(surface - a->xyz, normal) + 0.00001f);
    b->xyz += normal * fmaxf(0, simd_dot(surface - b->xyz, normal) + 0.00001f);
}


void SCPistonStep(simd_float4 *positions, simd_float4 *previous,
                  const float *heights, const float *previousHeights, float ropeRadius, uint32_t stringCount,
                  uint32_t stringsPerPiston, uint32_t segments, float segmentLength,
                  float damping, float gravityStrength) {
    const uint32_t pistonCount = stringCount / stringsPerPiston;
    PistonCollider colliders[pistonCount * 3];
    for (uint32_t piston = 0; piston < pistonCount; ++piston) {
        float x = ((float)piston - 3.5f) * 1.85f;
        float height = heights[piston], oldHeight = previousHeights[piston];
        colliders[piston * 3 + 2] = (PistonCollider){
            {x, height, 0}, {x, oldHeight, 0},
            {0.65f + ropeRadius, 0.055f + ropeRadius, 0.65f + ropeRadius},
            {0.65f + ropeRadius, 0.055f + ropeRadius, 0.65f + ropeRadius}, true, true};
        colliders[piston * 3] = (PistonCollider){
            {x, -1.53f, 0}, {x, -1.53f, 0},
            {0.38f + ropeRadius, 0.12f + ropeRadius, 0.38f + ropeRadius},
            {0.38f + ropeRadius, 0.12f + ropeRadius, 0.38f + ropeRadius}, true};
        colliders[piston * 3 + 1] = (PistonCollider){
            {x, (height - 1.53f) * 0.5f, 0}, {x, (oldHeight - 1.53f) * 0.5f, 0},
            {0.22f + ropeRadius, (height + 1.53f) * 0.5f + ropeRadius, 0.22f + ropeRadius},
            {0.22f + ropeRadius, (oldHeight + 1.53f) * 0.5f + ropeRadius, 0.22f + ropeRadius}, true};
    }
    const simd_float4 gravity = {0, -gravityStrength * (1.0f / 120.0f / 120.0f), 0, 0};
    for (uint32_t string = 0; string < stringCount; ++string) {
        simd_float4 *p = positions + string * (segments + 1);
        simd_float4 *old = previous + string * (segments + 1);
        p[0].y = heights[string / stringsPerPiston] - 0.055f;
        old[0] = p[0];
        for (uint32_t node = 1; node <= segments; ++node) {
            const simd_float4 position = p[node];
            p[node] += (position - old[node]) * (1.0f - damping) + gravity;
            old[node] = position;
            for (uint32_t collider = 0; collider < pistonCount * 3; ++collider)
                collideNode(&p[node], &old[node], colliders[collider], position.xyz);
        }
        for (uint32_t pass = 0; pass < 30; ++pass) {
            simd_float4 beforeConstraints[segments + 1];
            for (uint32_t node = 0; node <= segments; ++node) beforeConstraints[node] = p[node];
            for (uint32_t node = 1; node <= segments; ++node) {
                const simd_float4 difference = p[node] - p[node - 1];
                const float length = simd_length(difference);
                if (length <= 0.000001f) continue;
                const simd_float4 correction = difference * (1 - segmentLength / length);
                if (node == 1) {
                    p[node] -= correction;
                } else {
                    p[node] -= correction * 0.5f;
                    p[node - 1] += correction * 0.5f;
                }
            }
            // Propagate sudden root motion through the entire rope in one sweep.
            // The symmetric constraints above converge slowly along a taut chain.
            for (uint32_t node = 1; node <= segments; ++node) {
                const simd_float4 difference = p[node] - p[node - 1];
                const float length = simd_length(difference);
                const float maximumLength = segmentLength * 1.05f;
                if (length > maximumLength) {
                    p[node] -= difference * (1 - maximumLength / length);
                }
            }
            for (uint32_t node = 1; node <= segments; ++node) {
                for (uint32_t collider = 0; collider < pistonCount * 3; ++collider) {
                    PistonCollider fixed = colliders[collider];
                    fixed.previousCenter = fixed.center;
                    fixed.previousExtent = fixed.extent;
                    collideNode(&p[node], &old[node], fixed, beforeConstraints[node].xyz);
                    // The pinned root touches the cap underside.
                    if (node > 1) collideEdge(&p[node - 1], &p[node], colliders[collider]);
                }
                p[node].y = fmaxf(-1.65f, p[node].y);
            }
            // The root is on the underside, inside the radius-expanded cap.
            // Generic collision exits can put the first free node on top and
            // leave the pinned segment crossing the cap. Keep it below instead.
            const uint32_t piston = string / stringsPerPiston;
            const PistonCollider cap = colliders[piston * 3 + 2];
            if (hypotf(p[0].x - cap.center.x, p[0].z) < 0.65f) {
                const float ceiling = cap.center.y - cap.extent.y - 0.00001f;
                if (p[1].y > ceiling) {
                    p[1].y = ceiling;
                    const float capMotion = heights[piston] - previousHeights[piston];
                    const float velocity = p[1].y - old[1].y - capMotion;
                    if (velocity > 0) old[1].y += velocity;
                }
            }
            // Collisions can stretch a segment again. Spend extra passes only
            // while a rope still exceeds the stretch limit.
            if (pass >= 9) {
                bool stretched = false;
                for (uint32_t node = 1; node <= segments; ++node) {
                    if (simd_distance(p[node], p[node - 1]) > segmentLength * 1.1f) {
                        stretched = true;
                        break;
                    }
                }
                if (!stretched) break;
            }
        }
    }
}
