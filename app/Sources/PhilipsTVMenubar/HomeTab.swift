import SwiftUI

struct HomeTab: View {
    @EnvironmentObject var state: AppState
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            TVPreview()
            nowOn
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
            Text(state.isOn ? (state.lastLaunched?.name ?? "Titan OS") : "Standby")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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

/// Stylised TV with an Ambilight halo in the last chosen colour.
struct TVPreview: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if state.isOn {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(state.glow.opacity(0.55))
                        .blur(radius: 18)
                        .padding(.horizontal, 6)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: state.isOn
                                         ? [Color(white: 0.16), Color(white: 0.05)]
                                         : [Color(white: 0.07), Color(white: 0.03)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1.5))
                    .padding(.horizontal, 22)
                VStack(spacing: 4) {
                    if let app = state.lastLaunched, state.isOn {
                        AppIcon(app: app, size: 30)
                    } else {
                        Text("PHILIPS").font(.system(size: 11, weight: .heavy)).tracking(2)
                            .foregroundStyle(state.isOn ? Theme.accent : .secondary)
                    }
                    Text(state.isOn ? "TV on" : "TV off")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.isOn ? .white : .secondary)
                }
            }
            .frame(height: 118)
            HStack {
                Rectangle().frame(width: 18, height: 2).rotationEffect(.degrees(25))
                Spacer()
                Rectangle().frame(width: 18, height: 2).rotationEffect(.degrees(-25))
            }
            .foregroundStyle(Color.white.opacity(0.2))
            .padding(.horizontal, 44)
        }
        .padding(.top, 4)
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
