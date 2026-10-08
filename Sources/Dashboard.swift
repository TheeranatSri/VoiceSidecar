import SwiftUI

struct Dashboard: View {
    @ObservedObject var store: SessionStore
    let onExport: () -> Void
    let onPermissions: () -> Void
    let onManualToggle: () -> Void

    @State private var selectedID: UUID?
    @State private var editor = ""

    private var selected: VoiceSession? {
        guard let selectedID else { return nil }
        return store.sessions.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: store.isRecording ? "record.circle.fill" : "waveform")
                    .font(.title2)
                    .foregroundStyle(store.isRecording ? Color.red : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceSidecar").font(.headline)
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.isRecording ? "Stop recording" : "Manual record") { onManualToggle() }
                Button("Permissions") { onPermissions() }
                Button("Export dataset…") { onExport() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECORDINGS (\(store.sessions.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 12)
                    List(selection: $selectedID) {
                        ForEach(store.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(session.displayName).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Image(systemName: session.reviewed ? "checkmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(session.reviewed ? Color.green : Color.secondary)
                                }
                                Text("\(session.sourceApp) · \(String(format: "%.1f", session.durationSeconds))s")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if !session.geminiTranscript.isEmpty {
                                    Text(session.geminiTranscript).font(.caption).lineLimit(2)
                                } else {
                                    Text("No Gemini text · paste transcript to review")
                                        .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 5)
                            .tag(session.id)
                        }
                    }
                }
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 370)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let session = selected {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayName).font(.title3.weight(.medium))
                                Text("\(session.captureMethod) · \(session.sourceApp) · \(String(format: "%.2f", session.durationSeconds)) sec · \(session.sampleRate) Hz")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { store.play(session.id) } label: {
                                Label("Play WAV", systemImage: "play.circle")
                            }
                            .disabled(session.sampleRate == 0)
                        }
                        Divider()
                        Text("GEMINI OUTPUT (UNVERIFIED)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            Text(session.geminiTranscript.isEmpty
                                 ? "Not captured. This app cannot extract Gemini text from every editor. You can paste the actual transcript below."
                                 : session.geminiTranscript)
                                .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(10).frame(minHeight: 70, maxHeight: 155)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Text("VERIFIED TRANSCRIPT — EDIT TO MATCH THE AUDIO EXACTLY")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use Gemini text") {
                                editor = session.geminiTranscript
                            }
                            .disabled(session.geminiTranscript.isEmpty)
                        }
                        TextEditor(text: $editor)
                            .font(.body)
                            .padding(5)
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.secondary.opacity(0.25)))
                        HStack {
                            Label(session.reviewed ? "Reviewed — included if 1–30 sec" : "Not reviewed — excluded from export",
                                  systemImage: session.reviewed ? "checkmark.seal.fill" : "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(session.reviewed ? Color.green : Color.secondary)
                            Spacer()
                            Button("Save verified text") {
                                store.review(session.id, correctedText: editor)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(editor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (session.reviewed && editor == session.verifiedTranscript))
                        }
                        Text("Gemini cleans up speech (and may rewrite it). Listen and correct omissions, fillers, names and Thai words before saving. A missing transcript is not auto-filled.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Spacer()
                        Text("Select a recording to review").font(.title3).foregroundStyle(.secondary)
                        Text("Hold Fn while speaking into Gemini. Release Fn to save the WAV. Gemini text is captured when the target editor supports Accessibility.")
                            .frame(maxWidth: 330).multilineTextAlignment(.center)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer(minLength: 0)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(store.fnStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Local only · original WAV + JSON + TXT in Application Support")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(minWidth: 900, minHeight: 585)
        .onAppear {
            if selectedID == nil { selectedID = store.sessions.first?.id }
            loadEditor()
        }
        .onChange(of: selectedID) { _ in loadEditor() }
        .onChange(of: selected?.geminiTranscript ?? "") { newValue in
            if let selected, !selected.reviewed, editor.isEmpty { editor = newValue }
        }
    }

    private func loadEditor() {
        guard let s = selected else { editor = ""; return }
        editor = s.reviewed ? s.verifiedTranscript : s.geminiTranscript
    }
}
