import SwiftUI

/// Now playing in the TV's YouTube app, with transport controls (Lounge API).
struct YouTubeCard: View {
    @EnvironmentObject var state: AppState
    let np: YouTubeLounge.NowPlaying

    var body: some View {
        Card(title: "YouTube", icon: "play.rectangle.fill",
             trailing: AnyView(Text(stateText).font(.system(size: 9)).foregroundStyle(.secondary))) {
            HStack(spacing: 10) {
                AsyncImage(url: np.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Theme.control }
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title ?? np.videoId).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    if let ch = np.channel {
                        Text(ch).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let pos = np.position
                VStack(spacing: 3) {
                    ProgressView(value: np.duration > 0 ? min(pos / np.duration, 1) : 0)
                        .tint(.red)
                    HStack {
                        Text(Self.time(pos)); Spacer(); Text(Self.time(np.duration))
                    }
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                control("backward.end.fill", enabled: np.hasPrevious) { state.yt("previous") { try await $0.previous() } }
                control("gobackward.10") { state.yt("seek") { try await $0.seek(by: -10) } }
                control(np.isPlaying ? "pause.fill" : "play.fill", tint: Color.red.opacity(0.75)) {
                    state.yt("play/pause") { try await $0.togglePlayPause() }
                }
                control("goforward.10") { state.yt("seek") { try await $0.seek(by: 10) } }
                control("forward.end.fill", enabled: np.hasNext) { state.yt("next") { try await $0.next() } }
            }
        }
    }

    private var stateText: String {
        switch np.state {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .buffering: return "Buffering…"
        case .ad: return "Ad"
        case .ended: return "Ended"
        default: return ""
        }
    }

    private func control(_ icon: String, enabled: Bool = true, tint: Color = Theme.control,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
