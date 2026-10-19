import SwiftUI

/// The TV's installed apps (home-screen order) as a searchable grid; ★ marks favourites.
/// Launched over Titan OS MQTT (any app, incl. Disney+/HBO Max); without Titan
/// pairing, YouTube/Netflix/Prime fall back to DIAL. See TitanClient / launchDIAL.
struct AppsTab: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var filtered: [TitanApp] {
        query.isEmpty ? state.tvApps
            : state.tvApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search \(state.tvApps.count) apps", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))

            if state.titan == nil { TitanPairCard() }

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(filtered) { app in tile(app) }
            }
        }
    }

    private func tile(_ app: TitanApp) -> some View {
        let fav = state.favorites.contains(app.code)
        let current = state.lastLaunched?.code == app.code
        return Button { state.launch(app) } label: {
            VStack(spacing: 6) {
                AppIcon(app: app, size: 42)
                Text(app.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 88)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(current ? Theme.accent : Theme.cardStroke, lineWidth: current ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                Button { state.toggleFavorite(app) } label: {
                    Image(systemName: fav ? "star.fill" : "star")
                        .font(.system(size: 9))
                        .foregroundStyle(fav ? Theme.accent : Color.secondary)
                        .padding(7).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.buttonStyle(.plain)
    }
}

/// Titan OS (MQTT) pairing: needed to launch every app, not just the DIAL ones.
struct TitanPairCard: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Card(title: "Unlock all apps", icon: "link") {
            Text("Disney+, HBO Max etc. need Titan OS pairing. The TV will show a 4-digit PIN.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if state.titanAwaitingPIN {
                HStack(spacing: 8) {
                    TextField("PIN", text: $state.titanPIN)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { state.finishTitanPairing() }
                    PillButton(title: "Pair", tint: Theme.accent) { state.finishTitanPairing() }
                }
            } else {
                PillButton(title: "Request PIN", tint: Theme.accent) { state.startTitanPairing() }
            }
        }
    }
}
