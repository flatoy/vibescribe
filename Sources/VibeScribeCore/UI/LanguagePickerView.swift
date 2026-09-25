import Combine
import SwiftUI

struct LanguagePickerRow: Identifiable, Equatable {
    enum Section: String {
        case pinned = "Pinned"
        case recent = "Recent"
        case all = "All languages"
        case results = ""
    }

    let language: WhisperLanguage
    let section: Section
    /// 1...3 for pinned languages.
    let shortcut: Int?
    /// Matched character offsets in the English and native names.
    let nameMatches: Set<Int>
    let nativeMatches: Set<Int>

    var id: String { section.rawValue + language.id }
}

@MainActor
final class LanguagePickerModel: ObservableObject {
    enum Mode {
        case choose
        case pin
    }

    @Published var query: String = ""
    @Published private(set) var rows: [LanguagePickerRow] = []
    @Published var highlightIndex: Int = 0
    @Published private(set) var keyboardNavTick: Int = 0
    @Published private(set) var mode: Mode = .choose

    var onCommit: (WhisperLanguage) -> Void = { _ in }
    var onCancel: () -> Void = {}

    let preferences: Preferences
    private var cancellables = Set<AnyCancellable>()

    var results: [WhisperLanguage] { rows.map(\.language) }

    init(preferences: Preferences) {
        self.preferences = preferences
        Publishers.CombineLatest3($query, preferences.$pinnedLanguages, preferences.$recentLanguages)
            .map { query, pinned, recent in Self.compute(query: query, pinned: pinned, recent: recent) }
            .sink { [weak self] rows in
                guard let self else { return }
                self.rows = rows
                self.highlightIndex = min(self.highlightIndex, max(rows.count - 1, 0))
            }
            .store(in: &cancellables)
    }

    func reset(mode: Mode = .choose) {
        self.mode = mode
        query = ""
        highlightIndex = 0
    }

    func moveHighlight(by delta: Int) {
        guard !rows.isEmpty else { return }
        highlightIndex = max(0, min(rows.count - 1, highlightIndex + delta))
        keyboardNavTick &+= 1
    }

    func setHoverHighlight(at index: Int) {
        guard rows.indices.contains(index) else { return }
        highlightIndex = index
    }

    func commit(at index: Int? = nil) {
        let target = index ?? highlightIndex
        guard rows.indices.contains(target) else { return }
        onCommit(rows[target].language)
    }

    /// ⌘1...⌘3 choose a pinned language.
    func commitPinned(_ number: Int) {
        let pinned = preferences.pinnedLanguages
        guard pinned.indices.contains(number - 1) else {
            NSSound.beep()
            return
        }
        onCommit(pinned[number - 1])
    }

    /// ⌘P pins or unpins the highlighted language.
    func togglePinHighlighted() {
        guard rows.indices.contains(highlightIndex) else { return }
        if !preferences.togglePin(rows[highlightIndex].language) {
            NSSound.beep()
        }
    }

    func cancel() {
        onCancel()
    }

    static func compute(query: String, pinned: [WhisperLanguage], recent: [WhisperLanguage]) -> [LanguagePickerRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return search(trimmed) }

        var rows = pinned.enumerated().map { index, language in
            LanguagePickerRow(language: language, section: .pinned, shortcut: index + 1, nameMatches: [], nativeMatches: [])
        }
        let recentOnly = recent.filter { !pinned.contains($0) }
        rows += recentOnly.map {
            LanguagePickerRow(language: $0, section: .recent, shortcut: nil, nameMatches: [], nativeMatches: [])
        }
        let shown = Set(pinned + recentOnly)
        rows += WhisperLanguage.allCases.filter { !shown.contains($0) }.map {
            LanguagePickerRow(language: $0, section: .all, shortcut: nil, nameMatches: [], nativeMatches: [])
        }
        return rows
    }

    private static func search(_ query: String) -> [LanguagePickerRow] {
        let scored: [(LanguagePickerRow, Int)] = WhisperLanguage.allCases.compactMap { language in
            let name = fuzzyMatch(query: query, in: language.displayName)
            let native = language.nativeName.flatMap { fuzzyMatch(query: query, in: $0) }
            let code = fuzzyMatch(query: query, in: language.rawValue)
            let best = [name?.score, native.map { $0.score + 50_000 }, code.map { $0.score + 100_000 }]
                .compactMap { $0 }
                .min()
            guard let best else { return nil }
            let row = LanguagePickerRow(
                language: language,
                section: .results,
                shortcut: nil,
                nameMatches: name?.indices ?? [],
                nativeMatches: native?.indices ?? []
            )
            return (row, best)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Letters must appear in order. Earlier and tighter matches score lower (better).
    static func fuzzyMatch(query: String, in text: String) -> (score: Int, indices: Set<Int>)? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return (0, []) }
        var qi = 0
        var indices = Set<Int>()
        var firstMatch: Int?
        var lastMatch = -1
        var gaps = 0
        for (i, c) in t.enumerated() {
            guard qi < q.count else { break }
            if c == q[qi] {
                if firstMatch == nil { firstMatch = i }
                if lastMatch >= 0 { gaps += (i - lastMatch - 1) }
                lastMatch = i
                indices.insert(i)
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        return ((firstMatch ?? 0) * 1000 + gaps * 10 + t.count, indices)
    }
}

struct LanguagePickerView: View {
    @ObservedObject var model: LanguagePickerModel
    @ObservedObject private var preferences: Preferences
    @FocusState private var focused: Bool

    static let size = CGSize(width: 380, height: 372)

    init(model: LanguagePickerModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if model.rows.isEmpty {
                emptyState
            } else {
                resultsList
            }
            keyHints
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(Theme.glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.glassBorder))
        .environment(\.colorScheme, .dark)
        .task { focused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.mode == .pin ? "pin" : "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(model.mode == .pin ? "Pin a language" : "Search languages")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .allowsHitTesting(false)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .tint(.white.opacity(0.7))
                    .focused($focused)
                    .onChange(of: model.query) { model.highlightIndex = 0 }
                    .accessibilityLabel("Search languages")
            }
            Text(model.query.isEmpty ? "now: \(preferences.language.badge.lowercased())" : resultCount)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultCount: String {
        model.rows.count == 1 ? "1 result" : "\(model.rows.count) results"
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if row.section != .results, index == 0 || model.rows[index - 1].section != row.section {
                            Text(row.section.rawValue.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.horizontal, 20)
                                .padding(.top, 9)
                                .padding(.bottom, 4)
                        }
                        LanguageRow(
                            row: row,
                            isHighlighted: index == model.highlightIndex,
                            isCurrent: row.language == preferences.language,
                            isPinned: preferences.pinnedLanguages.contains(row.language),
                            mode: model.mode
                        )
                        .id(row.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.commit(at: index) }
                        .onHover { hovering in
                            if hovering { model.setHoverHighlight(at: index) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.keyboardNavTick) {
                guard model.rows.indices.contains(model.highlightIndex) else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(model.rows[model.highlightIndex].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No language called “\(model.query.trimmed)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("The speech model supports 100 languages. Choose Automatic to let it detect the language.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Use Automatic") { model.onCommit(.automatic) }
                .buttonStyle(.spectrum)
                .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyHints: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "move")
            hint(["↩"], model.mode == .pin ? "pin" : "choose")
            if model.mode == .choose { hint(["⌘P"], "pin") }
            Spacer()
            hint(["esc"], model.query.isEmpty ? "close" : "clear search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
        }
    }
}

private struct LanguageRow: View {
    let row: LanguagePickerRow
    let isHighlighted: Bool
    let isCurrent: Bool
    let isPinned: Bool
    let mode: LanguagePickerModel.Mode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .pin ? "pin.fill" : "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.spectrum[2])
                .frame(width: 12)
                .opacity(mode == .pin ? (isPinned ? 1 : 0) : (isCurrent ? 1 : 0))
            highlighted(row.language.displayName, row.nameMatches)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            if let native = row.language.nativeName {
                highlighted(native, row.nativeMatches)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 8)
            if let shortcut = row.shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 17)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            } else {
                Text(row.language.whisperCode ?? "auto")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.white.opacity(0.14) : Color.clear)
        )
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func highlighted(_ text: String, _ matches: Set<Int>) -> Text {
        guard !matches.isEmpty else { return Text(text) }
        var attributed = AttributedString()
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matches.contains(index) {
                piece.foregroundColor = Theme.spectrum[3]
                piece.font = .system(size: 13, weight: .semibold)
            }
            attributed += piece
        }
        return Text(attributed)
    }
}
