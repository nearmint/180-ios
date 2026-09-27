//
//  NotificationsRepository.swift
//  180
//
//  Récupère le feed des notifications depuis WordPress (180c/v1/notifications) et
//  le met en cache sur disque pour l'affichage hors-ligne. Helper sans état
//  observable, utilisé par NotificationManager.
//

import Foundation
import os

enum NotificationsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

struct NotificationsRepository {

    let perPage = 20

    private static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private var cacheURL: URL? {
        let dir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return dir?.appendingPathComponent("notifications_feed.json")
    }

    /// Récupère une page du feed (déjà envoyées, plus récentes d'abord).
    func fetch(page: Int) async throws -> [AppNotification] {
        guard let url = URL(string: "\(APIConfig.shared.restV1)/notifications?page=\(page)&per_page=\(perPage)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await AppHTTP.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.iso8601.decode([AppNotification].self, from: data)
    }

    // MARK: - Cache disque

    func saveCache(_ items: [AppNotification]) {
        guard let url = cacheURL else { return }
        do {
            try Self.encoder.encode(items).write(to: url, options: .atomic)
        } catch {
            AppLogger.data.error("[Notifs] écriture cache échouée: \(error)")
        }
    }

    func loadCache() -> [AppNotification] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.iso8601.decode([AppNotification].self, from: data)) ?? []
    }
}
