import Foundation

/// The room-code signaling socket (web/netplay.js sigConnect): JSON messages
/// over a WebSocket to the same server the web build uses. It only relays
/// the WebRTC descriptions and candidates; game traffic is peer-to-peer.
final class LinkSignaling: NSObject, URLSessionWebSocketDelegate {
    /// web NET_SIGNAL_URL. DEBUG builds take `-signal ws://host:8790` (the
    /// local server, web/signaling) for tests.
    static var url: URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-signal"), i + 1 < args.count, let u = URL(string: args[i + 1]) {
            return u
        }
        #endif
        return URL(string: "wss://signal.dingbat.gg/signal")!
    }

    var onOpen: (() -> Void)?
    /// Before it opened (`opened` false) or after.
    var onClose: ((_ opened: Bool) -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opened = false
    private var done = false

    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: Self.url)
        self.task = task
        task.resume()
        receive()
    }

    func send(_ obj: [String: Any]) {
        guard opened, !done, let task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// Our own close: no onClose.
    func close() {
        guard !done else { return }
        done = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                switch result {
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onMessage?(obj)
                    }
                    self.receive()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        session?.invalidateAndCancel()
        onClose?(opened)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard !done else { return }
        opened = true
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}
