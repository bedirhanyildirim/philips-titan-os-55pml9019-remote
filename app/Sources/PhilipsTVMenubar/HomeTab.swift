import SwiftUI

struct HomeTab: View {
    @EnvironmentObject var state: AppState
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            TVPreview()
            nowOn
            if state.isOn, let np = state.ytNow { YouTubeCard(np: np) }
            VolumeCard()
            favoritesCard
            sourceCard
        }
    }

    private var nowOn: some View {
        HStack(spacing: 6) {
            Circle().fill(state.isOn ? Theme.accent : Color.gray).frame(width: 5, height: 5)
            Text("NOW ON").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
            Spacer()
            if state.isOn, let n = state.nowOn {
                Text([n.title, n.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(state.isOn ? "…" : "Standby").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var favoritesCard: some View {
        Card(title: "Favourites", icon: "star",
             trailing: AnyView(PillButton(title: "All") { tab = .apps })) {
            // "Home" is always first; then every favourite, 4 per row.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                Button {
                    state.key("Home")
                    state.lastLaunched = nil
                    state.nowOn = AppState.NowOn(title: "Home screen", icon: "house.fill")
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "house.fill").font(.system(size: 17))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                        Text("Home").font(.system(size: 10)).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
                ForEach(state.favoriteApps) { app in
                    Button { state.launch(app) } label: {
                        VStack(spacing: 5) {
                            AppIcon(app: app, size: 40)
                            Text(app.name).font(.system(size: 10)).lineLimit(1)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }
            if state.favoriteApps.isEmpty {
                Text("Star ★ apps in the Apps tab to add favourites")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var sourceCard: some View {
        Card(title: "Sources", icon: "cable.connector",
             trailing: AnyView(PillButton(title: "All") { tab = .sources })) {
            VStack(spacing: 6) {
                SourceRow(icon: "play.tv", title: "Streaming",
                          subtitle: "Home screen and apps") {
                    state.key("Home")
                }
                SourceRow(icon: "antenna.radiowaves.left.and.right", title: "Watch TV",
                          subtitle: "Last watched channel") {
                    state.key("WatchTV")
                }
                // Orange box on HDMI 1 — only when it answers on the network
                if state.orangeReachable, let s = state.orangeStatus {
                    SourceRow(icon: "tv.and.mediabox", title: "Orange TV",
                              subtitle: s.isOn ? "HDMI 1 · box on" : "HDMI 1 · box in standby") {
                        state.watchOrange()
                    }
                }
            }
        }
        .task { await state.refreshOrange() }
    }
}

/// The living-room setup as it really is: wall-mounted TV with Ambilight on the left, top
/// and right edges only, the soundbar on the TV unit below, the Orange box in its cubby.
struct TVPreview: View {
    @EnvironmentObject var state: AppState

    private let wall = Color(.sRGB, red: 0.20, green: 0.07, blue: 0.08)
    private let wood = Color(.sRGB, red: 0.80, green: 0.68, blue: 0.52)

    var body: some View {
        let on = state.isOn
        let glow = on && state.glow != .clear ? state.glow : Color.clear
        let orangeOn = state.orangeReachable && state.orangeStatus?.isOn == true

        GeometryReader { g in
            let w = g.size.width
            let tvW = w * 0.62, tvH = tvW * 9 / 16
            let tvX = (w - tvW) / 2, tvY: CGFloat = 16
            let unitY = tvY + tvH + 30

            ZStack(alignment: .topLeading) {
                wall
                // Ambilight: left, top, right — no bottom LEDs
                Group {
                    Rectangle().fill(glow).frame(width: 14, height: tvH * 0.95)
                        .offset(x: tvX - 6, y: tvY + tvH * 0.03)
                    Rectangle().fill(glow).frame(width: 14, height: tvH * 0.95)
                        .offset(x: tvX + tvW - 8, y: tvY + tvH * 0.03)
                    Rectangle().fill(glow).frame(width: tvW * 0.95, height: 12)
                        .offset(x: tvX + tvW * 0.025, y: tvY - 5)
                }
                .blur(radius: 14)
                .opacity(0.9)

                // TV
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: on ? [Color(white: 0.18), Color(white: 0.06)]
                                                    : [Color(white: 0.06), Color(white: 0.02)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.25), lineWidth: 1.5))
                    .overlay(screen)
                    .frame(width: tvW, height: tvH)
                    .offset(x: tvX, y: tvY)

                // TV unit (light wood) with the soundbar on top and the Orange box in the middle cubby
                Rectangle().fill(wood.opacity(0.9))
                    .frame(width: w, height: 5).offset(y: unitY)
                Rectangle().fill(wood.opacity(0.55))
                    .frame(width: w, height: g.size.height - unitY - 5).offset(y: unitY + 5)
                Rectangle().fill(Color.black.opacity(0.35))
                    .frame(width: w * 0.3, height: g.size.height - unitY - 9)
                    .offset(x: w * 0.35, y: unitY + 7)
                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.1))
                    .frame(width: 28, height: 8)
                    .overlay(alignment: .leading) {
                        Circle().fill(orangeOn ? Color.orange : Color(white: 0.25))
                            .frame(width: 3, height: 3).padding(.leading, 3)
                    }
                    .offset(x: w / 2 - 6, y: g.size.height - 12)
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12))
                    .frame(width: tvW * 0.75, height: 7)
                    .overlay(Circle().fill(on ? Color.white.opacity(0.8) : Color(white: 0.25)).frame(width: 2.5, height: 2.5))
                    .offset(x: (w - tvW * 0.75) / 2, y: unitY - 7)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardStroke))
    }

    private var screen: some View {
        VStack(spacing: 4) {
            if state.isOn, let app = state.nowOn?.app {
                AppIcon(app: app, size: 26)
            } else if state.isOn, let n = state.nowOn {
                Image(systemName: n.icon).font(.system(size: 17)).foregroundStyle(Theme.accent)
            } else {
                Text("PHILIPS").font(.system(size: 9, weight: .heavy)).tracking(2)
                    .foregroundStyle(state.isOn ? Theme.accent : Color(white: 0.3))
            }
            Text(state.isOn ? (state.nowOn?.title ?? "TV on") : "TV off")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.isOn ? .white : Color(white: 0.4))
                .lineLimit(1).padding(.horizontal, 6)
        }
    }
}

/// Soundbar volume (HDMI-CEC): no readable level, just step/mute keys.
struct VolumeCard: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Card(title: "Volume", icon: "speaker.wave.2.fill",
             trailing: AnyView(Text("Soundbar · HDMI-CEC").font(.system(size: 9)).foregroundStyle(.secondary))) {
            HStack(spacing: 8) {
                RoundButton(icon: "speaker.slash.fill") { key("Mute") }
                Spacer()
                RoundButton(icon: "minus") { key("VolumeDown") }
                RoundButton(icon: "plus") { key("VolumeUp") }
            }
        }
    }
    private func key(_ k: String) { state.key(k) }
}

struct SourceRow: View {
    let icon: String, title: String, subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// App icon from the Titan catalog, with a lettered fallback.
struct AppIcon: View {
    let app: TitanApp
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let url = app.icon {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { fallback }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
    private var fallback: some View {
        ZStack {
            Theme.control
            Text(String(app.name.prefix(1))).font(.system(size: size * 0.45, weight: .bold))
        }
    }
}
