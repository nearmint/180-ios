//
//  AppDelegate.swift
//  180
//
//  AppDelegate minimal, dédié à OneSignal : le SDK 5 a besoin d'un delegate pour
//  `didFinishLaunchingWithOptions`. Aucune logique existante n'est déplacée ici —
//  l'enregistrement des polices et l'initialisation Firebase restent dans
//  `_80App.init()`.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotificationService.shared.initialize(launchOptions: launchOptions)
        // `app_first_open` : gardé par un drapeau `UserDefaults`, donc émis une
        // seule fois dans la vie de l'installation.
        UmamiTracker.shared.trackFirstOpenIfNeeded()
        return true
    }

    /// Portrait forcé au runtime, en complément des `UISupportedInterfaceOrientations`
    /// de l'Info.plist : cette méthode fait autorité et couvre aussi les contrôleurs
    /// présentés modalement (lecteur vidéo, `SFSafariViewController`…) qui pourraient
    /// sinon basculer en paysage.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}
