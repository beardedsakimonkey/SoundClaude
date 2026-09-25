#ifndef SC_PCM_RING_BUFFER_H
#define SC_PCM_RING_BUFFER_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SCSpectrumBandCount = 64,
};

typedef struct SCPMRingBuffer SCPMRingBuffer;
typedef struct SCSpectrumBuffer SCSpectrumBuffer;

/// Creates fixed storage for one producer and one consumer.
SCPMRingBuffer *SCPMRingBufferCreate(uint32_t capacity);
void SCPMRingBufferDestroy(SCPMRingBuffer *ring);

/// Configures the sample layout before the audio device starts.
bool SCPMRingBufferConfigure(
    SCPMRingBuffer *ring,
    const AudioStreamBasicDescription *format
);

/// These functions must only run while the audio device is stopped.
void SCPMRingBufferReset(SCPMRingBuffer *ring);
uint32_t SCPMRingBufferRead(
    SCPMRingBuffer *ring,
    float *output,
    uint32_t maximumFrameCount
);
uint32_t SCPMRingBufferAvailable(const SCPMRingBuffer *ring);
uint64_t SCPMRingBufferDroppedFrames(const SCPMRingBuffer *ring);

/// Registers the allocation-free C audio callback with a Core Audio device.
OSStatus SCPMRingBufferCreateIOProc(
    AudioObjectID deviceID,
    SCPMRingBuffer *ring,
    AudioDeviceIOProcID *outputIOProcID
);
OSStatus SCPMRingBufferDestroyIOProc(
    AudioObjectID deviceID,
    AudioDeviceIOProcID ioProcID
);

/// A lock-free fixed-size snapshot shared by the FFT worker and Metal renderer.
SCSpectrumBuffer *SCSpectrumBufferCreate(void);
void SCSpectrumBufferDestroy(SCSpectrumBuffer *buffer);
void SCSpectrumBufferClear(SCSpectrumBuffer *buffer);
void SCSpectrumBufferPublish(
    SCSpectrumBuffer *buffer,
    const float bands[SCSpectrumBandCount],
    float rms,
    float bassLevel,
    float trebleLevel
);
bool SCSpectrumBufferRead(
    const SCSpectrumBuffer *buffer,
    float outputBands[SCSpectrumBandCount],
    float *outputRMS,
    float *outputBassLevel,
    float *outputTrebleLevel
);

#ifdef __cplusplus
}
#endif

#endif
