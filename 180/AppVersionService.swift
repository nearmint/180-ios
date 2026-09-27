import Foundation

/// Réponse de `GET 180c/v1/app-version` — `{ ios:{min,current}, android:{…} }`.
struct AppVersionResponse: Decodable {
    let ios: PlatformVersion
}

struct PlatformVersion: Decodable {
    let min: String
    let current: String
}

enum VersionCheckResult {
    case ok
    case forceUpdate(String)
}

/// Vérifie si la version installée est toujours supportée.
class AppVersionService {
    static let shared = AppVersionService()
    private init() {}

    /// Endpoint REST (remplace l'ancien fichier statique app-version.json).
    private var versionURL: String { "\(APIConfig.shared.restV1)/app-version" }

    /// Message affiché en cas de version trop ancienne (l'endpoint ne le fournit pas).
    private static let forceUpdateMessage = "Une mise à jour est requise pour continuer à utiliser l'app."

    func checkMinimumVersion() async -> VersionCheckResult {
        guard let url = URL(string: versionURL) else { return .ok }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, _) = try await AppHTTP.session.data(for: request)
            let info = try JSONDecoder().decode(AppVersionResponse.self, from: data)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            if !isVersion(current, atLeast: info.ios.min) {
                return .forceUpdate(Self.forceUpdateMessage)
            }
            return .ok
        } catch {
            // Fail open : si le serveur est injoignable, l'app continue normalement.
            return .ok
        }
    }

    private func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let v1 = version.split(separator: ".").compactMap { Int($0) }
        let v2 = minimum.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(v1.count, v2.count) {
            let a = i < v1.count ? v1[i] : 0
            let b = i < v2.count ? v2[i] : 0
            if a < b { return false }
            if a > b { return true }
        }
        return true
    }
}
