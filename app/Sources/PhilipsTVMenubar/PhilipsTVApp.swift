import SwiftUI

@main
struct PhilipsTVApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .frame(width: 340)
        } label: {
            Image(systemName: state.isOn ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if state.needsPairing {
                PairingView()
            } else {
                MainView()
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case home, remote, apps, sources, orange, ambilight, settings
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "tv"
        case .remote: return "circle.grid.cross"
        case .apps: return "square.grid.2x2"
        case .sources: return "cable.connector"
        case .orange: return "tv.and.mediabox"
        case .ambilight: return "sparkles"
        case .settings: return "slider.horizontal.3"
        }
    }
    var title: String {
        switch self {
        case .home: return "Home"
        case .remote: return "Remote"
        case .apps: return "Apps"
        case .sources: return "Sources"
        case .orange: return "Orange TV"
        case .ambilight: return "Ambilight"
        case .settings: return "Settings"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("tab") private var tab: Tab = .home

    var body: some View {
        VStack(spacing: 12) {
            header
            tabBar
            ScrollView(showsIndicators: false) {
                Group {
                    switch tab {
                    case .home: HomeTab(tab: $tab)
                    case .remote: RemoteTab()
                    case .apps: AppsTab()
                    case .sources: SourcesTab()
                    case .orange: OrangeTab()
                    case .ambilight: AmbilightView()
                    case .settings: SettingsTab()
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 470)
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("PHILIPS").font(.system(size: 10, weight: .heavy)).tracking(1.5)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Philips TV").font(.system(size: 15, weight: .bold))
                Text("Titan OS").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.togglePower()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(state.isOn ? Theme.accent : .secondary)
                    .frame(width: 30, height: 30)
            }.buttonStyle(.plain)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tab == t ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(tab == t ? Theme.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(state.statusMessage.isEmpty && state.isOn ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(state.statusMessage.isEmpty ? (state.isOn ? "Connected" : "TV off") : state.statusMessage)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(state.modelName).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            Button { Task { await state.refresh(); await state.loadApps() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
        }
    }
}

// MARK: - Pairing (JointSpace)

struct PairingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair your Philips TV").font(.headline)
            if !state.pairingAwaitingPIN {
                Text("TV IP address").font(.caption).foregroundStyle(.secondary)
                TextField("192.168.0.45", text: $state.pairingHost)
                    .textFieldStyle(.roundedBorder)
                Button("Request PIN") { state.startPairing() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Enter the PIN shown on the TV").font(.caption).foregroundStyle(.secondary)
                TextField("1234", text: $state.pairingPIN)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.finishPairing() }
                Button("Pair") { state.finishPairing() }
                    .buttonStyle(.borderedProminent)
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
    }
}
