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
    @Published var axTrusted = Permissions.axTrusted

    let prefs = Prefs.shared
    let backend = BackendManager()
    let audio = AudioPlayer()
    let hotkey = HotKeyManager()

    private var generation = 0   // cancels stale streams
    private var playingText = "" // text currently being read (for the smart toggle)

    private init() {
        hotkey.onFire = { [weak self] in self?.triggerRead() }
        audio.onFinished = { [weak self] in self?.finishIfDone() }
    }

    func bootstrap() {
        hotkey.register(prefs.hotKey)
        Log.write("bootstrap: axTrusted=\(Permissions.axTrusted) readSource=\(prefs.readSource.rawValue) captureMode=\(prefs.captureMode.rawValue)")
        // Selection capture needs Accessibility. Prompt up front so the user
        // isn't met with a silent "No text captured" later.
        if prefs.readSource == .selection && !Permissions.axTrusted {
            Permissions.requestAX()
        }
        // Keep the published trust flag fresh (granting happens out of process).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.axTrusted = Permissions.axTrusted }
        }
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

    func triggerRead() { Task { await runRead() } }

    private func runRead() async {
        let wasPlaying = (status == .reading || status == .paused)
        // Honor the "ignore re-trigger" preference if the user turned it off.
        if wasPlaying && !prefs.stopOnNewTrigger { return }

        generation += 1
        let gen = generation
        if !wasPlaying { status = .capturing }

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
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Smart toggle: pressing the shortcut while audio is playing either
        // switches to freshly-selected text, or — if nothing new is selected —
        // just stops. No need to reach for the Stop button.
        if wasPlaying {
            if trimmed.isEmpty || cleaned == playingText {
                Log.write("trigger while playing, no new text -> stop")
                stop()
                return
            }
            Log.write("trigger while playing, new text -> switch")
            audio.stop()   // generation already advanced; old stream is now stale
        }

        lastCleaned = cleaned
        guard !trimmed.isEmpty else {
            // Distinguish "nothing selected" from "can't capture because no permission".
            if prefs.readSource == .selection && !Permissions.axTrusted {
                Log.write("read aborted: no capture and Accessibility not granted")
                status = .error("Grant Accessibility to capture")
                Permissions.requestAX()
            } else {
                Log.write("read aborted: no text captured (source=\(prefs.readSource.rawValue))")
                status = .error("No text captured")
            }
            resetToIdle(after: 3)
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

        playingText = cleaned
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
            if gen == generation && status == .reading { status = .idle; playingText = "" }
        } catch {
            if gen == generation { status = .error(error.localizedDescription); resetToIdle(after: 3) }
        }
    }

    /// Language-appropriate preview line so non-English voices phonemize
    /// real text in their own language instead of mangled English.
    static func sampleText(for voice: String) -> String {
        switch voice.prefix(2) {
        case "ef", "em": return "Hola, esta es una prueba de la voz."
        case "ff":       return "Bonjour, ceci est un test de la voix."
        case "hf", "hm": return "नमस्ते, यह आवाज़ का एक परीक्षण है।"
        case "if", "im": return "Ciao, questa è una prova della voce."
        case "jf", "jm": return "こんにちは、これは音声のテストです。"
        case "pf", "pm": return "Olá, este é um teste da voz."
        case "zf", "zm": return "你好，这是语音测试。"
        default:         return "This is a preview of the selected voice."
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
        playingText = ""
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
            let sample = Self.sampleText(for: prefs.voice)
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
