import Foundation

/// WebSocket signaling client. Speaks the SAME protocol as the web listener
/// (see src/signaling.js): we connect to ws://<mac-ip>:<port>/ws, send
/// {type:"hello", role:"listener"}, and relay opaque {type:"signal", ...}
/// payloads (SDP / ICE) to and from the broadcaster. Messages are passed as
/// dictionaries because the `data` field is polymorphic (sdp | candidate).
final class Signaling: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var closedByUs = false
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(url: URL) { self.url = url; super.init() }

    func connect() {
        closedByUs = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func send(_ obj: [String: Any]) {
        guard let task = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { _ in }
    }

    func close() {
        closedByUs = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                if !self.closedByUs { DispatchQueue.main.async { self.onClose?() } }
            case .success(let message):
                if case let .string(s) = message,
                   let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(obj) }
                }
                self.receiveLoop()
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        DispatchQueue.main.async { self.onOpen?() }
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !closedByUs { DispatchQueue.main.async { self.onClose?() } }
    }
}
