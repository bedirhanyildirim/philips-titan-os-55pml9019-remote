import SwiftUI

/// Remote for the Orange TV box on HDMI 1 (local HTTP API, see OrangeClient).
struct OrangeTab: View {
    @EnvironmentObject var state: AppState
    private let orangeTint = Color(.sRGB, red: 1.0, green: 0.47, blue: 0.0)

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Orange TV")
            statusCard
            Card {
                VStack(spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(spacing: 10) {
                            RoundButton(icon: "line.3.horizontal") { state.orangeKey(.menu) }.help("Menu")
                            RoundButton(icon: "arrow.uturn.backward") { state.orangeKey(.back) }.help("Back")
                        }
                        Spacer()
                        dpad
                        Spacer()
                        VStack(spacing: 10) {
                            RoundButton(icon: "film") { state.orangeKey(.vod) }.help("VOD")
                            RoundButton(icon: "record.circle") { state.orangeKey(.record) }.help("Record")
                        }
                    }
                    HStack(spacing: 6) {
                        media("backward.fill", .rewind)
                        media("playpause.fill", .playPause)
                        media("forward.fill", .forward)
                    }
                }
            }
            HStack(spacing: 8) {
                wide("chevron.down", "Channel −") { state.orangeKey(.channelDown) }
                wide("chevron.up", "Channel +") { state.orangeKey(.channelUp) }
            }
            Card(title: "Channel number", icon: "number") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 0], id: \.self) { n in
                        Button { state.orangeKey(OrangeClient.Key.digit(n)) } label: {
                            Text("\(n)").font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await state.refreshOrange() }
    }

    private var statusCard: some View {
        let s = state.orangeStatus
        return Card {
            HStack(spacing: 12) {
                Image(systemName: "tv.and.mediabox").font(.system(size: 18))
                    .foregroundStyle(orangeTint)
                    .frame(width: 44, height: 44)
                    .background(orangeTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orange TV box").font(.system(size: 13, weight: .semibold))
                    Text(subtitle(s)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.orangeKey(.power) } label: {
                    Image(systemName: "power").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(s?.isOn == true ? orangeTint : .secondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.control, in: Circle())
                }.buttonStyle(.plain).disabled(!state.orangeReachable).help("Power box on/off")
            }
            HStack(spacing: 6) {
                PillButton(title: "Show on TV (HDMI 1)", tint: orangeTint.opacity(0.35)) { state.watchOrange() }
                Spacer()
                PillButton(title: "Refresh") { Task { await state.refreshOrange() } }
            }
            if !state.orangeReachable {
                Text("Box not on the network. If it's fully off, turn it on with the Orange remote (no Wake-on-LAN support).")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }

    private func subtitle(_ s: OrangeClient.Status?) -> String {
        guard state.orangeReachable, let s = s else { return "Unreachable" }
        guard s.isOn else { return "Standby" }
        switch s.context {
        case "LIVE": return "Live TV" + (s.channelId.map { " · channel #\($0)" } ?? "")
        case "HOMEPAGE": return "Main menu"
        case "": return "On"
        default: return "On · \(s.context.capitalized)"
        }
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(Theme.control)
            arrow("chevron.up", .up).offset(y: -46)
            arrow("chevron.down", .down).offset(y: 46)
            arrow("chevron.left", .left).offset(x: -46)
            arrow("chevron.right", .right).offset(x: 46)
            Button { state.orangeKey(.ok) } label: {
                Text("OK").font(.system(size: 13, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(orangeTint, in: Circle())
            }.buttonStyle(.plain)
        }
        .frame(width: 132, height: 132)
    }

    private func arrow(_ icon: String, _ k: OrangeClient.Key) -> some View {
        Button { state.orangeKey(k) } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func media(_ icon: String, _ k: OrangeClient.Key) -> some View {
        Button { state.orangeKey(k) } label: {
            Image(systemName: icon).font(.system(size: 11))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func wide(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
        }.buttonStyle(.plain)
    }
}
