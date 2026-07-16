import SwiftUI
import Combine

// MARK: - Theme Protocols
public protocol ThemeProtocol {
    var name: String { get }
    var accent: Color { get }
    var background: [Color] { get }
    var cardBackground: Color { get }
    var textPrimary: Color { get }
    var textSecondary: Color { get }
}

// MARK: - Mocha Theme (Classic)
public struct MochaTheme: ThemeProtocol {
    public let name = "Mocha"
    public let accent = Color(red: 0.68, green: 0.48, blue: 0.32)
    public let background = [Color(red: 0.07, green: 0.05, blue: 0.04), Color(red: 0.12, green: 0.09, blue: 0.07)]
    public let cardBackground = Color(red: 0.15, green: 0.12, blue: 0.10)
    public let textPrimary = Color.white
    public let textSecondary = Color.gray
}

// MARK: - Espresso Theme (OLED Dark Mode)
public struct EspressoTheme: ThemeProtocol {
    public let name = "Espresso"
    public let accent = Color(red: 0.80, green: 0.60, blue: 0.45)
    public let background = [Color(red: 0.02, green: 0.01, blue: 0.01), Color(red: 0.05, green: 0.04, blue: 0.04)]
    public let cardBackground = Color(red: 0.08, green: 0.07, blue: 0.07)
    public let textPrimary = Color.white
    public let textSecondary = Color.gray
}

// MARK: - Theme Manager
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    @Published public var currentTheme: ThemeProtocol = MochaTheme()
    
    private init() {
        let savedTheme = UserDefaults.standard.string(forKey: "activeTheme") ?? "Mocha"
        switchTheme(to: savedTheme)
    }
    
    public func switchTheme(to themeName: String) {
        if themeName == "Espresso" {
            currentTheme = EspressoTheme()
        } else {
            currentTheme = MochaTheme()
        }
        
        UserDefaults.standard.set(themeName, forKey: "activeTheme")
        updateTabBarAppearance()
    }
    
    public func backgroundGradient() -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: currentTheme.background),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private func updateTabBarAppearance() {
        let appearance = UITabBarAppearance()
        
        // Professional Glassmorphism effect for TabBar
        let blurEffect = UIBlurEffect(style: .systemThinMaterialDark)
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = blurEffect
        
        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor(currentTheme.textSecondary)
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(currentTheme.textSecondary)]
        
        itemAppearance.selected.iconColor = UIColor(currentTheme.accent)
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(currentTheme.accent)]
        
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance
        
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Glassmorphism View Modifier
public struct GlassmorphismModifier: ViewModifier {
    let theme: ThemeProtocol
    
    public func body(content: Content) -> some View {
        content
            .background(theme.cardBackground.opacity(0.6))
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.2), .clear, .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

public extension View {
    func glassCard(theme: ThemeProtocol) -> some View {
        self.modifier(GlassmorphismModifier(theme: theme))
    }
}
