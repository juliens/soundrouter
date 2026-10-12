// sr_meters.c — lock-free peak meters (relaxed atomics on float bit patterns).
//
// Peaks are non-negative floats, whose IEEE-754 bit patterns order like unsigned integers,
// so "max" is a CAS loop on the raw bits.

#include "sr_internal.h"

#include <stdatomic.h>

void sr_meters_reset(SRMeters *m) {
    if (!m) return;
    for (uint32_t s = 0; s < SR_MAX_SOURCES; ++s)
        for (uint32_t c = 0; c < SR_MAX_CHANNELS; ++c)
            atomic_store_explicit(&m->sourcePeakBits[s][c], 0, memory_order_relaxed);
    for (uint32_t c = 0; c < SR_MAX_CHANNELS; ++c)
        atomic_store_explicit(&m->outputPeakBits[c], 0, memory_order_relaxed);
}

void sr_meters_update_max(_Atomic uint32_t *slot, float peak) {
    if (!(peak > 0.0f)) return; /* also rejects NaN */
    uint32_t bits = sr_float_to_bits(peak);
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    while (cur < bits &&
           !atomic_compare_exchange_weak_explicit(slot, &cur, bits, memory_order_relaxed,
                                                  memory_order_relaxed)) {
    }
}

float sr_meters_take_source(SRMeters *m, uint32_t source, uint32_t channel) {
    if (!m || source >= SR_MAX_SOURCES || channel >= SR_MAX_CHANNELS) return 0.0f;
    return sr_bits_to_float(
        atomic_exchange_explicit(&m->sourcePeakBits[source][channel], 0, memory_order_relaxed));
}

float sr_meters_take_output(SRMeters *m, uint32_t channel) {
    if (!m || channel >= SR_MAX_CHANNELS) return 0.0f;
    return sr_bits_to_float(
        atomic_exchange_explicit(&m->outputPeakBits[channel], 0, memory_order_relaxed));
}
