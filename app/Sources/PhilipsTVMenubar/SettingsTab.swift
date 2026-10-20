import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Settings")
            Card(title: "Television", icon: "tv") {
                row("Model", state.modelName.isEmpty ? "—" : state.modelName)
                row("IP", state.client?.host ?? "—")
                row("Status", state.isOn ? "On" : "Off / standby")
            }
            Card(title: "Connections", icon: "link") {
                status("JointSpace (Ambilight, pointer)",
                       state.needsPairing ? .warn("Not paired") : !state.isOn ? .off
                       : state.jointSpaceDown ? .warn("Not responding — power-cycle the TV") : .ok)
                status("Titan OS (apps, remote keys)",
                       state.titan == nil ? .warn("Not paired") : state.isOn ? .ok : .off)
                status("DIAL (YouTube, Netflix, Prime)", state.isOn ? .ok : .off)
                HStack(spacing: 6) {
                    PillButton(title: "Re-pair remote") { state.needsPairing = true }
                    if state.titan == nil {
                        PillButton(title: "Pair Titan", tint: Theme.accent) { state.startTitanPairing() }
                    }
                }
                if state.titanAwaitingPIN {
                    HStack(spacing: 8) {
                        TextField("PIN on TV", text: $state.titanPIN)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { state.finishTitanPairing() }
                        PillButton(title: "Pair", tint: Theme.accent) { state.finishTitanPairing() }
                    }
                }
            }
            Card(title: "Orange TV box", icon: "tv.and.mediabox") {
                if let host = state.orangeHost {
                    row("Found at", host)
                    row("Status", !state.orangeReachable ? "Not answering" : (state.orangeStatus?.isOn == true ? "On" : "Standby"))
                } else {
                    Text(state.orangeScanning ? "Scanning the network…" : "No Orange box found on this network.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    PillButton(title: state.orangeScanning ? "Scanning…" : "Scan network") {
                        Task { await state.discoverOrange() }
                    }
                    if state.orangeHost != nil { PillButton(title: "Forget") { state.forgetOrange() } }
                }
            }
            Card(title: "App", icon: "app.badge") {
                HStack {
                    PillButton(title: "Refresh app list") { Task { await state.loadApps() } }
                    Spacer()
                    PillButton(title: "Quit", tint: Color.red.opacity(0.5)) { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 11, weight: .medium)).textSelection(.enabled)
        }
    }

    enum Health { case ok, off, warn(String) }

    private func status(_ title: String, _ h: Health) -> some View {
        let (icon, color, note): (String, Color, String?) = {
            switch h {
            case .ok: return ("checkmark.circle.fill", .green, nil)
            case .off: return ("moon.circle", .secondary, "TV off")
            case .warn(let m): return ("exclamationmark.triangle.fill", .orange, m)
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11))
                if let note = note { Text(note).font(.system(size: 9)).foregroundStyle(color) }
            }
            Spacer()
        }
    }
}
