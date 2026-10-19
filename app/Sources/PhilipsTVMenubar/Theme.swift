import SwiftUI

/// Shared look: dark glassy cards, Philips-blue accent.
enum Theme {
    static let accent = Color(.sRGB, red: 0.13, green: 0.47, blue: 1.0)
    static let bg = Color(.sRGB, red: 0.07, green: 0.07, blue: 0.09)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let control = Color.white.opacity(0.08)
}

struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(spacing: 6) {
                    if let icon = icon {
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let title = title { Text(title).font(.system(size: 12, weight: .semibold)) }
                    Spacer()
                    if let trailing = trailing { trailing }
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardStroke))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Square-ish rounded icon button used across the remote/volume controls.
struct RoundButton: View {
    let icon: String
    var size: CGFloat = 36
    var tint: Color = Theme.control
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .semibold))
                .frame(width: size, height: size)
                .background(tint, in: RoundedRectangle(cornerRadius: size * 0.3))
        }.buttonStyle(.plain)
    }
}

/// Small capsule text button ("All", "Off", …).
struct PillButton: View {
    let title: String
    var tint: Color = Theme.control
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(tint, in: Capsule())
        }.buttonStyle(.plain)
    }
}
