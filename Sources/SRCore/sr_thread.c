// sr_thread.c — promote the calling thread to Mach real-time (time-constraint) scheduling.

#include "sr_internal.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>

int sr_thread_set_realtime(uint32_t periodFrames, double sampleRate) {
    if (periodFrames == 0 || !(sampleRate > 0)) return KERN_INVALID_ARGUMENT;
    mach_timebase_info_data_t tb;
    if (mach_timebase_info(&tb) != KERN_SUCCESS || tb.numer == 0) return KERN_FAILURE;
    double ticksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    double periodTicks = (double)periodFrames / sampleRate * ticksPerSecond;
    if (periodTicks < 1 || periodTicks > 4e9) return KERN_INVALID_ARGUMENT;

    thread_time_constraint_policy_data_t policy;
    policy.period = (uint32_t)periodTicks;
    policy.computation = (uint32_t)(periodTicks * 0.5);
    policy.constraint = (uint32_t)periodTicks;
    policy.preemptible = 1;
    return (int)thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                                  THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}
