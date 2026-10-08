import Foundation
import Combine
import AppKit
import AVFoundation

struct VoiceSession: Identifiable, Codable {
    let id: UUID
    let folderName: String
    let startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var sampleRate: Int
    var sourceApp: String
    var captureMethod: String
    var geminiTranscript: String
    var verifiedTranscript: String
    var reviewed: Bool

    var displayName: String {
        Self.displayDateFormatter.string(from: startedAt)
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy · HH:mm:ss"
        return f
    }()
}

struct ExportReport {
    let url: URL
    let exported: Int
    let excluded: Int
    let voiceReferences: Int
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [VoiceSession] = []
    @Published var status = "Starting..."
    @Published var isRecording = false
    @Published var fnStatus = "Fn not initialized"

    let rootURL: URL
    private var player: AVAudioPlayer?

    init() {
        // Entirely local storage; no cloud services are used by this application.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("VoiceSidecar", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = directories.compactMap { url -> VoiceSession? in
            let file = url.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(VoiceSession.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func prepareSession(sourceApp: String, captureMethod: String) throws -> VoiceSession {
        let id = UUID()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = "\(stamp)_\(id.uuidString.prefix(8))"
        let session = VoiceSession(id: id, folderName: folder, startedAt: Date(),
                                   endedAt: nil, durationSeconds: 0, sampleRate: 0,
                                   sourceApp: sourceApp, captureMethod: captureMethod,
                                   geminiTranscript: "", verifiedTranscript: "", reviewed: false)
        try FileManager.default.createDirectory(at: folderURL(for: session), withIntermediateDirectories: true)
        sessions.insert(session, at: 0)
        persist(session)
        return session
    }

    func complete(_ id: UUID, sampleRate: Int, frameCount: UInt64) {
        guard let index = index(for: id) else { return }
        sessions[index].endedAt = Date()
        sessions[index].sampleRate = sampleRate
        sessions[index].durationSeconds = sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
        persist(sessions[index])
    }

    func discard(_ id: UUID) {
        guard let index = index(for: id) else { return }
        let session = sessions.remove(at: index)
        try? FileManager.default.removeItem(at: folderURL(for: session))
    }

    func addGeminiResult(_ text: String, for id: UUID) {
        guard let index = index(for: id), !sessions[index].reviewed else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[index].geminiTranscript = trimmed
        persist(sessions[index])
        status = "Gemini text captured · review before export"
    }

    func review(_ id: UUID, correctedText: String) {
        guard let index = index(for: id) else { return }
        let clean = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].verifiedTranscript = clean
        sessions[index].reviewed = !clean.isEmpty
        persist(sessions[index])
        status = sessions[index].reviewed ? "Verified transcript saved" : "Review cleared"
    }

    func folderURL(for session: VoiceSession) -> URL {
        rootURL.appendingPathComponent(session.folderName, isDirectory: true)
    }

    func audioURL(for session: VoiceSession) -> URL {
        folderURL(for: session).appendingPathComponent("audio.wav")
    }

    func openDataFolder() {
        NSWorkspace.shared.open(rootURL)
    }

    func play(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: audioURL(for: session))
            player?.play()
        } catch {
            status = "Could not play audio: \(error.localizedDescription)"
        }
    }

    func exportDataset(into parent: URL) throws -> ExportReport {
        let f = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let destination = parent.appendingPathComponent("VoiceSidecar_Dataset_\(stamp.string(from: Date()))", isDirectory: true)
        let wavs = destination.appendingPathComponent("wavs", isDirectory: true)
        let refs = destination.appendingPathComponent("voice_refs", isDirectory: true)
        try f.createDirectory(at: wavs, withIntermediateDirectories: true)
        try f.createDirectory(at: refs, withIntermediateDirectories: true)

        // Do not export unreviewed transcripts or recordings outside the useful range.
        // Long dictations need text-aligned segmentation before TTS training.
        let eligible = sessions.filter {
            $0.reviewed && !$0.verifiedTranscript.isEmpty &&
            $0.durationSeconds >= 1.0 && $0.durationSeconds <= 30.0 &&
            f.fileExists(atPath: audioURL(for: $0).path)
        }
        let excluded = sessions.count - eligible.count
        var ljsLines: [String] = []
        var xttsLines: [String] = ["audio_file|text|speaker_name"]
        var jsonLines: [String] = []

        for session in eligible {
            let stem = session.id.uuidString.lowercased()
            let fileName = "\(stem).wav"
            try f.copyItem(at: audioURL(for: session), to: wavs.appendingPathComponent(fileName))
            let cleanText = sanitizeMetadata(session.verifiedTranscript)
            ljsLines.append("\(stem)|\(cleanText)|\(cleanText)")
            xttsLines.append("wavs/\(fileName)|\(cleanText)|my_voice")
            let json: [String: Any] = [
                "audio_filepath": "wavs/\(fileName)",
                "text": session.verifiedTranscript,
                "duration": session.durationSeconds,
                "speaker": "my_voice",
                "sample_rate": session.sampleRate
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            if let line = String(data: data, encoding: .utf8) { jsonLines.append(line) }
        }

        try (ljsLines.joined(separator: "\n") + (ljsLines.isEmpty ? "" : "\n"))
            .write(to: destination.appendingPathComponent("metadata.csv"), atomically: true, encoding: .utf8)
        try (xttsLines.joined(separator: "\n") + "\n")
            .write(to: destination.appendingPathComponent("metadata_xtts.csv"), atomically: true, encoding: .utf8)
        try (jsonLines.joined(separator: "\n") + (jsonLines.isEmpty ? "" : "\n"))
            .write(to: destination.appendingPathComponent("manifest.jsonl"), atomically: true, encoding: .utf8)

        // Good reference clips for zero-shot voice cloning; never assume models accept any length.
        let candidates = eligible.filter { $0.durationSeconds >= 3.0 && $0.durationSeconds <= 20.0 }
            .sorted { abs($0.durationSeconds - 10.0) < abs($1.durationSeconds - 10.0) }
        let selected = Array(candidates.prefix(12))
        for session in selected {
            try f.copyItem(at: audioURL(for: session),
                           to: refs.appendingPathComponent(session.id.uuidString.lowercased() + ".wav"))
        }
        let instructions = """
        VoiceSidecar local dataset
        =========================
        wavs/              : 16-bit mono lossless PCM WAV at the mic's native sample rate
        metadata.csv        : LJSpeech convention (stem|text|normalized_text), no header
        metadata_xtts.csv   : audio_file|text|speaker_name, with header
        manifest.jsonl      : JSONL with path, transcript, duration, speaker, sample_rate
        voice_refs/         : up to 12 reviewed clips (3-20 s) for voice-cloning references

        Exported: \(eligible.count) reviewed clips. Excluded: \(excluded) clips.
        Review all transcripts against the audio. Gemini may paraphrase or remove fillers.
        Model-specific training scripts may require resampling (e.g. 22050 or 24000 Hz),
        other metadata formats, and Thai text normalization. This export does not train a model.
        Recordings longer than 30 seconds are excluded rather than being incorrectly split.
        All data stays on your Mac unless you share or upload it yourself.
        """
        try instructions.write(to: destination.appendingPathComponent("README.txt"),
                               atomically: true, encoding: .utf8)
        status = "Exported \(eligible.count) reviewed clips"
        return ExportReport(url: destination, exported: eligible.count,
                            excluded: excluded, voiceReferences: selected.count)
    }

    private func sanitizeMetadata(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func index(for id: UUID) -> Int? { sessions.firstIndex(where: { $0.id == id }) }

    private func persist(_ session: VoiceSession) {
        let folder = folderURL(for: session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(session) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        if !session.geminiTranscript.isEmpty {
            try? session.geminiTranscript.write(to: folder.appendingPathComponent("transcript_gemini.txt"),
                                                atomically: true, encoding: .utf8)
        }
        if session.reviewed {
            try? session.verifiedTranscript.write(to: folder.appendingPathComponent("transcript_verified.txt"),
                                                  atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("transcript_verified.txt"))
        }
    }
}
