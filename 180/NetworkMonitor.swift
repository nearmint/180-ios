import Foundation
import Network
import Observation
import os

/// Source **unique** de vérité de la connectivité, adossée à `NWPathMonitor`.
///
/// Deux mécanismes coexistent volontairement dans l'app et ne se recouvrent pas :
///
/// - `NetworkMonitor` pilote l'UI **proactive** — bandeau hors ligne, gating des
///   cycles de synchronisation. Il répond à « y a-t-il un chemin réseau ? » avant
///   même qu'une requête soit émise.
/// - `APIError` (cf. `Networking.swift`) pilote l'UI **réactive** — l'échec d'une
///   requête déjà partie, typé `.offline` / `.timeout` / `.http(_)`…
///
/// Un chemin satisfait ne garantit pas qu'une requête aboutira (portail captif,
/// serveur à terre) : le monitor ne remplace donc jamais la taxonomie d'erreurs.
///
/// ## Hystérésis
///
/// Une perte de chemin n'est publiée qu'après `offlineGrace`, et annulée si le
/// réseau revient entre-temps. Sans ce délai, un basculement Wi-Fi → cellulaire
/// ou une micro-coupure ferait clignoter le bandeau. Le **retour** en ligne est
/// publié immédiatement (rien à amortir : on ne fait qu'enlever un bandeau), et
/// le **tout premier** verdict au lancement l'est aussi, pour qu'une app ouverte
/// en mode avion affiche son bandeau d'emblée plutôt qu'une seconde et demie
/// plus tard.
@MainActor
@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    /// `true` tant qu'un chemin réseau est disponible. Optimiste au démarrage :
    /// la première mise à jour de `NWPathMonitor` arrive en quelques
    /// millisecondes et corrige la valeur avant tout rendu utile.
    private(set) var isConnected = true

    /// Délai d'amortissement avant de publier une perte de connectivité.
    private static let offlineGrace: Duration = .milliseconds(1500)

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(
        label: "fr.thermostat6.app180.networkmonitor",
        qos: .utility
    )
    /// Publication différée d'une perte, annulable si le réseau revient.
    @ObservationIgnored private var pendingOffline: Task<Void, Never>?
    @ObservationIgnored private var hasSettledFirstPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            // Recapture faible : la `Task` reçoit sa propre copie de la
            // référence au lieu de relire la variable capturée par le handler.
            Task { @MainActor [weak self] in self?.apply(satisfied: satisfied) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Applique un verdict de chemin en respectant l'hystérésis.
    private func apply(satisfied: Bool) {
        // Premier verdict : appliqué tel quel, sans amortissement.
        guard hasSettledFirstPath else {
            hasSettledFirstPath = true
            pendingOffline?.cancel()
            pendingOffline = nil
            setConnected(satisfied)
            return
        }

        if satisfied {
            pendingOffline?.cancel()
            pendingOffline = nil
            setConnected(true)
            return
        }

        // Perte : différée. Une perte déjà en attente n'est pas replanifiée.
        guard isConnected, pendingOffline == nil else { return }
        pendingOffline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.offlineGrace)
            guard !Task.isCancelled, let self else { return }
            self.pendingOffline = nil
            self.setConnected(false)
        }
    }

    /// Écrit `isConnected` **seulement en cas de changement effectif** : le
    /// registrar d'`@Observable` notifierait sinon les vues à chaque mise à jour
    /// de chemin (changement d'interface, de passerelle…) sans transition réelle.
    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        let state = value ? "en ligne" : "hors ligne"
        AppLogger.data.info("[Réseau] \(state, privacy: .public)")
    }
}
