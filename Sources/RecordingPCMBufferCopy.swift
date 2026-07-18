import AVFoundation
import Foundation

enum RecordingPCMBufferCopyError: Error, Equatable {
    case unsupportedFormat
    case missingAudioData
    case invalidByteCount
}

enum RecordingPCMBufferCopy {
    static func data(from buffer: AVAudioPCMBuffer) throws -> Data {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatInt16,
              format.sampleRate == 16_000,
              format.channelCount == 1,
              format.isInterleaved else {
            throw RecordingPCMBufferCopyError.unsupportedFormat
        }

        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return Data() }

        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard Int(audioBuffer.mDataByteSize) >= byteCount else {
            throw RecordingPCMBufferCopyError.invalidByteCount
        }
        guard let baseAddress = audioBuffer.mData else {
            throw RecordingPCMBufferCopyError.missingAudioData
        }
        return Data(bytes: baseAddress, count: byteCount)
    }
}
