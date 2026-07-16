import SwiftUI
import WebKit

/// Thin `WKWebView` wrapper for rendering a package's classic Cydia-style
/// `Depiction:`/`SileoDepiction:` page — these are plain HTML pages meant
/// for an in-app browser, not Sileo's newer native JSON depiction format
/// (out of scope here; unsupported repos simply won't set this field).
public struct DepictionWebView: UIViewRepresentable {
    let url: URL

    public func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

public struct DepictionView: View {
    let title: String
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var themeManager = ThemeManager.shared

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    public var body: some View {
        NavigationView {
            DepictionWebView(url: url)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundColor(themeManager.currentTheme.accent)
                    }
                }
        }
    }
}
