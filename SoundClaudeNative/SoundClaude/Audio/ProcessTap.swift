import CoreAudio
import Foundation

struct ProcessTapFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: UInt32
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerFrame: UInt32
    let bitsPerChannel: UInt32
}

enum ProcessTapError: LocalizedError {
    case processNotReady
    case unsupportedFormat(ProcessTapFormat)
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .processNotReady:
            return "The app audio process is not ready."
        case let .unsupportedFormat(format):
            return "The audio tap returned an unsupported \(format.bitsPerChannel)-bit format."
        case let .coreAudio(operation, status):
            return "\(operation) failed with Core Audio status \(status)."
        }
    }
}

/// Owns the process tap, its private aggregate device, and its IO procedure.
/// Call all methods from one non-real-time serial queue.
final class ProcessTap: @unchecked Sendable {
    private let ringBuffer: OpaquePointer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(ringBuffer: OpaquePointer) {
        self.ringBuffer = ringBuffer
    }

    deinit {
        stop()
    }

    func start(processIdentifier: pid_t) throws -> ProcessTapFormat {
        stop()

        do {
            let processObjectID = try audioProcessObjectID(
                processIdentifier: processIdentifier
            )
            let description = CATapDescription()
            description.name = "SoundClaude visualizer"
            description.processes = [processObjectID]
            description.isPrivate = true
            description.isMixdown = true
            description.isMono = false
            description.isExclusive = false
            description.muteBehavior = .unmuted

            try check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "Create the process tap"
            )

            let tapUID = try readTapUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundClaude visualizer",
                kAudioAggregateDeviceUIDKey:
                    "com.tim.soundclaude.native.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "Create the private aggregate device"
            )

            try attach(tapUID: tapUID)
            try waitForAggregateInput()

            var streamDescription = try readTapFormat()
            let format = ProcessTapFormat(
                sampleRate: streamDescription.mSampleRate,
                channelCount: streamDescription.mChannelsPerFrame,
                formatID: streamDescription.mFormatID,
                formatFlags: streamDescription.mFormatFlags,
                bytesPerFrame: streamDescription.mBytesPerFrame,
                bitsPerChannel: streamDescription.mBitsPerChannel
            )
            guard SCPMRingBufferConfigure(ringBuffer, &streamDescription) else {
                throw ProcessTapError.unsupportedFormat(format)
            }

            try check(
                SCPMRingBufferCreateIOProc(
                    aggregateDeviceID,
                    ringBuffer,
                    &ioProcID
                ),
                operation: "Create the audio IO procedure"
            )
            guard let ioProcID else {
                throw ProcessTapError.coreAudio(
                    operation: "Create the audio IO procedure",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            try check(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "Start the aggregate device"
            )
            return format
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            SCPMRingBufferDestroyIOProc(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func audioProcessObjectID(
        processIdentifier: pid_t
    ) throws -> AudioObjectID {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyTranslatePIDToProcessObject
        )
        var processIdentifier = processIdentifier
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        let status = withUnsafePointer(to: &processIdentifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.stride),
                qualifier,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw ProcessTapError.processNotReady
        }
        return processObjectID
    }

    private func readTapUID() throws -> CFString {
        var address = propertyAddress(selector: kAudioTapPropertyUID)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        try check(status, operation: "Read the process tap identifier")
        return uid
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        var format = AudioStreamBasicDescription()
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            operation: "Read the process tap format"
        )
        return format
    }

    private func attach(tapUID: CFString) throws {
        var address = propertyAddress(
            selector: kAudioAggregateDevicePropertyTapList
        )
        var tapList: CFArray = [tapUID] as CFArray
        let size = UInt32(MemoryLayout<CFArray>.stride)
        let status = withUnsafeMutablePointer(to: &tapList) { pointer in
            AudioObjectSetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                size,
                pointer
            )
        }
        try check(status, operation: "Attach the tap to the aggregate device")
    }

    private func waitForAggregateInput() throws {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        for _ in 0..<40 {
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                aggregateDeviceID,
                &address,
                0,
                nil,
                &size
            )
            if status == noErr,
               size >= UInt32(MemoryLayout<AudioObjectID>.stride) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ProcessTapError.coreAudio(
            operation: "Wait for the aggregate input stream",
            status: kAudioHardwareNotReadyError
        )
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw ProcessTapError.coreAudio(
                operation: operation,
                status: status
            )
        }
    }
}
