import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var pulse = false
    @State private var appear = false
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 10) {
            PulseOrb(pulse: pulse)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(cardBackground)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        .scaleEffect(appear ? 1.0 : 0.7)
        .opacity(appear ? 1.0 : 0.0)
        .blur(radius: appear ? 0 : 6)
        .offset(y: appear ? 0 : -20)
        .overlay(shimmerOverlay)
        .mask(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white)
        )
        .id(appState.overlayPulseID)
        .onAppear {
            pulse = appState.isRecording
            shimmer = appState.isRecording
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72, blendDuration: 0.2)) {
                appear = appState.isRecording
            }
        }
        .onDisappear {
            appear = false
            pulse = false
            shimmer = false
        }
        .onChange(of: appState.isRecording) { isRecording in
            pulse = isRecording
            shimmer = isRecording
            if isRecording {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72, blendDuration: 0.2)) {
                    appear = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appear = false
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

    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.0),
                Color.white.opacity(0.12),
                Color.white.opacity(0.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: 120, height: 120)
        .rotationEffect(.degrees(25))
        .offset(x: shimmer ? 120 : -140, y: shimmer ? -12 : 12)
        .animation(
            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: shimmer
        )
        .blendMode(.screen)
    }
}

private struct PulseOrb: View {
    let pulse: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.25))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.15 : 0.8)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.red, Color.red.opacity(0.7)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 12
                    )
                )
                .frame(width: 9, height: 9)
                .shadow(color: Color.red.opacity(0.6), radius: 8, x: 0, y: 0)
        }
    }
}
