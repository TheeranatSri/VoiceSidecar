import Foundation
import AVFoundation

struct RecordingResult {
    let sampleRate: Int
    let framesWritten: UInt64
}

enum RecorderError: LocalizedError {
    case badInputFormat
    case fileCreationFailed
    case alreadyRecording
    case fileTooLarge
    case notRecording

    var errorDescription: String? {
        switch self {
        case .badInputFormat: return "Microphone did not provide 32-bit float audio."
        case .fileCreationFailed: return "Could not create WAV file."
        case .alreadyRecording: return "A recording is already active."
        case .fileTooLarge: return "WAV is larger than 4 GB; RF64 is not supported."
        case .notRecording: return "No active recording."
        }
    }
}

/// Writes canonical, uncompressed, mono PCM16 WAV at the *device's native sample rate*.
/// Work is serialized on a private queue so the audio callback never waits for disk I/O.
private final class WAVWriter {
    let sampleRate: Int
    private let output: FileHandle
    private let queue = DispatchQueue(label: "local.voicesidecar.wavwriter", qos: .utility)
    private var dataBytes: UInt64 = 0 // accessed only on queue
    private var writeError: Error?     // accessed only on queue

    init(url: URL, sampleRate: Int) throws {
        self.sampleRate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 44)) else {
            throw RecorderError.fileCreationFailed
        }
        output = try FileHandle(forWritingTo: url)
        try output.seek(toOffset: 44)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // Mixed to mono before encoding; clipping is limited to the PCM16 range.
        var data = Data(count: frameCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: UInt16.self)
            for i in 0..<frameCount {
                var value: Float = 0
                for c in 0..<channelCount { value += channels[c][i] }
                value /= Float(channelCount)
                let clamped = max(-1.0, min(1.0, value))
                let pcm = Int16((clamped * 32767.0).rounded())
                samples[i] = UInt16(bitPattern: pcm).littleEndian
            }
        }
        queue.async { [self] in
            guard writeError == nil else { return }
            do {
                try output.write(contentsOf: data)
                dataBytes += UInt64(data.count)
            } catch {
                writeError = error
            }
        }
    }

    func finish() throws -> UInt64 {
        try queue.sync {
            defer { try? output.close() }
            if let writeError { throw writeError }
            guard dataBytes <= UInt64(UInt32.max) - 36 else { throw RecorderError.fileTooLarge }
            let header = Self.header(sampleRate: sampleRate, dataSize: UInt32(dataBytes))
            try output.seek(toOffset: 0)
            try output.write(contentsOf: header)
            try output.synchronize()
            return dataBytes / 2
        }
    }

    private static func header(sampleRate: Int, dataSize: UInt32) -> Data {
        var bytes = Data()
        func ascii(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1)   // format 1 = integer PCM
        u16(1)                           // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))      // byte rate
        u16(2); u16(16)                  // block align, bits/sample
        ascii("data"); u32(dataSize)
        return bytes
    }
}

final class WAVRecorder {
    private var engine: AVAudioEngine?
    private var writer: WAVWriter?
    private var sourceRate = 0

    var isRecording: Bool { engine != nil }

    func start(url: URL) throws {
        guard engine == nil else { throw RecorderError.alreadyRecording }
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else { throw RecorderError.badInputFormat }
        let newWriter = try WAVWriter(url: url, sampleRate: Int(format.sampleRate.rounded()))
        do {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [newWriter] buffer, _ in
                newWriter.append(buffer)
            }
            try newEngine.start()
            sourceRate = Int(format.sampleRate.rounded())
            engine = newEngine
            writer = newWriter
        } catch {
            input.removeTap(onBus: 0)
            newEngine.stop()
            _ = try? newWriter.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() throws -> RecordingResult {
        guard let activeEngine = engine, let activeWriter = writer else {
            throw RecorderError.notRecording
        }
        activeEngine.inputNode.removeTap(onBus: 0)
        activeEngine.stop()
        engine = nil
        writer = nil
        let frames = try activeWriter.finish()
        return RecordingResult(sampleRate: sourceRate, framesWritten: frames)
    }
}
