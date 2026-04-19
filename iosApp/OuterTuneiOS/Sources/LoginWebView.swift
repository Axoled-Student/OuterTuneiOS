import SwiftUI
import WebKit

/// 以 WKWebView 模擬 Android 原版 LoginScreen：
/// 1. 讓使用者在 Google / YouTube Music 網頁上完成登入
/// 2. 當導回 music.youtube.com 時抓取完整 cookie 字串
/// 3. 同時從頁面 JS 中讀取 window.yt.config_.VISITOR_DATA 與 DATASYNC_ID
///
/// 登入完成後會呼叫 onFinish(cookie, visitorData, dataSyncId)。
struct LoginWebView: UIViewRepresentable {
    let onFinish: (String, String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 使用非持久的 dataStore 以便登入後能更乾淨地管理 cookie
        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "outertune")
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com")!
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onFinish: (String, String, String) -> Void
        weak var webView: WKWebView?

        private var latestCookie: String = ""
        private var latestVisitorData: String = ""
        private var latestDataSyncId: String = ""
        private var hasReported: Bool = false

        init(onFinish: @escaping (String, String, String) -> Void) {
            self.onFinish = onFinish
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 注入 JS 取回 VISITOR_DATA 與 DATASYNC_ID
            let js = """
            (function(){
              try {
                if (window.yt && window.yt.config_) {
                  var payload = {
                    visitorData: window.yt.config_.VISITOR_DATA || '',
                    dataSyncId: window.yt.config_.DATASYNC_ID || ''
                  };
                  window.webkit.messageHandlers.outertune.postMessage(payload);
                }
              } catch (e) { /* ignore */ }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)

            // 當導覽到 music.youtube.com 時，擷取 cookie
            guard let url = webView.url, let host = url.host else { return }
            if host.contains("music.youtube.com") || host.contains("www.youtube.com") {
                harvestCookies(from: webView)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "outertune" else { return }
            guard let body = message.body as? [String: Any] else { return }

            if let visitor = body["visitorData"] as? String, !visitor.isEmpty {
                latestVisitorData = visitor
            }
            if let dsid = body["dataSyncId"] as? String, !dsid.isEmpty {
                latestDataSyncId = dsid
            }
            tryReport()
        }

        private func harvestCookies(from webView: WKWebView) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let relevant = cookies.filter {
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                if relevant.isEmpty { return }
                let cookieString = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                self.latestCookie = cookieString
                self.tryReport()
            }
        }

        private func tryReport() {
            guard !hasReported else { return }
            // 必須同時擁有 SAPISID 與 visitor data / dataSyncId
            guard latestCookie.contains("SAPISID"),
                  !latestVisitorData.isEmpty else {
                return
            }
            hasReported = true
            let cookie = latestCookie
            let visitor = latestVisitorData
            let dataSyncId = latestDataSyncId
            DispatchQueue.main.async { [weak self] in
                self?.onFinish(cookie, visitor, dataSyncId)
            }
        }
    }
}

struct LoginContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        NavigationView {
            LoginWebView { cookie, visitor, dataSyncId in
                account.updateCookie(cookie)
                account.updateVisitorData(visitor)
                account.updateDataSyncId(dataSyncId)
                Task {
                    await player.refreshAccountInfo()
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("登入 YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
