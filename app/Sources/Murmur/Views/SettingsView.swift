import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab().tabItem { Label("Voice & Audio", systemImage: "waveform") }
            EngineTab().tabItem { Label("Engine", systemImage: "cpu") }
            CaptureTab().tabItem { Label("Capture", systemImage: "text.viewfinder") }
            CleanupTab().tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            ShortcutTab().tabItem { Label("Shortcut", systemImage: "command") }
            ModelsTab().tabItem { Label("Models", systemImage: "cube.box") }
            DiagnosticsTab().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(16)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Picker("Read source", selection: $prefs.readSource) {
                ForEach(ReadSource.allCases) { Text($0.label).tag($0) }
            }
            Picker("Cleanup profile", selection: $prefs.profile) {
                ForEach(Profile.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Stop current speech when shortcut pressed again", isOn: $prefs.stopOnNewTrigger)
            Toggle("Keep model warm", isOn: $prefs.keepWarm)
            Toggle("Show mini-player controls", isOn: $prefs.showMiniPlayer)
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                .onChange(of: prefs.launchAtLogin) { _, on in LoginItem.set(on) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice & Audio

private struct VoiceTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voice").font(.headline)
                Spacer()
                Button { state.testVoice() } label: { Label("Test", systemImage: "speaker.wave.2.fill") }
                    .controlSize(.small)
            }
            VoicePickerList(voices: state.voices, selection: $prefs.voice)
                .frame(minHeight: 220)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            Form {
                Section("Playback") {
                    slider("Speed", $prefs.speed, 0.5...2.0, "%.2f×")
                    slider("Pitch", $prefs.pitch, -600...600, "%.0f¢")
                    slider("Volume", $prefs.volume, 0...1, "%.0f%%", scale: 100)
                    slider("Pause", $prefs.pauseScale, 0...2.5, "%.2f×")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ fmt: String, scale: Double = 1) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Engine (Kokoro / Chatterbox HD)

private struct EngineTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @State private var installing = false
    @State private var installLog = ""
    @State private var showImporter = false
    @State private var newName = ""

    var body: some View {
        Form {
            Section("Voice engine") {
                Picker("Engine", selection: $prefs.engine) {
                    Text("Kokoro — instant, 54 voices").tag("kokoro")
                    Text("Chatterbox HD — higher quality, cloned voices").tag("chatterbox")
                }
                .pickerStyle(.radioGroup)
                Text("Kokoro runs on CPU and starts instantly. Chatterbox HD uses the GPU for noticeably more natural speech, with a few seconds of startup. Switch any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if prefs.engine == "chatterbox" {
                if !state.hdInstalled {
                    Section("Enable HD") {
                        Text("HD mode downloads its engine (~1.3 GB, one time) into Application Support — it is not bundled, so the app stays small.")
                            .font(.caption).foregroundStyle(.secondary)
                        if installing {
                            ProgressView().controlSize(.small)
                            ScrollView { Text(installLog).font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(height: 120).border(.quaternary)
                        } else {
                            Button("Download & enable HD") { startInstall() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Section("HD voices (cloned)") {
                        if state.hdVoices.isEmpty {
                            Text("No reference voices yet. Add a 10-20s clean audio clip of any voice you have the rights to use.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Voice", selection: $prefs.hdVoice) {
                            ForEach(state.hdVoices) { v in Text(v.id).tag(v.id) }
                            if state.hdVoices.isEmpty { Text("—").tag("") }
                        }
                        HStack {
                            TextField("New voice name", text: $newName).frame(width: 160)
                            Button("Add reference clip…") { showImporter = true }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Spacer()
                            Button("Test voice") { state.testVoice() }
                        }
                        Button {
                            installing = true; installLog = "fetching starter voices…\n"
                            state.fetchStarterVoices { line in
                                installLog += line + "\n"
                                if line.contains("[refreshed]") { installing = false }
                            }
                        } label: { Label("Get free starter voices (CMU ARCTIC)", systemImage: "square.and.arrow.down") }
                            .controlSize(.small).disabled(installing)
                        if installing && installLog.contains("fetching starter") {
                            ScrollView { Text(installLog).font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 70)
                        }
                        if !prefs.hdVoice.isEmpty {
                            Button(role: .destructive) { state.deleteHDVoice(prefs.hdVoice) } label: {
                                Label("Delete \"\(prefs.hdVoice)\"", systemImage: "trash")
                            }.controlSize(.small)
                        }
                    }
                    Section {
                        Label("HD audio is watermarked (Resemble Perth) to mark it as AI-generated. Only clone voices you have permission to use.",
                              systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshHD() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                let ok = url.startAccessingSecurityScopedResource()
                state.addHDVoice(from: url, name: newName)
                if ok { url.stopAccessingSecurityScopedResource() }
                newName = ""
            }
        }
    }

    private func startInstall() {
        installing = true; installLog = ""
        state.installHD { line in
            installLog += line + "\n"
            if line.contains("HD ready") { installing = false }
        }
    }
}

// MARK: - Capture

private struct CaptureTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var trusted = Permissions.axTrusted
    var body: some View {
        Form {
            Picker("Capture method", selection: $prefs.captureMode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            Section("Accessibility permission") {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Granted — Murmur can read your selected text"
                                 : "Not granted")
                    Spacer()
                }
                HStack {
                    Button("Request access") { Permissions.requestAX() }
                    Button("Open Settings") { Permissions.openAXSettings() }
                    Button("Recheck") { trusted = Permissions.axTrusted }
                }
            }
            Section("Why this is needed") {
                Text("macOS only lets a trusted app read another app's selected text, and only a trusted app can simulate ⌘C for the clipboard fallback. That's the sole reason Murmur asks.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("No keylogging, no screen reading, nothing sent anywhere — it reads only the text you select and trigger. All local, all open source.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Prefer no permission? Set Capture method or Read source to Clipboard, then copy text yourself before pressing the shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Last capture") {
                LabeledContent("Method", value: state.lastMethod.rawValue)
                if !state.lastCaptured.isEmpty {
                    Text(state.lastCaptured).font(.caption).lineLimit(4)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = Permissions.axTrusted }
    }
}

// MARK: - Cleanup

private struct CleanupTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var sample = "## Heading\n\nSee **the docs** [here](https://x.com) for `code`.\n- bullet one\n- bullet two\n\n$ echo hi  [1]"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.headline)
            HStack(spacing: 10) {
                VStack(alignment: .leading) {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $sample).font(.caption.monospaced())
                        .frame(height: 110).border(.quaternary)
                }
                VStack(alignment: .leading) {
                    Text("Spoken").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(cleaned).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 110).border(.quaternary)
                }
            }
            Picker("Profile", selection: $prefs.profile) {
                ForEach(Profile.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)

            HStack {
                Text("Custom regex rules").font(.headline)
                Spacer()
                Button {
                    prefs.customRules.append(CleanRule(name: "New rule", pattern: "", replacement: ""))
                } label: { Image(systemName: "plus") }
            }
            List {
                ForEach($prefs.customRules) { $rule in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        TextField("name", text: $rule.name).frame(width: 90)
                        TextField("pattern", text: $rule.pattern).font(.caption.monospaced())
                        TextField("→ repl", text: $rule.replacement).font(.caption.monospaced()).frame(width: 90)
                        Button(role: .destructive) {
                            prefs.customRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 90)
        }
    }
    private var cleaned: String {
        Preprocess.clean(sample, options: Preprocess.options(for: prefs.profile), custom: prefs.customRules)
    }
}

// MARK: - Shortcut

private struct ShortcutTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section("Global read shortcut") {
                HStack {
                    Text("Current"); Spacer()
                    HotKeyRecorder(combo: $prefs.hotKey) { state.reapplyHotKey() }
                }
                Text("Click the field, then press a modifier + key combination (e.g. ⌘⇧R).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Records the next modifier+key chord into a HotKeyCombo.
private struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording.toggle()
            recording ? startMonitor() : stopMonitor()
        } label: {
            Text(recording ? "Press keys…" : KeyName.describe(combo))
                .font(.body.monospaced())
                .frame(minWidth: 110)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(recording ? Color.accentColor.opacity(0.2) : Color(.quaternaryLabelColor),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let mods = KeyName.carbonModifiers(ev.modifierFlags)
            guard mods != 0 else { return ev } // require a modifier
            combo = HotKeyCombo(keyCode: UInt32(ev.keyCode), modifiers: mods)
            onChange()
            recording = false
            stopMonitor()
            return nil
        }
    }
    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Models

private struct ModelsTab: View {
    @EnvironmentObject var state: AppState
    @StateObject private var dl = ModelDownloader(modelsDir: AppState.shared.backend.modelsDir)
    var body: some View {
        Form {
            Section("Kokoro model") {
                LabeledContent("Status",
                    value: state.modelsPresent ? "Installed" : "Not installed")
                LabeledContent("Location", value: AppState.shared.backend.modelsDir.path)
                    .font(.caption)
                if dl.downloading {
                    ProgressView(value: dl.progress) { Text(dl.statusText).font(.caption) }
                } else if !state.modelsPresent {
                    Button("Download model (~340 MB)") { dl.start() }
                }
                if let e = dl.error { Text(e).font(.caption).foregroundStyle(.red) }
                if dl.done { Text("Downloaded. Restart playback to load.").font(.caption).foregroundStyle(.green) }
            }
            Section {
                Text("Voices included: 54 across English, Spanish, French, Italian, Hindi, Japanese, Portuguese, and Chinese.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: dl.done) { _, done in
            if done { Task { await state.backend.start(); state.modelsPresent = state.backend.ready } }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @State private var health = "checking…"
    @State private var activeProvider = "—"
    @State private var availableProviders = "—"
    var body: some View {
        Form {
            Section("Backend") {
                LabeledContent("Ready", value: state.backend.ready ? "yes" : "no")
                LabeledContent("Health", value: health)
                if let e = state.backend.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                Button("Recheck") { Task { await refresh() } }
                Button("Open backend log") {
                    NSWorkspace.shared.open(FileManager.default.temporaryDirectory
                        .appending(path: "murmur_backend.log"))
                }
            }
            Section("Acceleration") {
                Picker("Compute", selection: $prefs.providerMode) {
                    Text("Auto (CPU — fastest for Kokoro)").tag("auto")
                    Text("CPU").tag("cpu")
                    Text("CoreML (GPU / Neural Engine)").tag("coreml")
                }
                LabeledContent("Active", value: activeProvider)
                LabeledContent("Available", value: availableProviders)
                Text("Kokoro is small (82M); the vectorized CPU path benchmarks as fast as or faster than CoreML. Changing this restarts the engine.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply & restart engine") {
                    Task { state.backend.stop(); state.backend.ready = false
                           await state.backend.start(); await refresh() }
                }
            }
            Section("Capture") {
                LabeledContent("Accessibility trusted", value: Permissions.axTrusted ? "yes" : "no")
                LabeledContent("Last method", value: state.lastMethod.rawValue)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }
    private func refresh() async {
        if let h = await state.backend.client.health() {
            health = "\(h.status) · model \(h.model_loaded ? "loaded" : "off") · \(h.sample_rate) Hz"
            activeProvider = (h.active_providers?.first ?? "unknown")
                .replacingOccurrences(of: "ExecutionProvider", with: "")
            availableProviders = (h.available_providers ?? [])
                .map { $0.replacingOccurrences(of: "ExecutionProvider", with: "") }
                .joined(separator: ", ")
        } else { health = "unreachable" }
    }
}
