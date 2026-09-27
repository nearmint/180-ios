import Foundation
import SwiftUI
import UIKit

// MARK: - Color

extension Color {
    static let accent180 = Color(red: 255/255, green: 174/255, blue: 58/255)
}

// MARK: - String

extension String {
    func stripHTML() -> String {
        // Supprimer les balises HTML
        var result = self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Décoder les entités HTML courantes
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#8217;", "'"),
            ("&#8216;", "'"),
            ("&#8220;", "\""),
            ("&#8221;", "\""),
            ("&#8211;", "–"),
            ("&#8212;", "—"),
            ("&#8230;", "…"),
            ("&nbsp;", " "),
            ("&#038;", "&"),
            ("&#8209;", "‑"),
            ("&rsquo;", "'"),
            ("&lsquo;", "'"),
            ("&rdquo;", "\""),
            ("&ldquo;", "\""),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&hellip;", "…"),
            ("&#8242;", "′"),
            ("&#8243;", "″"),
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Supprimer les entités numériques restantes
        result = result.replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - App Fonts

enum AppFont {
    // `relativeTo:` rend les polices custom **scalables avec Dynamic Type**
    // (`.custom(_:size:)` seul reste à taille fixe). Par défaut relatif à `.body`.
    static func oswald(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .bold: name = "Oswald-Regular_Bold"
        case .semibold: name = "Oswald-Regular_SemiBold"
        case .medium: name = "Oswald-Regular_Medium"
        case .light: name = "Oswald-Regular_Light"
        default: name = "Oswald-Regular"
        }
        return .custom(name, size: size, relativeTo: textStyle)
    }

    static func playfair(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .bold: name = "PlayfairDisplayRoman-Bold"
        case .semibold: name = "PlayfairDisplayRoman-SemiBold"
        case .medium: name = "PlayfairDisplayRoman-Medium"
        default: name = "PlayfairDisplay-Regular"
        }
        return .custom(name, size: size, relativeTo: textStyle)
    }

    static func playfairItalic(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom("PlayfairDisplay-Italic", size: size, relativeTo: textStyle)
    }
}

// MARK: - Haptics

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Button Styles

struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
