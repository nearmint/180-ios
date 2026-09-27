import Foundation

/// Découpage des IDs en pages acceptées par `wp/v2`.
///
/// Logique **pure**, isolée du réseau pour être testable : c'est elle qui évite
/// le 400 que produit un `per_page` supérieur à la borne serveur.
///
/// Miroir Android : `RecipeFreshnessPaging` (`android/…/data/model/RecipeFreshness.kt`).
enum RecipePaging {

    /// Nombre maximum d'éléments par page accepté par `wp/v2` — au-delà, le
    /// serveur répond 400.
    static let maxPerPage = 100

    /// Découpe `ids` en pages d'au plus `maxPerPage` éléments, **dans l'ordre
    /// d'entrée**. Une liste vide ne produit aucune page.
    static func chunk(_ ids: [Int], maxPerPage: Int = RecipePaging.maxPerPage) -> [[Int]] {
        precondition(maxPerPage > 0, "maxPerPage doit être strictement positif")
        guard !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: maxPerPage).map { start in
            Array(ids[start..<min(start + maxPerPage, ids.count)])
        }
    }
}
