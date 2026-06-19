import SwiftUI

extension VoiceInfo {
    /// "Puck · English (US) ♂"
    var display: String {
        let base = id.split(separator: "_").last.map(String.init)?.capitalized ?? id
        return "\(base) · \(lang_label) \(gender == "female" ? "♀" : "♂")"
    }
    var shortName: String {
        let base = id.split(separator: "_").last.map(String.init)?.capitalized ?? id
        return "\(base) \(gender == "female" ? "♀" : "♂")"
    }
}

/// Scrollable, searchable, language-grouped voice list. Replaces the native
/// Picker menu, which gives no indication there are more voices to scroll to.
struct VoicePickerList: View {
    let voices: [VoiceInfo]
    @Binding var selection: String
    var onPick: (() -> Void)? = nil
    @State private var query = ""

    private var grouped: [(String, [VoiceInfo])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? voices : voices.filter {
            $0.display.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        return Dictionary(grouping: filtered, by: \.lang_label)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search \(voices.count) voices", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            ScrollViewReader { proxy in
                List {
                    ForEach(grouped, id: \.0) { lang, list in
                        Section(lang) {
                            ForEach(list) { v in row(v) }
                        }
                    }
                    if grouped.isEmpty {
                        Text("No matches").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .listStyle(.inset)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private func row(_ v: VoiceInfo) -> some View {
        Button {
            selection = v.id
            onPick?()
        } label: {
            HStack {
                Text(v.shortName)
                Spacer()
                if v.id == selection {
                    Image(systemName: "checkmark").foregroundStyle(.tint).font(.caption.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(v.id)
        .listRowBackground(v.id == selection ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// Compact control: shows the current voice, opens the scrollable list in a
/// popover with a clear chevron affordance.
struct VoiceMenuButton: View {
    let voices: [VoiceInfo]
    @Binding var selection: String
    @State private var open = false

    private var current: String {
        voices.first { $0.id == selection }?.display ?? selection
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(current).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VoicePickerList(voices: voices, selection: $selection) { open = false }
                .frame(width: 270, height: 340)
                .padding(8)
        }
    }
}
