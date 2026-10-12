// sr_internal.h — private helpers shared between SRCore translation units (not public API).
#ifndef SR_INTERNAL_H
#define SR_INTERNAL_H

#include "sr_core.h"

/* Peek up to `frames` frames into `nplanes` planes. Planes beyond the ring's channel count are
 * zero-filled; ring channels beyond `nplanes` are ignored. Returns frames copied. [RT] */
uint32_t sr_ring_peek_n(const SRRing *ring, float *const *planes, uint32_t nplanes,
                        uint32_t frames);

/* Atomic max of a non-negative float stored as bits (relaxed CAS loop). [RT] */
void sr_meters_update_max(_Atomic uint32_t *slot, float peak);

#endif
