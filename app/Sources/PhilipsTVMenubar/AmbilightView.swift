import SwiftUI

/// Rich Ambilight control: Video / Audio / Colour modes + Off, matching the
/// official Philips app. Values confirmed against the TV's JointSpace API.
struct AmbilightView: View {
    @EnvironmentObject var state: AppState
    @State private var category: Category = .video

    enum Category: String, CaseIterable, Identifiable {
        case video = "Video", audio = "Ses", colour = "Renk"
        var id: String { rawValue }
    }

    // (label, menuSetting) — styleName FOLLOW_VIDEO
    private let videoModes: [(String, String)] = [
        ("Standart", "STANDARD"), ("Doğal", "NATURAL"), ("Canlı", "VIVID"),
        ("Oyun", "GAME"), ("Konfor", "COMFORT"), ("Rahat", "RELAX"), ("Spor", "SPORTS"),
    ]
    // (label, algorithm) — styleName FOLLOW_AUDIO
    private let audioModes: [(String, String)] = [
        ("Lumina", "ENERGY_ADAPTIVE_BRIGHTNESS"), ("Colora", "ENERGY_ADAPTIVE_COLORS"),
        ("Retro", "VU_METER"), ("Spektrum", "SPECTRUM_ANALYZER"),
        ("Tarayıcı", "KNIGHT_RIDER_CLOCKWISE"), ("Ritim", "RANDOM_PIXEL_FLASH"),
        ("Strobe", "STROBE"), ("Parti", "PARTY"),
    ]
    // (label, menuSetting, swatch) — styleName FOLLOW_COLOR
    private let colourModes: [(String, String, Color)] = [
        ("Hot Lava", "HOT_LAVA", .red), ("Deep Water", "DEEP_WATER", .blue),
        ("Fresh Nature", "FRESH_NATURE", .green), ("Warm White", "ISF", Color(.sRGB, red: 1, green: 0.85, blue: 0.6)),
        ("Cool White", "PTA_LOUNGE", Color(.sRGB, red: 0.85, green: 0.92, blue: 1)),
    ]

    private let cols = [GridItem(.adaptive(minimum: 78), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🎨 Ambilight").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Kapat") { set(style: "OFF") }
                    .font(.caption2).buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            Picker("", selection: $category) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(columns: cols, spacing: 6) {
                switch category {
                case .video:
                    ForEach(videoModes, id: \.1) { m in
                        chip(m.0) { set(style: "FOLLOW_VIDEO", menu: m.1) }
                    }
                case .audio:
                    ForEach(audioModes, id: \.1) { m in
                        chip(m.0) { set(style: "FOLLOW_AUDIO", algorithm: m.1) }
                    }
                case .colour:
                    ForEach(colourModes, id: \.1) { m in
                        chip(m.0, dot: m.2) { set(style: "FOLLOW_COLOR", menu: m.1) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, dot: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let dot = dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func set(style: String, menu: String? = nil, algorithm: String? = nil) {
        state.run("Ambilight") { try await $0.setAmbilight(style: style, menu: menu, algorithm: algorithm) }
    }
}
