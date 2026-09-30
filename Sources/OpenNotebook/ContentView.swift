import SwiftUI

public struct ContentView: View {
    @ObservedObject var serviceManager: ServiceManager

    public init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
    }

    public var body: some View {
        Group {
            switch serviceManager.phase {
            case .idle:
                ProgressView("Initializing services...")
                    .progressViewStyle(CircularProgressViewStyle())
            case .starting(let serviceName):
                VStack(spacing: 16) {
                    ProgressView("Starting \(serviceName)...")
                        .progressViewStyle(CircularProgressViewStyle())
                    Text(serviceName)
                        .font(.headline)
                }
            case .ready:
                WebView(url: $currentWebURL, reloadTrigger: $reloadTrigger)
            case .failed(let message):
                VStack(spacing: 24) {
                    Text("Failed to start services")
                        .font(.headline)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Retry") {
                        serviceManager.retry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @State private var currentWebURL: URL? = URL(string: "http://127.0.0.1:8502")

    @State private var reloadTrigger = false
}
