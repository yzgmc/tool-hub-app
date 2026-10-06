import SwiftUI
import WebKit
import UIKit

/// WebView 插件：打开网关反代的子应用页面（自动拼 base + plugin.url）。
struct WebPluginView: View {
    @EnvironmentObject private var store: SettingsStore
    let plugin: Plugin

    var body: some View {
        let target = (store.client.base + (plugin.url ?? "/"))
        WebContainer(urlString: target)
            .navigationTitle(plugin.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let u = URL(string: target) {
                            UIApplication.shared.open(u)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
            }
    }
}

struct WebContainer: View {
    let urlString: String
    @State private var progress: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            if progress < 1.0 && progress > 0 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            WebView(urlString: urlString, progress: $progress)
        }
    }
}

struct WebView: UIViewRepresentable {
    let urlString: String
    @Binding var progress: Double

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        // 网关已带鉴权（App 的 API 请求）；页面本身走反代无需额外 token
        if let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        init(_ parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.progress = 1.0
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            parent.progress = 1.0
        }
    }
}
