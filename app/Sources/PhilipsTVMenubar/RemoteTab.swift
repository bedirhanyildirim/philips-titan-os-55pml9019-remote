import SwiftUI

struct RemoteTab: View {
    @EnvironmentObject var state: AppState
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Remote")
            Card {
                VStack(spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(spacing: 10) {
                            RoundButton(icon: "house.fill") { key("Home") }.help("Home")
                            RoundButton(icon: "arrow.uturn.backward") { key("Back") }.help("Back")
                        }
                        Spacer()
                        dpad
                        Spacer()
                        VStack(spacing: 10) {
                            RoundButton(icon: "line.3.horizontal") { key("Options") }.help("Menu")
                            RoundButton(icon: "info") { key("Info") }.help("Info")
                        }
                    }
                    HStack(spacing: 6) {
                        media("backward.end.fill", "Previous")
                        media("backward.fill", "Rewind")
                        media("playpause.fill", "PlayPause")
                        media("forward.fill", "FastForward")
                        media("forward.end.fill", "Next")
                    }
                }
            }
            HStack(spacing: 8) {
                channelButton("chevron.down", "Channel −", "ChannelStepDown")
                channelButton("chevron.up", "Channel +", "ChannelStepUp")
            }
            VolumeCard()
            Card(title: "Pointer", icon: "cursorarrow",
                 trailing: AnyView(Text("drag · tap = OK").font(.system(size: 9)).foregroundStyle(.secondary))) {
                TrackpadView()
            }
            Card(title: "Keyboard", icon: "keyboard") {
                HStack(spacing: 8) {
                    TextField("Type on TV…", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    RoundButton(icon: "paperplane.fill", size: 28, tint: Theme.accent.opacity(0.8), action: send)
                }
            }
        }
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(Theme.control)
            Circle().stroke(Color.white.opacity(0.06))
            arrow("chevron.up", "CursorUp").offset(y: -46)
            arrow("chevron.down", "CursorDown").offset(y: 46)
            arrow("chevron.left", "CursorLeft").offset(x: -46)
            arrow("chevron.right", "CursorRight").offset(x: 46)
            Button { key("Confirm") } label: {
                Text("OK").font(.system(size: 13, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(Theme.accent, in: Circle())
            }.buttonStyle(.plain)
        }
        .frame(width: 132, height: 132)
    }

    private func arrow(_ icon: String, _ k: String) -> some View {
        Button { key(k) } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func media(_ icon: String, _ k: String) -> some View {
        Button { key(k) } label: {
            Image(systemName: icon).font(.system(size: 11))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func channelButton(_ icon: String, _ title: String, _ k: String) -> some View {
        Button { key(k) } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
        }.buttonStyle(.plain)
    }

    private func send() {
        let t = typed; typed = ""
        guard !t.isEmpty else { return }
        state.type(t)
    }

    private func key(_ k: String) { state.key(k) }
}

// MARK: - Trackpad (pointer control for the TV browser)

struct TrackpadView: View {
    @EnvironmentObject var state: AppState
    @State private var last: CGPoint?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.accent.opacity(0.08))
            .frame(height: 90)
            .overlay(Image(systemName: "hand.point.up.left.fill").foregroundStyle(Theme.accent.opacity(0.4)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if let last = last {
                            let dx = Int((v.location.x - last.x) * 2.2)
                            let dy = Int((v.location.y - last.y) * 2.2)
                            if abs(dx) > 1 || abs(dy) > 1 {
                                state.run { try await $0.pointerMove(dx, dy) }
                                self.last = v.location
                            }
                        } else { last = v.location }
                    }
                    .onEnded { v in
                        if let l = last, abs(v.location.x - l.x) < 3, abs(v.location.y - l.y) < 3 {
                            state.key("Confirm")
                        }
                        last = nil
                    }
            )
    }
}
