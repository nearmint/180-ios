import SwiftUI
import Combine

struct ToastView: View {
    let message: String
    let type: ToastType

    enum ToastType {
        case error
        case success
        case info

        var icon: String {
            switch self {
            case .error: return "exclamationmark.triangle"
            case .success: return "checkmark.circle"
            case .info: return "info.circle"
            }
        }

        var color: Color {
            switch self {
            case .error: return .red
            case .success: return .green
            case .info: return .accent180
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: type.icon)
                .foregroundColor(type.color)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.horizontal)
    }
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var isShowing = false
    @Published var message = ""
    @Published var type: ToastView.ToastType = .info

    /// Réduire les animations : fondu court au lieu du ressort. Lu au moment de
    /// l'affichage — le manager n'est pas une vue, pas d'`@Environment` ici.
    private var animation: Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : .spring()
    }

    func show(_ message: String, type: ToastView.ToastType = .error) {
        DispatchQueue.main.async {
            self.message = message
            self.type = type
            withAnimation(self.animation) {
                self.isShowing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(self.animation) {
                    self.isShowing = false
                }
            }
        }
    }
}

struct ToastModifier: ViewModifier {
    @ObservedObject var toast = ToastManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if toast.isShowing {
                ToastView(message: toast.message, type: toast.type)
                    // Réduire les animations : fondu seul, sans glissement.
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .padding(.top, 50)
                    .zIndex(100)
            }
        }
    }
}

extension View {
    func withToast() -> some View {
        modifier(ToastModifier())
    }
}
