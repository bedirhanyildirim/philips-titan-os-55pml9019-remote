import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var client: PhilipsClient?
    @Published var needsPairing: Bool
    @Published var isOn: Bool = false
    @Published var modelName: String = ""
    @Published var currentApp: String = ""
    @Published var statusMessage: String = ""

    // pairing flow
    @Published var pairingHost: String = "192.168.0.45"
    @Published var pairingPIN: String = ""
    @Published var pairingAwaitingPIN: Bool = false
    private var pairingTimestamp: Int = 0

    init() {
        let c = PhilipsClient.loadSaved()
        self.client = c
        self.needsPairing = (c == nil)
        if c != nil { Task { await refresh() } }
    }

    func refresh() async {
        guard let c = client else { AppState.log("refresh: no client"); return }
        do {
            let state = try await c.powerState()
            isOn = (state == "On")
            if let name = try? await c.systemInfo()["name"] as? String { modelName = name }
            if let act = try? await c.currentActivity() { currentApp = act }
            statusMessage = ""
        } catch {
            statusMessage = "Bağlanılamadı"
            AppState.log("refresh ERROR: \(error)")
        }
    }

    nonisolated static func log(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".philips-tv-remote/app.log")
        let line = "\(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // fire-and-forget command with light error surfacing
    func run(_ label: String = "", _ body: @escaping (PhilipsClient) async throws -> Void) {
        guard let c = client else { return }
        Task {
            do { try await body(c) }
            catch { statusMessage = "\(label) hata" }
        }
    }

    // MARK: pairing

    func startPairing() {
        let c = PhilipsClient(host: pairingHost)
        client = c
        statusMessage = "TV'ye istek gönderiliyor…"
        Task {
            do {
                let (_, ts) = try await c.pairRequest()
                pairingTimestamp = ts
                pairingAwaitingPIN = true
                statusMessage = "TV ekranındaki PIN'i gir"
            } catch {
                statusMessage = "İstek başarısız — IP doğru mu?"
            }
        }
    }

    func finishPairing() {
        guard let c = client else { return }
        let pin = pairingPIN
        Task {
            do {
                try await c.pairGrant(pin: pin, timestamp: pairingTimestamp)
                needsPairing = false
                pairingAwaitingPIN = false
                pairingPIN = ""
                statusMessage = ""
                await refresh()
            } catch {
                statusMessage = "PIN geçersiz / süresi doldu — tekrar dene"
                pairingAwaitingPIN = false
            }
        }
    }
}
