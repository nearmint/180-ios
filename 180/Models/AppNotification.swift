//
//  AppNotification.swift
//  180
//
//  Modèle du centre de notifications, dérivé du JSON réel de
//  GET /wp-json/180c/v1/notifications (voir Lot A). `isRead` est un état local
//  (non servi par l'API).
//

import Foundation

struct AppNotification: Identifiable, Codable, Equatable {
    let id: Int
    let title: String
    let body: String
    let imageURL: URL?
    let target: Target
    let sentAt: Date
    /// État de lecture local (persisté côté app, absent du feed).
    var isRead: Bool = false

    struct Target: Codable, Equatable {
        let type: String   // recipe | article | url | none
        let id: Int
        let url: String
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, target
        case imageURL = "image_url"
        case sentAt = "sent_at"
    }

    /// Icône SF Symbol — réutilise les symboles déjà en place pour chaque cas
    /// (recette, éditorial, autre) afin de préserver l'apparence de la row.
    var iconName: String {
        switch target.type {
        case "recipe":  return "fork.knife"
        case "article": return "book"
        case "product": return "bag"
        default:        return "star"
        }
    }
}
