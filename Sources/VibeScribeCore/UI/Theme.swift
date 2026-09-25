import SwiftUI

/// Spectrum design tokens: dark glass, with the icon's seven colours as the only colour.
enum Theme {
    /// The icon's bars, left to right.
    static let spectrum: [Color] = [
        Color(hex: 0x6EC6EA), Color(hex: 0x7BA3F0), Color(hex: 0x9A8AE6), Color(hex: 0xC68AEE),
        Color(hex: 0xD884C4), Color(hex: 0xEE9A8F), Color(hex: 0xEDBB7A),
    ]

    static let windowTop = Color(hex: 0x232327)
    static let windowBottom = Color(hex: 0x1E1E21)
    static let sidebar = Color.black.opacity(0.2)
    static let footer = Color.black.opacity(0.14)
    static let panel = Color(hex: 0x27272B)
    static let iconWell = Color(hex: 0x35353B)
    static let field = Color(hex: 0x141416)
    static let control = Color(hex: 0x3A3A40)
    static let segmentTrack = Color(hex: 0x2F2F34)
    static let segmentThumb = Color(hex: 0x55555C)
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    static let text = Color(hex: 0xEDEDF0)
    static let secondary = Color(hex: 0x9A9AA3)
    static let tertiary = Color(hex: 0x6B6B74)

    static let accent = Color(hex: 0x9A8AE6)
    static let accentTop = Color(hex: 0xA797F0)
    static let accentBottom = Color(hex: 0x8A78DD)
    static let ok = Color(hex: 0x6EC6EA)
    static let warn = Color(hex: 0xEDBB7A)
    static let bad = Color(hex: 0xEE8A7F)

    static let glassTop = Color.black.opacity(0.92)
    static let glassBottom = Color.black.opacity(0.72)
    static let glassBorder = Color.white.opacity(0.12)

    /// Sidebar icon tiles, in page order.
    static let pageColors: [Color] = [
        Color(hex: 0x5E5E66), Color(hex: 0x5B7FD6), Color(hex: 0x8A73D8),
        Color(hex: 0xC06FA6), Color(hex: 0xD98972), Color(hex: 0x4A4A50),
    ]

    static var spectrumGradient: LinearGradient {
        LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
    }

    static var windowBackground: LinearGradient {
        LinearGradient(colors: [windowTop, windowBottom], startPoint: .top, endPoint: .bottom)
    }

    static var glassBackground: LinearGradient {
        LinearGradient(colors: [glassTop, glassBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var primaryFill: LinearGradient {
        LinearGradient(colors: [accentTop, accentBottom], startPoint: .top, endPoint: .bottom)
    }

    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    /// The dark window surface shared by the settings and setup windows.
    func spectrumWindowBackground() -> some View {
        background(Theme.windowBackground.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, .dark)
            .tint(Theme.accent)
    }
}
