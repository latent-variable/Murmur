import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @Environment(\.openSettings) private var openSettings

    /// Open Settings and force it to the front, even when the app is an
    /// accessory (no dock icon) and the window is already buried behind others.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            HStack(spacing: 10) {
                Picker("", selection: $prefs.voice) {
                    ForEach(state.voices) { v in
                        Text("\(displayName(v))").tag(v.id)
                    }
                    if state.voices.isEmpty { Text(prefs.voice).tag(prefs.voice) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button { state.testVoice() } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .help("Test voice")
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Speed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f×", prefs.speed)).font(.caption.monospacedDigit())
                }
                Slider(value: $prefs.speed, in: 0.5...2.0, step: 0.05)
            }

            transport

            Divider()

            HStack {
                Text("Read shortcut")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(KeyName.describe(prefs.hotKey))
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }

            if !state.lastCleaned.isEmpty {
                preview
            }

            Divider()

            HStack {
                Button { showSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.status.symbol)
                .font(.title3)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: state.status == .reading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmur").font(.headline)
                Text(state.status.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !state.modelsPresent {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .help("Models not installed — open Settings ▸ Models")
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { state.togglePlayPause() } label: {
                Image(systemName: state.status == .paused ? "play.fill" : "pause.fill")
                    .font(.title2)
            }
            .disabled(state.status != .reading && state.status != .paused)

            Button { state.stop() } label: {
                Image(systemName: "stop.fill").font(.title2)
            }
            .disabled(state.status != .reading && state.status != .paused)

            Spacer()

            Button { state.triggerRead() } label: {
                Label("Read selection", systemImage: "text.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var preview: some View {
        DisclosureGroup("Last read") {
            ScrollView {
                Text(state.lastCleaned)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            HStack {
                Text(state.lastMethod == .none ? "" : "via \(state.lastMethod.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.lastCleaned, forType: .string)
                }.controlSize(.mini)
                Button("Export WAV") { state.exportWAV() }.controlSize(.mini)
            }
        }
        .font(.caption)
    }

    private var statusColor: Color {
        switch state.status {
        case .reading: return .accentColor
        case .paused: return .orange
        case .error: return .red
        case .loadingModel: return .blue
        default: return .secondary
        }
    }

    private func displayName(_ v: VoiceInfo) -> String {
        let base = v.id.split(separator: "_").last.map(String.init)?.capitalized ?? v.id
        let flag = v.gender == "female" ? "♀" : "♂"
        return "\(base) · \(v.lang_label) \(flag)"
    }
}
