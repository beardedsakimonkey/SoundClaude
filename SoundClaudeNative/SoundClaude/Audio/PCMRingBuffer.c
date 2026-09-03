#include "PCMRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be lock-free");

struct SCPMRingBuffer {
    float *samples;
    uint32_t capacity;
    AudioStreamBasicDescription format;
    atomic_uint_fast64_t readPosition;
    atomic_uint_fast64_t writePosition;
    atomic_uint_fast64_t droppedFrames;
    atomic_bool isConfigured;
};

struct SCSpectrumBuffer {
    atomic_uint_fast64_t sequence;
    atomic_uint_least32_t bands[SCSpectrumBandCount];
    atomic_uint_least32_t rms;
};

static uint32_t SCFloatBits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float SCBitsFloat(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

SCPMRingBuffer *SCPMRingBufferCreate(uint32_t capacity) {
    if (capacity == 0) {
        return NULL;
    }

    SCPMRingBuffer *ring = calloc(1, sizeof(*ring));
    if (ring == NULL) {
        return NULL;
    }

    ring->samples = calloc(capacity, sizeof(float));
    if (ring->samples == NULL) {
        free(ring);
        return NULL;
    }

    ring->capacity = capacity;
    atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->writePosition, 0);
    atomic_init(&ring->droppedFrames, 0);
    atomic_init(&ring->isConfigured, false);
    return ring;
}

void SCPMRingBufferDestroy(SCPMRingBuffer *ring) {
    if (ring == NULL) {
        return;
    }
    free(ring->samples);
    free(ring);
}

bool SCPMRingBufferConfigure(
    SCPMRingBuffer *ring,
    const AudioStreamBasicDescription *format
) {
    if (ring == NULL || format == NULL) {
        return false;
    }

    const AudioFormatFlags requiredFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    const bool isFloatPCM = format->mFormatID == kAudioFormatLinearPCM
        && (format->mFormatFlags & requiredFlags) == requiredFlags
        && (format->mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
        && format->mBitsPerChannel == 32
        && format->mBytesPerFrame >= sizeof(float)
        && format->mSampleRate > 0
        && format->mChannelsPerFrame > 0;
    if (!isFloatPCM) {
        atomic_store_explicit(&ring->isConfigured, false, memory_order_release);
        return false;
    }

    ring->format = *format;
    atomic_store_explicit(&ring->isConfigured, true, memory_order_release);
    return true;
}

void SCPMRingBufferReset(SCPMRingBuffer *ring) {
    if (ring == NULL) {
        return;
    }
    memset(ring->samples, 0, ring->capacity * sizeof(float));
    atomic_store_explicit(&ring->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->writePosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->droppedFrames, 0, memory_order_relaxed);
}

uint32_t SCPMRingBufferAvailable(const SCPMRingBuffer *ring) {
    if (ring == NULL) {
        return 0;
    }
    const uint64_t write = atomic_load_explicit(
        &ring->writePosition,
        memory_order_acquire
    );
    const uint64_t read = atomic_load_explicit(
        &ring->readPosition,
        memory_order_relaxed
    );
    const uint64_t available = write - read;
    return available > UINT32_MAX ? UINT32_MAX : (uint32_t)available;
}

uint64_t SCPMRingBufferDroppedFrames(const SCPMRingBuffer *ring) {
    if (ring == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ring->droppedFrames, memory_order_relaxed);
}

uint32_t SCPMRingBufferRead(
    SCPMRingBuffer *ring,
    float *output,
    uint32_t maximumFrameCount
) {
    if (ring == NULL || output == NULL || maximumFrameCount == 0) {
        return 0;
    }

    const uint64_t read = atomic_load_explicit(
        &ring->readPosition,
        memory_order_relaxed
    );
    const uint64_t write = atomic_load_explicit(
        &ring->writePosition,
        memory_order_acquire
    );
    const uint64_t available = write - read;
    const uint32_t count = available < maximumFrameCount
        ? (uint32_t)available
        : maximumFrameCount;

    for (uint32_t index = 0; index < count; ++index) {
        output[index] = ring->samples[(read + index) % ring->capacity];
    }
    atomic_store_explicit(
        &ring->readPosition,
        read + count,
        memory_order_release
    );
    return count;
}

static uint32_t SCFrameCount(const AudioBufferList *inputData) {
    uint32_t frameCount = UINT32_MAX;
    bool foundBuffer = false;

    for (uint32_t bufferIndex = 0;
         bufferIndex < inputData->mNumberBuffers;
         ++bufferIndex) {
        const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        const uint32_t stride = (uint32_t)sizeof(float)
            * buffer->mNumberChannels;
        const uint32_t count = stride == 0
            ? 0
            : buffer->mDataByteSize / stride;
        frameCount = count < frameCount ? count : frameCount;
        foundBuffer = true;
    }
    return foundBuffer ? frameCount : 0;
}

static void SCWriteAudio(
    SCPMRingBuffer *ring,
    const AudioBufferList *inputData
) {
    if (!atomic_load_explicit(&ring->isConfigured, memory_order_acquire)) {
        return;
    }

    const uint32_t frameCount = SCFrameCount(inputData);
    if (frameCount == 0) {
        return;
    }

    const uint64_t write = atomic_load_explicit(
        &ring->writePosition,
        memory_order_relaxed
    );
    const uint64_t read = atomic_load_explicit(
        &ring->readPosition,
        memory_order_acquire
    );
    const uint64_t used = write - read;
    const uint32_t freeFrames = used >= ring->capacity
        ? 0
        : ring->capacity - (uint32_t)used;
    const uint32_t writeCount = frameCount < freeFrames
        ? frameCount
        : freeFrames;

    for (uint32_t frame = 0; frame < writeCount; ++frame) {
        float sum = 0.0f;
        uint32_t channelCount = 0;
        for (uint32_t bufferIndex = 0;
             bufferIndex < inputData->mNumberBuffers;
             ++bufferIndex) {
            const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
            if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
                continue;
            }
            const float *samples = (const float *)buffer->mData;
            for (uint32_t channel = 0;
                 channel < buffer->mNumberChannels;
                 ++channel) {
                sum += samples[(frame * buffer->mNumberChannels) + channel];
                ++channelCount;
            }
        }
        if (channelCount > 0) {
            ring->samples[(write + frame) % ring->capacity] =
                sum / (float)channelCount;
        }
    }

    if (writeCount < frameCount) {
        atomic_fetch_add_explicit(
            &ring->droppedFrames,
            frameCount - writeCount,
            memory_order_relaxed
        );
    }
    atomic_store_explicit(
        &ring->writePosition,
        write + writeCount,
        memory_order_release
    );
}

static OSStatus SCAudioIOProc(
    AudioObjectID deviceID,
    const AudioTimeStamp *currentTime,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *outputData,
    const AudioTimeStamp *outputTime,
    void *clientData
) {
    (void)deviceID;
    (void)currentTime;
    (void)inputTime;
    (void)outputData;
    (void)outputTime;

    SCPMRingBuffer *ring = clientData;
    if (ring != NULL && inputData != NULL) {
        SCWriteAudio(ring, inputData);
    }
    return noErr;
}

OSStatus SCPMRingBufferCreateIOProc(
    AudioObjectID deviceID,
    SCPMRingBuffer *ring,
    AudioDeviceIOProcID *outputIOProcID
) {
    if (ring == NULL || outputIOProcID == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    return AudioDeviceCreateIOProcID(
        deviceID,
        SCAudioIOProc,
        ring,
        outputIOProcID
    );
}

OSStatus SCPMRingBufferDestroyIOProc(
    AudioObjectID deviceID,
    AudioDeviceIOProcID ioProcID
) {
    return AudioDeviceDestroyIOProcID(deviceID, ioProcID);
}

SCSpectrumBuffer *SCSpectrumBufferCreate(void) {
    SCSpectrumBuffer *buffer = calloc(1, sizeof(*buffer));
    if (buffer == NULL) {
        return NULL;
    }
    atomic_init(&buffer->sequence, 0);
    atomic_init(&buffer->rms, SCFloatBits(0.0f));
    for (uint32_t index = 0; index < SCSpectrumBandCount; ++index) {
        atomic_init(&buffer->bands[index], SCFloatBits(0.0f));
    }
    return buffer;
}

void SCSpectrumBufferDestroy(SCSpectrumBuffer *buffer) {
    free(buffer);
}

void SCSpectrumBufferClear(SCSpectrumBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }
    float zeros[SCSpectrumBandCount] = {0};
    SCSpectrumBufferPublish(buffer, zeros, 0.0f);
}

void SCSpectrumBufferPublish(
    SCSpectrumBuffer *buffer,
    const float bands[SCSpectrumBandCount],
    float rms
) {
    if (buffer == NULL || bands == NULL) {
        return;
    }

    const uint64_t previous = atomic_load_explicit(
        &buffer->sequence,
        memory_order_relaxed
    );
    const uint64_t writing = (previous & 1U) == 0 ? previous + 1 : previous + 2;
    atomic_store_explicit(&buffer->sequence, writing, memory_order_release);

    for (uint32_t index = 0; index < SCSpectrumBandCount; ++index) {
        atomic_store_explicit(
            &buffer->bands[index],
            SCFloatBits(bands[index]),
            memory_order_relaxed
        );
    }
    atomic_store_explicit(&buffer->rms, SCFloatBits(rms), memory_order_relaxed);
    atomic_store_explicit(&buffer->sequence, writing + 1, memory_order_release);
}

bool SCSpectrumBufferRead(
    const SCSpectrumBuffer *buffer,
    float outputBands[SCSpectrumBandCount],
    float *outputRMS
) {
    if (buffer == NULL || outputBands == NULL) {
        return false;
    }

    float snapshot[SCSpectrumBandCount];
    for (uint32_t attempt = 0; attempt < 3; ++attempt) {
        const uint64_t before = atomic_load_explicit(
            &buffer->sequence,
            memory_order_acquire
        );
        if ((before & 1U) != 0) {
            continue;
        }
        for (uint32_t index = 0; index < SCSpectrumBandCount; ++index) {
            const uint32_t bits = atomic_load_explicit(
                &buffer->bands[index],
                memory_order_relaxed
            );
            snapshot[index] = SCBitsFloat(bits);
        }
        const float rms = SCBitsFloat(atomic_load_explicit(
            &buffer->rms,
            memory_order_relaxed
        ));
        const uint64_t after = atomic_load_explicit(
            &buffer->sequence,
            memory_order_acquire
        );
        if (before == after) {
            memcpy(outputBands, snapshot, sizeof(snapshot));
            if (outputRMS != NULL) {
                *outputRMS = rms;
            }
            return true;
        }
    }
    return false;
}
