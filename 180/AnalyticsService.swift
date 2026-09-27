import Foundation
import FirebaseAnalytics

enum AnalyticsService {

    // MARK: - Recettes

    static func viewRecipe(id: Int, title: String, isPremium: Bool) {
        Analytics.logEvent("view_recipe", parameters: [
            "recipe_id": id,
            "recipe_title": title,
            "is_premium": isPremium
        ])
    }

    static func paywallView(id: Int, title: String) {
        Analytics.logEvent("paywall_view", parameters: [
            "recipe_id": id,
            "recipe_title": title
        ])
    }

    static func shareRecipe(id: Int, title: String) {
        Analytics.logEvent("share_recipe", parameters: [
            "recipe_id": id,
            "recipe_title": title
        ])
    }

    // MARK: - Favoris

    static func addFavorite(id: Int, title: String) {
        Analytics.logEvent("add_favorite", parameters: [
            "recipe_id": id,
            "recipe_title": title
        ])
    }

    static func removeFavorite(id: Int, title: String) {
        Analytics.logEvent("remove_favorite", parameters: [
            "recipe_id": id,
            "recipe_title": title
        ])
    }

    // MARK: - Recherche

    static func search(query: String, resultsCount: Int) {
        Analytics.logEvent("search", parameters: [
            "query": query,
            "results_count": resultsCount
        ])
    }

    // MARK: - Auth

    static func login(method: String) {
        Analytics.logEvent("login", parameters: [
            "method": method
        ])
    }

    static func loginFailed(error: String) {
        Analytics.logEvent("login_failed", parameters: [
            "error_message": error
        ])
    }

    static func logout() {
        Analytics.logEvent("logout", parameters: nil)
    }

    // MARK: - Conversion

    static func signupClick(source: String) {
        Analytics.logEvent("signup_click", parameters: [
            "source": source
        ])
    }

    static func boutiqueClick() {
        Analytics.logEvent("boutique_click", parameters: nil)
    }

    // MARK: - Filtres

    static func filterApplied(sortOrder: String, season: String?, dishType: String?) {
        Analytics.logEvent("filter_applied", parameters: [
            "sort_order": sortOrder,
            "season": season ?? "all",
            "dish_type": dishType ?? "all"
        ])
    }

    // MARK: - Newsletter

    static func newsletterSubscribe() {
        Analytics.logEvent("newsletter_subscribe", parameters: nil)
    }

    static func newsletterUnsubscribe() {
        Analytics.logEvent("newsletter_unsubscribe", parameters: nil)
    }

    // MARK: - Notifications

    static func notificationPermission(granted: Bool) {
        Analytics.logEvent("notification_permission", parameters: [
            "granted": granted
        ])
    }

    static func notificationOpened(id: String, type: String) {
        Analytics.logEvent("notification_opened", parameters: [
            "notification_id": id,
            "notification_type": type
        ])
    }

    // MARK: - In-App Messages

    static func inAppMessageDisplayed(id: String) {
        Analytics.logEvent("iam_displayed", parameters: [
            "message_id": id
        ])
    }

    static func inAppMessageClicked(id: String, actionId: String?) {
        Analytics.logEvent("iam_clicked", parameters: [
            "message_id": id,
            "action_id": actionId ?? "none"
        ])
    }

    // MARK: - Paramètres

    static func darkModeChanged(mode: String) {
        Analytics.logEvent("dark_mode_changed", parameters: [
            "mode": mode
        ])
    }

    static func contactSupport() {
        Analytics.logEvent("contact_support", parameters: nil)
    }

    static func rateAppClick() {
        Analytics.logEvent("rate_app_click", parameters: nil)
    }

    static func shareApp() {
        Analytics.logEvent("share_app", parameters: nil)
    }

    static func onboardingComplete() {
        Analytics.logEvent("onboarding_complete", parameters: nil)
    }

    // MARK: - User Properties

    static func setUserProperties(isLoggedIn: Bool, isSubscriber: Bool, newsletterSubscribed: Bool, darkMode: String, notificationsEnabled: Bool, favoritesCount: Int) {
        var userType = "visitor"
        if isSubscriber { userType = "subscriber" }
        else if isLoggedIn { userType = "logged_in" }

        Analytics.setUserProperty(userType, forName: "user_type")
        Analytics.setUserProperty(isSubscriber ? "true" : "false", forName: "is_subscriber")
        Analytics.setUserProperty(newsletterSubscribed ? "true" : "false", forName: "newsletter_subscribed")
        Analytics.setUserProperty(darkMode, forName: "dark_mode")
        Analytics.setUserProperty(notificationsEnabled ? "true" : "false", forName: "notifications_enabled")
        Analytics.setUserProperty("\(favoritesCount)", forName: "favorites_count")
    }
}
