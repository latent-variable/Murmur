import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab().tabItem { Label("Voice & Audio", systemImage: "waveform") }
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
        Form {
            Section("Voice") {
                Picker("Voice", selection: $prefs.voice) {
                    ForEach(groupedVoices, id: \.0) { lang, list in
                        Section(lang) {
                            ForEach(list) { v in Text(name(v)).tag(v.id) }
                        }
                    }
                    if state.voices.isEmpty { Text(prefs.voice).tag(prefs.voice) }
                }
                Button("Test voice") { state.testVoice() }
            }
            Section("Playback") {
                slider("Speed", $prefs.speed, 0.5...2.0, "%.2f×")
                slider("Pitch", $prefs.pitch, -600...600, "%.0f¢")
                slider("Volume", $prefs.volume, 0...1, "%.0f%%", scale: 100)
            }
        }
        .formStyle(.grouped)
    }

    private var groupedVoices: [(String, [VoiceInfo])] {
        Dictionary(grouping: state.voices, by: \.lang_label)
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    private func name(_ v: VoiceInfo) -> String {
        let base = v.id.split(separator: "_").last.map(String.init)?.capitalized ?? v.id
        return "\(base) (\(v.gender == "female" ? "♀" : "♂"))"
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
                    Text(trusted ? "Granted — direct selected-text capture available"
                                 : "Not granted — falls back to clipboard copy")
                    Spacer()
                }
                HStack {
                    Button("Request access") { Permissions.requestAX() }
                    Button("Open Settings") { Permissions.openAXSettings() }
                    Button("Recheck") { trusted = Permissions.axTrusted }
                }
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
