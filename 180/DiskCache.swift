import Foundation

/// Cache disque générique clé → valeur `Codable`, avec horodatage et TTL.
///
/// Support de la stratégie **stale-while-revalidate** : l'appelant lit d'abord
/// la valeur en cache (affichage immédiat, même légèrement périmée dans la
/// limite du TTL), puis rafraîchit en réseau et réécrit. Les fichiers vivent
/// dans `Caches/` — évincés par le système sous pression disque, jamais
/// sauvegardés sur iCloud. Les écritures sont asynchrones (hors main thread).
///
/// `nonisolated` (l'isolation par défaut du module est `MainActor`) : l'encodage
/// tourne sur `ioQueue`. D'où `T: Sendable` sur `store` — cette contrainte
/// refuse à la compilation un type dont la conformance `Codable` serait isolée
/// au main actor, donc inutilisable sur cette file.
nonisolated final class DiskCache: Sendable {
    static let shared = DiskCache()

    private let directory: URL
    private let ioQueue = DispatchQueue(label: "fr.thermostat6.app180.diskcache", qos: .utility)

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("net-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Enveloppe horodatée : permet de calculer l'âge sans dépendre de la date
    /// de modification du fichier (peu fiable après restauration/synchro).
    private struct Envelope<T: Codable>: Codable {
        let storedAt: Date
        let value: T
    }

    private func fileURL(_ key: String) -> URL {
        // Clé → nom de fichier sûr (base64 url-safe, jamais de séparateur).
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    /// Écrit une valeur (asynchrone). Écrase toute valeur précédente.
    func store<T: Codable & Sendable>(_ value: T, forKey key: String) {
        let url = fileURL(key)
        ioQueue.async {
            let envelope = Envelope(storedAt: Date(), value: value)
            if let data = try? JSONEncoder().encode(envelope) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Lit une valeur si présente **et plus jeune que `maxAge`** (`nil` sinon).
    func load<T: Codable>(_ type: T.Type, forKey key: String, maxAge: TimeInterval) -> T? {
        guard let data = try? Data(contentsOf: fileURL(key)),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(envelope.storedAt) <= maxAge else { return nil }
        return envelope.value
    }

    /// Vide tout le cache disque JSON.
    func clear() {
        let dir = directory
        ioQueue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
