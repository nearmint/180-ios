//
//  NotificationService.swift
//  OneSignalNotificationServiceExtension
//
//  Notification Service Extension OneSignal (SDK 5). Elle permet l'affichage des
//  images dans les notifications (rich push) et la confirmation de délivrance.
//  Le corps suit le pattern officiel du SDK 5 — ne pas réécrire de mémoire.
//

import UserNotifications
import OneSignalExtension

final class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var receivedRequest: UNNotificationRequest!
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.receivedRequest = request
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        if let bestAttemptContent = bestAttemptContent {
            OneSignalExtension.didReceiveNotificationExtensionRequest(
                request,
                with: bestAttemptContent,
                withContentHandler: contentHandler
            )
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            OneSignalExtension.serviceExtensionTimeWillExpireRequest(
                receivedRequest,
                with: bestAttemptContent
            )
            contentHandler(bestAttemptContent)
        }
    }
}
