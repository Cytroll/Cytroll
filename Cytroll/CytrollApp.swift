//
//  CytrollApp.swift
//  Cytroll
//
//  Created by س on 29/01/1448 AH.
//

import SwiftUI

@main
struct CytrollApp: App {
    // MARK: - Global State Injection
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Injecting global environment objects for deep view hierarchy access
                .environmentObject(themeManager)
                .environmentObject(queueManager)
                // Force dark mode to align with Rootless standard UI
                .preferredColorScheme(.dark)
        }
    }
}
