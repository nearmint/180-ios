import Foundation
import OSLog

enum AppLogger {
    // `SWIFT_APPROACHABLE_CONCURRENCY` isole le module sur le main actor par
    // défaut. On marque ces loggers `nonisolated` (Logger est Sendable) pour
    // qu'ils restent accessibles depuis n'importe quel contexte — y compris des
    // acteurs (ex. RecipeTaxonomyResolver) — sans erreur d'isolation en Swift 6.
    nonisolated static let api = Logger(subsystem: "fr.180c.app", category: "API")
    nonisolated static let auth = Logger(subsystem: "fr.180c.app", category: "Auth")
    nonisolated static let ui = Logger(subsystem: "fr.180c.app", category: "UI")
    nonisolated static let data = Logger(subsystem: "fr.180c.app", category: "Data")
    nonisolated static let notif = Logger(subsystem: "fr.180c.app", category: "Notifications")
}
