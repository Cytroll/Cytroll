import SwiftUI

public struct LiveConsoleView: View {
    @Binding var isPresented: Bool
    @ObservedObject var console = ConsoleManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    
    // We pass a boolean to indicate if the background process is still running
    var isRunning: Bool
    var title: String
    
    public init(isPresented: Binding<Bool>, isRunning: Bool, title: String) {
        self._isPresented = isPresented
        self.isRunning = isRunning
        self.title = title
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            // خلفية الشاشة السوداء بالكامل (Classic Terminal)
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // شريط العنوان العلوي
                ZStack {
                    Color(white: 0.1).ignoresSafeArea(edges: .top)
                    Text(isRunning ? "\(title) (Executing...)" : "\(title) (Complete)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(isRunning ? .orange : .green)
                        .padding(.vertical, 16)
                }
                .frame(height: 50)
                
                // مخرجات الكونسول مع التمرير التلقائي
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(console.logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(logColor(for: log))
                                    .id(index) // Anchor نقطة ارتكاز للتمرير
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: console.logs.count) { _ in
                            if !console.logs.isEmpty {
                                withAnimation {
                                    proxy.scrollTo(console.logs.count - 1, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                
                // زر الرجوع يظهر فقط عند انتهاء العملية
                if !isRunning {
                    Button(action: {
                        isPresented = false
                        console.clear() // تنظيف السجل استعداداً للعملية القادمة
                    }) {
                        Text("Dismiss")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(white: 0.15))
                    }
                }
            }
        }
        .preferredColorScheme(.dark) // إجبار النمط الداكن لشريط الحالة
    }
    
    // MARK: - ملون النصوص الذكي
    private func logColor(for log: String) -> Color {
        let lower = log.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("fatal") || lower.contains("❌") {
            return .red
        } else if lower.contains("success") || lower.contains("done") || lower.contains("perfectly") || lower.contains("✅") || lower.contains("🏁") {
            return .green
        } else if lower.contains("warning") || lower.contains("🛠️") || lower.contains("🩹") {
            return .yellow
        } else {
            return .white
        }
    }
}
