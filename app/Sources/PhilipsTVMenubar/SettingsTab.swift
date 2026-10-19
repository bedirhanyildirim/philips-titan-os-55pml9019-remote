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
                status("JointSpace (remote, Ambilight)", ok: !state.needsPairing)
                status("Titan OS (apps)", ok: state.titan != nil)
                status("DIAL (YouTube, Netflix, Prime)", ok: true)
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

    private func status(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(ok ? .green : .orange)
            Text(title).font(.system(size: 11))
            Spacer()
        }
    }
}
