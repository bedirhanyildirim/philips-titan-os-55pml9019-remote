import SwiftUI

/// Rich Ambilight control: Video / Audio / Colour modes + Off, matching the
/// official Philips app. Values confirmed against the TV's JointSpace API.
struct AmbilightView: View {
    @EnvironmentObject var state: AppState
    @State private var category: Category = .video
    @State private var selected: String?

    enum Category: String, CaseIterable, Identifiable {
        case video = "Video", audio = "Audio", colour = "Colour"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .video: return "film"
            case .audio: return "waveform"
            case .colour: return "paintpalette"
            }
        }
        var hint: String {
            switch self {
            case .video: return "Lights follow the picture on screen"
            case .audio: return "Lights move with the music"
            case .colour: return "A fixed colour or white tone"
            }
        }
    }

    // (label, menuSetting) — styleName FOLLOW_VIDEO
    private let videoModes: [(String, String)] = [
        ("Standard", "STANDARD"), ("Natural", "NATURAL"), ("Vivid", "VIVID"),
        ("Game", "GAME"), ("Comfort", "COMFORT"), ("Relax", "RELAX"), ("Sports", "SPORTS"),
    ]
    // (label, algorithm) — styleName FOLLOW_AUDIO
    private let audioModes: [(String, String)] = [
        ("Lumina", "ENERGY_ADAPTIVE_BRIGHTNESS"), ("Colora", "ENERGY_ADAPTIVE_COLORS"),
        ("Retro", "VU_METER"), ("Spectrum", "SPECTRUM_ANALYZER"),
        ("Scanner", "KNIGHT_RIDER_CLOCKWISE"), ("Rhythm", "RANDOM_PIXEL_FLASH"),
        ("Strobe", "STROBE"), ("Party", "PARTY"),
    ]
    // (label, menuSetting, swatch) — styleName FOLLOW_COLOR
    private let colourModes: [(String, String, Color)] = [
        ("Hot Lava", "HOT_LAVA", .red), ("Deep Water", "DEEP_WATER", .blue),
        ("Fresh Nature", "FRESH_NATURE", .green), ("Warm White", "ISF", Color(.sRGB, red: 1, green: 0.85, blue: 0.6)),
        ("Cool White", "PTA_LOUNGE", Color(.sRGB, red: 0.85, green: 0.92, blue: 1)),
    ]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Ambilight")
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 20))
                        .foregroundStyle(state.glow)
                        .frame(width: 44, height: 44)
                        .background(state.glow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected ?? "Ambilight").font(.system(size: 13, weight: .semibold))
                        Text(category.hint).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PillButton(title: "Off", tint: Color.red.opacity(0.35)) {
                        selected = "Off"; state.glow = .gray
                        state.run("Ambilight") { try await $0.setAmbilightStyle(.off) }
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(Category.allCases) { c in
                    Button { category = c } label: {
                        Label(c.rawValue, systemImage: c.icon).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .foregroundStyle(category == c ? Theme.accent : .secondary)
                            .background(category == c ? Theme.accent.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))

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
                        chip(m.0, dot: m.2) { state.glow = m.2; set(style: "FOLLOW_COLOR", menu: m.1) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, dot: Color? = nil, _ action: @escaping () -> Void) -> some View {
        let on = selected == title
        return Button {
            selected = title
            if dot == nil { state.glow = Theme.accent }
            action()
        } label: {
            HStack(spacing: 5) {
                if let dot = dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(on ? Theme.accent.opacity(0.2) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.accent : Theme.cardStroke))
        }.buttonStyle(.plain)
    }

    private func set(style: String, menu: String? = nil, algorithm: String? = nil) {
        let node: PhilipsClient.AmbilightStyleNode =
            style == "FOLLOW_AUDIO" ? .audio : style == "FOLLOW_COLOR" ? .colour : .video
        state.run("Ambilight") {
            // switch the menu style first (also turns Ambilight back on after Off),
            // then pick the mode; spaced out — Titan's HTTPS server wedges on bursts
            try await $0.setAmbilightStyle(node)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await $0.setAmbilight(style: style, menu: menu, algorithm: algorithm)
        }
    }
}
