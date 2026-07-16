import SwiftUI

extension View {
    /// Hides the system List/ScrollView background when available (iOS 16+).
    /// No-op on iOS 15 so the deployment target stays at 15.0.
    @ViewBuilder
    func cytrollHideScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
