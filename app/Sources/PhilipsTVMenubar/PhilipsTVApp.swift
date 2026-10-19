import SwiftUI

@main
struct PhilipsTVApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .frame(width: 300)
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
            Color.black.opacity(0.92).ignoresSafeArea()
            if state.needsPairing {
                PairingView()
            } else {
                ControlView()
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Philips TV'yi Eşleştir").font(.headline)
            if !state.pairingAwaitingPIN {
                Text("TV'nin IP adresi").font(.caption).foregroundStyle(.secondary)
                TextField("192.168.0.45", text: $state.pairingHost)
                    .textFieldStyle(.roundedBorder)
                Button("PIN İste") { state.startPairing() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("TV ekranındaki PIN'i gir").font(.caption).foregroundStyle(.secondary)
                TextField("1234", text: $state.pairingPIN)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.finishPairing() }
                Button("Eşleştir") { state.finishPairing() }
                    .buttonStyle(.borderedProminent)
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
    }
}

// MARK: - Main controls

struct ControlView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            header
            volumeRow
            dpad
            mediaRow
            ambilightRow
            sourceRow
            keyboardRow
            TrackpadView()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.modelName.isEmpty ? "Philips TV" : state.modelName)
                    .font(.headline)
                Text(state.isOn ? "🟢 Açık" : "⚪️ Kapalı")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { state.run("güç") { try await $0.sendKey("Standby") } } label: {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(state.isOn ? Color.blue : Color.gray.opacity(0.4), in: Circle())
            }.buttonStyle(.plain)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            iconButton("speaker.wave.1.fill") { state.run { try await $0.sendKey("VolumeDown") } }
            iconButton("speaker.slash.fill") { state.run { try await $0.sendKey("Mute") } }
            iconButton("speaker.wave.3.fill") { state.run { try await $0.sendKey("VolumeUp") } }
        }
    }

    private var dpad: some View {
        VStack(spacing: 8) {
            iconButton("chevron.up") { key("CursorUp") }
            HStack(spacing: 8) {
                iconButton("chevron.left") { key("CursorLeft") }
                Button { key("Confirm") } label: {
                    Text("OK").fontWeight(.bold)
                        .frame(width: 56, height: 56)
                        .background(Color.blue.opacity(0.8), in: Circle())
                }.buttonStyle(.plain)
                iconButton("chevron.right") { key("CursorRight") }
            }
            iconButton("chevron.down") { key("CursorDown") }
            HStack(spacing: 8) {
                smallButton("Geri", "arrow.uturn.backward") { key("Back") }
                smallButton("Ana", "house.fill") { key("Home") }
                smallButton("Menü", "line.3.horizontal") { key("Options") }
            }
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            iconButton("backward.end.fill") { key("Previous") }
            iconButton("playpause.fill") { key("PlayPause") }
            iconButton("stop.fill") { key("Stop") }
            iconButton("forward.end.fill") { key("Next") }
        }
    }

    private var ambilightRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🎨 Ambilight").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                tag("Video") { state.run { try await $0.setAmbilight(style: "FOLLOW_VIDEO", menu: "NATURAL") } }
                tag("Ses") { state.run { try await $0.setAmbilight(style: "FOLLOW_AUDIO", algorithm: "VU_METER") } }
                tag("Parti") { state.run { try await $0.setAmbilight(style: "FOLLOW_AUDIO", algorithm: "PARTY") } }
                tag("Kapat") { state.run { try await $0.setAmbilight(style: "OFF") } }
            }
        }
    }

    private var sourceRow: some View {
        HStack {
            smallButton("Kaynak", "tv.and.hifispeaker.fill") { key("Source") }
            Spacer()
            if !state.currentApp.isEmpty {
                Text("Aktif: \(state.currentApp)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @State private var typed: String = ""
    private var keyboardRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
            TextField("TV'ye yaz…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            Button("Gönder") { send() }.buttonStyle(.bordered)
        }
    }
    private func send() {
        let t = typed; typed = ""
        guard !t.isEmpty else { return }
        state.run("klavye") { try await $0.textEntry(t) }
    }

    private var footer: some View {
        HStack {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            Button("Yenile") { Task { await state.refresh() } }.font(.caption2).buttonStyle(.plain)
            Button("Çıkış") { NSApplication.shared.terminate(nil) }.font(.caption2).buttonStyle(.plain)
        }
    }

    // helpers
    private func key(_ k: String) { state.run(k) { try await $0.sendKey(k) } }

    private func iconButton(_ sys: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sys)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func smallButton(_ title: String, _ sys: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: sys).font(.caption)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private func tag(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Color.white.opacity(0.08), in: Capsule())
        }.buttonStyle(.plain)
    }
}

// MARK: - Trackpad (pointer control for the TV browser)

struct TrackpadView: View {
    @EnvironmentObject var state: AppState
    @State private var last: CGPoint?

    var body: some View {
        VStack(spacing: 4) {
            Text("🖱 Trackpad — sürükle, dokun = OK").font(.caption2).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .frame(height: 90)
                .overlay(Image(systemName: "hand.point.up.left.fill").foregroundStyle(.white.opacity(0.25)))
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
                                state.run { try await $0.sendKey("Confirm") }
                            }
                            last = nil
                        }
                )
        }
    }
}
