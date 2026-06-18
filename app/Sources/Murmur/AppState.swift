import AppKit
import SwiftUI

enum Status: Equatable {
    case idle, loadingModel, capturing, reading, paused, error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .loadingModel: return "Loading model…"
        case .capturing: return "Capturing…"
        case .reading: return "Reading"
        case .paused: return "Paused"
        case .error(let m): return "Error: \(m)"
        }
    }
    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .loadingModel: return "arrow.down.circle"
        case .capturing: return "text.viewfinder"
        case .reading: return "waveform.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: Status = .idle
    @Published var voices: [VoiceInfo] = []
    @Published var lastCaptured: String = ""
    @Published var lastCleaned: String = ""
    @Published var lastMethod: Capture.Method = .none
    @Published var modelsPresent = false

    let prefs = Prefs.shared
    let backend = BackendManager()
    let audio = AudioPlayer()
    let hotkey = HotKeyManager()

    private var generation = 0   // cancels stale streams

    private init() {
        hotkey.onFire = { [weak self] in self?.triggerRead() }
        audio.onFinished = { [weak self] in self?.finishIfDone() }
    }

    func bootstrap() {
        hotkey.register(prefs.hotKey)
        Task {
            status = .loadingModel
            await backend.start()
            let health = await backend.client.health()
            modelsPresent = backend.ready || (health?.files_present ?? false)
            voices = await backend.client.voices()
            status = backend.ready ? .idle : .error(backend.lastError ?? "Backend not ready")
        }
    }

    func reapplyHotKey() { hotkey.register(prefs.hotKey) }

    // MARK: - read pipeline

    func triggerRead() {
        if status == .reading || status == .paused {
            if prefs.stopOnNewTrigger { stop() } else { return }
        }
        Task { await runRead() }
    }

    private func runRead() async {
        generation += 1
        let gen = generation
        status = .capturing

        let capture: Capture
        if prefs.readSource == .clipboard {
            let pb = NSPasteboard.general.string(forType: .string) ?? ""
            capture = Capture(text: pb, method: .clipboard)
        } else {
            capture = TextCapture.capture(mode: prefs.captureMode)
        }
        lastCaptured = capture.text
        lastMethod = capture.method

        let cleaned = cleanedText(capture.text)
        lastCleaned = cleaned
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .error("No text captured")
            resetToIdle(after: 2)
            return
        }

        if !backend.ready {
            status = .loadingModel
            await backend.start()
            if !backend.ready {
                status = .error(backend.lastError ?? "Backend not ready")
                return
            }
        }

        status = .reading
        audio.start(volume: Float(prefs.volume), pitchCents: Float(prefs.pitch))
        do {
            try await backend.client.streamPCM(text: cleaned, voice: prefs.voice,
                                                speed: prefs.speed) { [weak self] data in
                guard let self, gen == self.generation else { return }
                self.audio.feed(data)
            }
            // drain
            while gen == generation && audio.hasQueued && status == .reading {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if gen == generation && status == .reading { status = .idle }
        } catch {
            if gen == generation { status = .error(error.localizedDescription); resetToIdle(after: 3) }
        }
    }

    func cleanedText(_ raw: String) -> String {
        Preprocess.clean(raw, options: Preprocess.options(for: prefs.profile), custom: prefs.customRules)
    }

    // MARK: - transport

    func pause() { if status == .reading { audio.pause(); status = .paused } }
    func resume() { if status == .paused { audio.resume(); status = .reading } }
    func togglePlayPause() { status == .paused ? resume() : pause() }

    func stop() {
        generation += 1
        audio.stop()
        status = .idle
    }

    func testVoice() {
        Task {
            if !backend.ready { await backend.start() }
            guard backend.ready else { status = .error("Backend not ready"); return }
            generation += 1
            let gen = generation
            status = .reading
            audio.start(volume: Float(prefs.volume), pitchCents: Float(prefs.pitch))
            let sample = "This is the \(prefs.voice) voice, reading at the current settings."
            try? await backend.client.streamPCM(text: sample, voice: prefs.voice, speed: prefs.speed) { [weak self] d in
                guard let self, gen == self.generation else { return }
                self.audio.feed(d)
            }
            while gen == generation && audio.hasQueued { try? await Task.sleep(nanoseconds: 150_000_000) }
            if gen == generation { status = .idle }
        }
    }

    func exportWAV() {
        let text = lastCleaned.isEmpty ? cleanedText(lastCaptured) : lastCleaned
        guard !text.isEmpty else { return }
        Task {
            guard let data = try? await backend.client.wav(text: text, voice: prefs.voice, speed: prefs.speed) else {
                status = .error("Export failed"); return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "murmur.wav"
            panel.allowedContentTypes = [.wav]
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func finishIfDone() {}

    private func resetToIdle(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if case .error = status { status = .idle }
        }
    }
}
