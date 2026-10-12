// sr_ring.h — pure, real-time-safe ring index math for the SoundRouter driver.
// No allocation, no lock, no syscall. Planes are laid out as in sr_shm.h: channel c of a
// block lives at planes + c * SR_RING_FRAMES, frame at device sample time S lives at
// index (S & SR_RING_MASK).

#ifndef SR_RING_H
#define SR_RING_H

#include <stdint.h>
#include <stdatomic.h>

/* Portion of [start, start+n) that is readable given writeFrame (one past last written):
 * frames S with writeFrame - SR_RING_FRAMES <= S < writeFrame. The result is a single
 * contiguous sub-range: frames [start + *first, start + *first + *count). */
void sr_ring_valid_range(int64_t writeFrame, int64_t start, uint32_t n,
                         uint32_t *first, uint32_t *count);

/* Copies [start, start+n) from planar ring `planes` (planeChannels planes) into the HAL
 * buffer `out` (outChannels channels, interleaved or non-interleaved = consecutive
 * channel blocks of n frames). Frames outside the valid range and channels beyond
 * planeChannels are zero. Returns the number of valid frames. */
uint32_t sr_ring_read(const float *planes, uint32_t planeChannels, int64_t writeFrame,
                      int64_t start, uint32_t n,
                      float *out, uint32_t outChannels, int interleaved);

/* Writes [start, start+n) from HAL buffer `in` into the planar ring. If n exceeds the ring
 * only the last SR_RING_FRAMES frames are written. Channels beyond inChannels are zeroed. */
void sr_ring_write(float *planes, uint32_t planeChannels,
                   int64_t start, uint32_t n,
                   const float *in, uint32_t inChannels, int interleaved);

/* *p = max(*p, v) with release ordering; lock-free. Returns the resulting value. */
int64_t sr_atomic_max_i64(_Atomic int64_t *p, int64_t v);

#endif /* SR_RING_H */
