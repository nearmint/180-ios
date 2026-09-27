import Foundation
import Combine

/// Routeur d'onglets partagé : permet à un écran (ex. rail « Mon carnet » de
/// l'accueil) de basculer programmatiquement vers un autre onglet (Favoris).
@MainActor
final class TabRouter: ObservableObject {
    static let shared = TabRouter()

    @Published var selected = 0

    enum Tab {
        static let home = 0
        static let search = 1
        static let favorites = 2
        static let account = 3
    }
}
