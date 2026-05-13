import Combine
import SwiftUI

@MainActor
final class LanguagePickerModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [DeepgramLanguage] = DeepgramLanguage.allCases
    @Published var highlightIndex: Int = 0

    var onCommit: (DeepgramLanguage) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init() {
        $query
            .map { Self.compute(for: $0) }
            .assign(to: &$results)
    }

    func reset() {
        query = ""
        highlightIndex = 0
    }

    func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlightIndex = max(0, min(results.count - 1, highlightIndex + delta))
    }

    func commit(at index: Int? = nil) {
        let target = index ?? highlightIndex
        guard results.indices.contains(target) else { return }
        onCommit(results[target])
    }

    func cancel() {
        onCancel()
    }

    private static func compute(for query: String) -> [DeepgramLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return DeepgramLanguage.allCases
        }
        let scored: [(DeepgramLanguage, Int)] = DeepgramLanguage.allCases.compactMap { lang in
            guard let score = fuzzyScore(query: trimmed, in: lang.displayName) else { return nil }
            return (lang, score)
        }
        return scored.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    private static func fuzzyScore(query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0
        var firstMatch: Int?
        var lastMatch = -1
        var gaps = 0
        for (i, c) in t.enumerated() {
            guard qi < q.count else { break }
            if c == q[qi] {
                if firstMatch == nil { firstMatch = i }
                if lastMatch >= 0 { gaps += (i - lastMatch - 1) }
                lastMatch = i
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        return (firstMatch ?? 0) * 1000 + gaps * 10 + t.count
    }
}

struct LanguagePickerView: View {
    @ObservedObject var model: LanguagePickerModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar

            if !model.results.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                resultsList
            }
        }
        .background(cardBackground)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        .task {
            focused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Search languages")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .allowsHitTesting(false)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .tint(Color.white.opacity(0.7))
                    .focused($focused)
                    .onChange(of: model.query) { _ in
                        model.highlightIndex = 0
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, lang in
                        LanguageRow(
                            language: lang,
                            isHighlighted: index == model.highlightIndex
                        )
                        .id(lang.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.commit(at: index)
                        }
                        .onHover { isHovering in
                            if isHovering {
                                model.highlightIndex = index
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            .onChange(of: model.highlightIndex) { newIndex in
                guard model.results.indices.contains(newIndex) else { return }
                let lang = model.results[newIndex]
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(lang.id, anchor: .center)
                }
            }
        }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.92), Color.black.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(0.2)
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

private struct LanguageRow: View {
    let language: DeepgramLanguage
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(language.displayName)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(language.deepgramCode)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
                .monospaced()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.white.opacity(0.14) : Color.clear)
                .padding(.horizontal, 6)
        )
    }
}
