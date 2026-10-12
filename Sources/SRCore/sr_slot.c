// sr_slot.c — single-reader / single-writer RCU-like pointer slot.
//
// Reader: acquire() increments readerEpoch (odd = inside a read section) then loads the
// current pointer; release() increments it again (even = quiescent).
// Writer: publish() exchanges the pointer then samples readerEpoch. A retired pointer tagged
// with epoch E can be freed when E is even (the reader was outside; any later acquire sees
// the new pointer thanks to seq_cst ordering of the exchange and the epoch increment), or
// when readerEpoch != E (the reader has left the section it was in).
// Frees only ever happen on the writer thread (publish/collect/destroy).

#include "sr_internal.h"

#include <stdatomic.h>
#include <stdlib.h>

typedef struct {
    void    *ptr;
    uint64_t epoch;
} SRRetired;

struct SRPlanSlot {
    _Atomic(void *)  current;
    _Atomic uint64_t readerEpoch;
    void (*freeFn)(void *);
    SRRetired *retired;     /* writer-only */
    size_t     retiredCount;
    size_t     retiredCap;
};

SRPlanSlot *sr_slot_create(void (*freeFn)(void *)) {
    SRPlanSlot *s = (SRPlanSlot *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->current, NULL);
    atomic_init(&s->readerEpoch, 0);
    s->freeFn = freeFn;
    return s;
}

static void free_ptr(SRPlanSlot *s, void *p) {
    if (p && s->freeFn) s->freeFn(p);
}

void sr_slot_collect(SRPlanSlot *s) {
    if (!s || s->retiredCount == 0) return;
    uint64_t now = atomic_load_explicit(&s->readerEpoch, memory_order_seq_cst);
    size_t keep = 0;
    for (size_t i = 0; i < s->retiredCount; ++i) {
        SRRetired r = s->retired[i];
        if ((r.epoch & 1u) == 0 || now != r.epoch) free_ptr(s, r.ptr);
        else s->retired[keep++] = r;
    }
    s->retiredCount = keep;
}

void sr_slot_publish(SRPlanSlot *s, void *ptr) {
    if (!s) return;
    void *old = atomic_exchange_explicit(&s->current, ptr, memory_order_seq_cst);
    uint64_t epoch = atomic_load_explicit(&s->readerEpoch, memory_order_seq_cst);
    if (old) {
        if (s->retiredCount == s->retiredCap) {
            size_t cap = s->retiredCap ? s->retiredCap * 2 : 8;
            SRRetired *n = (SRRetired *)realloc(s->retired, cap * sizeof(SRRetired));
            if (!n) {
                /* Out of memory: leak rather than risk a use-after-free. */
                sr_slot_collect(s);
                return;
            }
            s->retired = n;
            s->retiredCap = cap;
        }
        s->retired[s->retiredCount++] = (SRRetired){ old, epoch };
    }
    sr_slot_collect(s);
}

void sr_slot_destroy(SRPlanSlot *s) {
    if (!s) return;
    for (size_t i = 0; i < s->retiredCount; ++i) free_ptr(s, s->retired[i].ptr);
    free(s->retired);
    free_ptr(s, atomic_load_explicit(&s->current, memory_order_acquire));
    free(s);
}

void *sr_slot_acquire(SRPlanSlot *s) {
    atomic_fetch_add_explicit(&s->readerEpoch, 1, memory_order_seq_cst);
    return atomic_load_explicit(&s->current, memory_order_seq_cst);
}

void sr_slot_release(SRPlanSlot *s) {
    atomic_fetch_add_explicit(&s->readerEpoch, 1, memory_order_seq_cst);
}
