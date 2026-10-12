// sr_mix.c — per-device mixer: routes, gains, device volume/mute, clipping, meters.

#include "sr_internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

SRMixPlan *sr_mix_plan_create(uint32_t routeCapacity) {
    size_t size = sizeof(SRMixPlan) + (size_t)routeCapacity * sizeof(SRRoute);
    return (SRMixPlan *)calloc(1, size);
}

void sr_mix_plan_destroy(SRMixPlan *plan) { free(plan); }

static inline float peak_abs(const float *x, uint32_t n) {
    float m = 0.0f;
    for (uint32_t i = 0; i < n; ++i) {
        float a = fabsf(x[i]);
        m = a > m ? a : m;
    }
    return m;
}

void sr_mix_render(const SRMixPlan *plan, const float *const *const *sourcePlanes,
                   float *const *out, uint32_t frames, SRMeters *meters) {
    if (!plan || !out) return;
    uint32_t outCh = plan->outputChannels;
    if (outCh > SR_MAX_CHANNELS) outCh = SR_MAX_CHANNELS;
    for (uint32_t c = 0; c < outCh; ++c)
        if (out[c]) memset(out[c], 0, frames * sizeof(float));
    if (frames == 0) return;

    uint32_t srcCount = plan->sourceCount;
    if (srcCount > SR_MAX_SOURCES) srcCount = SR_MAX_SOURCES;

    float srcGain[SR_MAX_SOURCES];
    for (uint32_t s = 0; s < srcCount; ++s) {
        const SRMixSource *src = &plan->sources[s];
        bool present = sourcePlanes && sourcePlanes[s];
        srcGain[s] = (src->muted || !src->active || !present) ? 0.0f : src->volume;
        if (meters && srcGain[s] != 0.0f) {
            uint32_t nm = src->channels < SR_MAX_CHANNELS ? src->channels : SR_MAX_CHANNELS;
            for (uint32_t c = 0; c < nm; ++c) {
                const float *x = sourcePlanes[s][c];
                if (!x) continue;
                sr_meters_update_max(&meters->sourcePeakBits[s][c],
                                     peak_abs(x, frames) * fabsf(srcGain[s]));
            }
        }
    }

    for (uint32_t r = 0; r < plan->routeCount; ++r) {
        const SRRoute *rt = &plan->routes[r];
        uint32_t s = rt->sourceIndex;
        if (s >= srcCount || rt->outputChannel >= outCh) continue;
        if (rt->sourceChannel >= plan->sources[s].channels) continue;
        float g = srcGain[s] * rt->gain;
        if (g == 0.0f) continue;
        const float *x = sourcePlanes[s][rt->sourceChannel];
        float *y = out[rt->outputChannel];
        if (!x || !y) continue;
        for (uint32_t i = 0; i < frames; ++i) y[i] += x[i] * g;
    }

    float dg = plan->muted ? 0.0f : plan->volume;
    for (uint32_t c = 0; c < outCh; ++c) {
        float *y = out[c];
        if (!y) continue;
        float peak = 0.0f;
        for (uint32_t i = 0; i < frames; ++i) {
            float v = y[i] * dg;
            v = v > 1.0f ? 1.0f : v;
            v = v < -1.0f ? -1.0f : v;
            v = (v == v) ? v : 0.0f; /* NaN -> 0 */
            y[i] = v;
            float a = fabsf(v);
            peak = a > peak ? a : peak;
        }
        if (meters) sr_meters_update_max(&meters->outputPeakBits[c], peak);
    }
}
