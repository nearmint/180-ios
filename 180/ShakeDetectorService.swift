import Combine
import CoreMotion
import Foundation

/// Détecte les secousses de l'appareil via CoreMotion (userAcceleration = sans gravité)
@MainActor
final class ShakeDetectorService: ObservableObject {
    static let shared = ShakeDetectorService()

    private let motionManager = CMMotionManager()
    @Published var didShake = false

    private var lastShakeTime: Date = .distantPast
    private let shakeThreshold: Double = 2.2   // g (sans gravité)
    private let shakeCooldown: TimeInterval = 2.0

    private init() {}

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.05
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let ua = motion.userAcceleration
            let magnitude = sqrt(ua.x * ua.x + ua.y * ua.y + ua.z * ua.z)
            guard magnitude > self.shakeThreshold else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastShakeTime) > self.shakeCooldown else { return }
            self.lastShakeTime = now
            self.didShake = true
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    func reset() {
        didShake = false
    }
}
