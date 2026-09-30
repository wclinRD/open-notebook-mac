import SwiftUI
import WebKit

public struct WebView: NSViewRepresentable {
    @Binding public var url: URL?
    @Binding public var reloadTrigger: Bool

    public init(url: Binding<URL?>, reloadTrigger: Binding<Bool>) {
        self._url = url
        self._reloadTrigger = reloadTrigger
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.webView.navigationDelegate = context.coordinator
        // The command menu posts this instead of flipping a binding, so a reload
        // does not require rebuilding the view tree.
        context.coordinator.observeReload(on: container.webView)
        if let url {
            container.webView.load(URLRequest(url: url))
            context.coordinator.loadedURL = url
        }
        return container
    }

    public func updateNSView(_ nsView: WebViewContainer, context: Context) {
        // Only navigate when the target actually changed. Re-loading on every
        // update would yank the user back to the home page on any state change.
        guard let url, url != context.coordinator.loadedURL else { return }
        nsView.webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
    }

    public static func dismantleNSView(_ nsView: WebViewContainer, coordinator: Coordinator) {
        if let observer = coordinator.reloadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        nsView.webView.navigationDelegate = nil
        nsView.webView.stopLoading()
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var reloadObserver: NSObjectProtocol?

        func observeReload(on webView: WKWebView) {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .openNotebookReloadWebView,
                object: nil,
                queue: .main
            ) { _ in
                webView.reload()
            }
        }

        /// A failed load is almost always the web server not being up yet; the
        /// health check passed but the page request raced it.
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            NSLog("OpenNotebook web load failed: \(error.localizedDescription)")
        }
    }
}

public final class WebViewContainer: NSView {
    public let webView: WKWebView

    override public init(frame: CGRect) {
        // Behind-window material rather than a solid fill, so the window does not
        // flash white while the page loads.
        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.material = .underWindowBackground

        webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true

        super.init(frame: frame)
        addSubview(effectView)
        addSubview(webView)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
