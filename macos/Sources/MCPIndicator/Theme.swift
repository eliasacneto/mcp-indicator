import SwiftUI

extension HealthStatus {
    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemGreen)
        case .degraded: Color(nsColor: .systemYellow)
        case .remote: Color(nsColor: .systemBlue)
        case .stopped, .disabled: Color(nsColor: .systemGray)
        }
    }

    var label: String {
        switch self {
        case .running: "em execução"
        case .degraded: "degradado"
        case .remote: "remoto"
        case .stopped: "parado"
        case .disabled: "desligado"
        }
    }
}

enum Theme {
    static let symbol = "point.3.filled.connected.trianglepath.dotted"
    static let accent = LinearGradient(
        colors: [Color(red: 0.38, green: 0.36, blue: 0.98), Color(red: 0.70, green: 0.33, blue: 0.95)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Ponto de estado com halo; pulsa suavemente enquanto o MCP está vivo.
struct StatusDot: View {
    let status: HealthStatus
    var size: CGFloat = 9
    var animated = true
    @ViewState private var pulse = false

    var body: some View {
        ZStack {
            if animated && status == .running {
                Circle()
                    .fill(status.color.opacity(0.35))
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.1 : 1)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(status.color.gradient)
                .frame(width: size, height: size)
                .shadow(color: status.color.opacity(status == .stopped ? 0 : 0.6), radius: 3)
        }
        .frame(width: size * 2, height: size * 2)
        .onAppear { pulse = true }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// `@State` virou macro no SDK do macOS 27 e o plugin só vem com o Xcode.
/// Este wrapper usa o tipo `State` directamente, para compilar também só com as Command Line Tools.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
