import SwiftUI

/// A row of the TV's Sources drawer. Drawer order on this TV, top→bottom:
/// Satellite, Antenna, Streaming, Screen mirroring, USB, Network, HDMI 1–4.
/// The list doesn't wrap, so a row is reached from an end: `.bottom(up: n)` = n rows
/// above HDMI 4, `.top(down: n)` = n rows below Satellite. Screen mirroring is never a target.
struct TVSource: Identifiable, Hashable {
    enum Path: Hashable { case home, top(down: Int), bottom(up: Int) }
    let id: String
    let name: String
    let detail: String
    let icon: String
    let path: Path

    static let hdmi: [TVSource] = [
        TVSource(id: "hdmi1", name: "HDMI 1", detail: "HDMI 1", icon: "rectangle.connected.to.line.below", path: .bottom(up: 3)),
        TVSource(id: "hdmi2", name: "Home Theatre", detail: "HDMI 2 · Soundbar (eARC)", icon: "hifispeaker.2", path: .bottom(up: 2)),
        TVSource(id: "hdmi3", name: "Computer", detail: "HDMI 3", icon: "desktopcomputer", path: .bottom(up: 1)),
        TVSource(id: "hdmi4", name: "HDMI 4", detail: "HDMI 4", icon: "cable.connector.horizontal", path: .bottom(up: 0)),
    ]
    static let tv: [TVSource] = [
        TVSource(id: "streaming", name: "Streaming", detail: "Home screen and apps", icon: "play.tv", path: .home),
        TVSource(id: "satellite", name: "Satellite", detail: "Satellite", icon: "antenna.radiowaves.left.and.right", path: .top(down: 0)),
        TVSource(id: "antenna", name: "Antenna", detail: "Antenna", icon: "dot.radiowaves.up.forward", path: .top(down: 1)),
    ]
    static let other: [TVSource] = [
        TVSource(id: "usb", name: "USB", detail: "USB drive", icon: "externaldrive", path: .bottom(up: 5)),
        TVSource(id: "network", name: "Network", detail: "Network media (DLNA)", icon: "network", path: .bottom(up: 4)),
    ]
}

struct SourcesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Sources")
            if state.titan == nil { TitanPairCard() }
            group("HDMI", icon: "cable.connector", TVSource.hdmi.map { s in
                // HDMI 1 is labelled after the Orange box when one was found
                guard s.id == "hdmi1", state.orangeHost != nil else { return s }
                return TVSource(id: s.id, name: "Orange TV", detail: "HDMI 1 · TV box", icon: "tv.and.mediabox", path: s.path)
            })
            group("TV", icon: "tv", TVSource.tv)
            group("Other", icon: "square.stack", TVSource.other)
            Text("Sources are picked through the TV's Sources menu (takes a few seconds). Screen mirroring is left out on purpose: it drops the TV off the network.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group(_ title: String, icon: String, _ sources: [TVSource]) -> some View {
        Card(title: title, icon: icon) {
            VStack(spacing: 4) {
                ForEach(sources) { s in row(s) }
            }
        }
    }

    private func row(_ s: TVSource) -> some View {
        let on = state.currentSource == s
        return Button { state.select(s) } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon).font(.system(size: 13))
                    .foregroundStyle(on ? Theme.accent : .white)
                    .frame(width: 30, height: 30)
                    .background(on ? Theme.accent.opacity(0.2) : Theme.control, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 12, weight: .semibold))
                    Text(s.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if on {
                    Text("SELECTED").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Theme.accent)
                }
            }
            .padding(4)
            .background(on ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
