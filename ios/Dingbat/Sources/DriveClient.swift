import Foundation

/// One file in the appDataFolder listing.
struct DriveFile {
    var id: String
    var name: String
    var size: Int
    var modifiedTime: String
    var createdTime: String
    /// The generation the file was written for (appProperties.gen; absent 0).
    var gen: Int
}

/// The Drive v3 REST calls the sync makes (web index.js driveFetch and the
/// upload/download helpers). Every call takes the access token from
/// `token()` at send time and, on a 401, asks `renew()` once and replays.
final class DriveClient {
    static var files = "https://www.googleapis.com/drive/v3/files"
    static var upload = "https://www.googleapis.com/upload/drive/v3/files"

    var token: () -> String? = { nil }
    var renew: () async -> Bool = { false }
    /// Thrown between calls when the session that started the work ended.
    var live: () throws -> Void = {}

    struct HTTPError: LocalizedError {
        var status: Int
        var errorDescription: String? { "Drive request failed (HTTP \(status))" }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Authenticated request; one renewal on a 401; rate limits and transient
    /// server errors retried with backoff (web driveRetryWait: any request on
    /// a rate limit, only GET/PATCH on a 5xx, which may have done the work).
    func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:],
               body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        func send() async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.httpMethod = method
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let t = token() { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
            req.httpBody = body
            let (data, res) = try await session.data(for: req)
            return (data, res as! HTTPURLResponse)
        }
        var (data, res) = try await send()
        if res.statusCode == 401 {
            guard await renew() else { throw HTTPError(status: 401) }
            try live()
            (data, res) = try await send()
        }
        var attempt = 0
        while !(200..<300).contains(res.statusCode) && attempt < 3 {
            var limited = res.statusCode == 429
            if res.statusCode == 403,
               let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let errs = (o["error"] as? [String: Any])?["errors"] as? [[String: Any]] {
                limited = errs.contains { ["rateLimitExceeded", "userRateLimitExceeded"].contains($0["reason"] as? String) }
            }
            let transient = [500, 502, 503, 504].contains(res.statusCode) && (method == "GET" || method == "PATCH")
            guard limited || transient else { break }
            var wait = 0.5 * pow(2, Double(attempt)) * (0.75 + Double.random(in: 0..<0.5))
            if let ra = Double(res.value(forHTTPHeaderField: "Retry-After") ?? ""), ra > 0 { wait = min(ra, 10) }
            try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            try live()
            (data, res) = try await send()
            attempt += 1
        }
        guard (200..<300).contains(res.statusCode) else { throw HTTPError(status: res.statusCode) }
        return (data, res)
    }

    /// Every page of the listing.
    func listAll() async throws -> [DriveFile] {
        var out: [DriveFile] = []
        var page: String?
        repeat {
            var c = URLComponents(string: Self.files)!
            var q = [URLQueryItem(name: "spaces", value: "appDataFolder"),
                     URLQueryItem(name: "pageSize", value: "1000"),
                     URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,size,modifiedTime,createdTime,appProperties)")]
            if let page { q.append(URLQueryItem(name: "pageToken", value: page)) }
            c.queryItems = q
            let (data, _) = try await fetch(c.url!)
            try live()
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            for f in o["files"] as? [[String: Any]] ?? [] {
                guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
                let props = f["appProperties"] as? [String: Any]
                let g = Int((props?["gen"] as? String) ?? "") ?? 0
                out.append(DriveFile(id: id, name: name, size: Int((f["size"] as? String) ?? "") ?? 0,
                                     modifiedTime: f["modifiedTime"] as? String ?? "",
                                     createdTime: f["createdTime"] as? String ?? "", gen: max(0, g)))
            }
            page = o["nextPageToken"] as? String
        } while page != nil
        return out
    }

    private static let uploadFields = "id,modifiedTime"

    private func genProps(_ gen: Int, explicitNull: Bool) -> Any? {
        if gen > 0 { return ["gen": String(gen)] }
        return explicitNull ? ["gen": NSNull()] : nil
    }

    private func multipart(_ meta: [String: Any], _ bytes: Data) -> (String, Data) {
        let boundary = "dingbat" + String(Int.random(in: 0..<Int(Int32.max)), radix: 36)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append((try? JSONSerialization.data(withJSONObject: meta)) ?? Data("{}".utf8))
        body.append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(bytes)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        return ("multipart/related; boundary=" + boundary, body)
    }

    /// The modifiedTime Drive stamped a write with.
    private func stamp(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["modifiedTime"] as? String
    }

    /// Create or update a file (web driveUploadFile): bytes and the
    /// generation stamp together where Drive allows (multipart, 5 MB), bytes
    /// first then the stamp for a big file being restamped. Returns Drive's
    /// modifiedTime for the write.
    @discardableResult
    func uploadFile(name: String, bytes: Data, existingID: String?, gen: Int = 0, restamp: Bool = false) async throws -> String? {
        let small = bytes.count <= 4 * 1024 * 1024
        func url(_ base: String, _ q: String) -> URL { URL(string: base + q)! }
        let fieldsQ = "&fields=" + Self.uploadFields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        if let id = existingID {
            if !restamp || !small {
                let (d, _) = try await fetch(url(Self.upload + "/" + id, "?uploadType=media" + fieldsQ), method: "PATCH",
                                             headers: ["Content-Type": "application/octet-stream"], body: bytes)
                if !restamp { return stamp(d) }
                let meta: [String: Any] = ["appProperties": genProps(gen, explicitNull: true)!]
                let (d2, _) = try await fetch(url(Self.files + "/" + id, "?fields=" + Self.uploadFields), method: "PATCH",
                                              headers: ["Content-Type": "application/json"],
                                              body: try JSONSerialization.data(withJSONObject: meta))
                return stamp(d2)
            }
            let meta: [String: Any] = ["appProperties": genProps(gen, explicitNull: true)!]
            let (ct, body) = multipart(meta, bytes)
            let (d, _) = try await fetch(url(Self.upload + "/" + id, "?uploadType=multipart" + fieldsQ), method: "PATCH",
                                         headers: ["Content-Type": ct], body: body)
            return stamp(d)
        }
        var meta: [String: Any] = ["name": name, "parents": ["appDataFolder"]]
        if let p = genProps(gen, explicitNull: false) { meta["appProperties"] = p }
        if small {
            let (ct, body) = multipart(meta, bytes)
            let (d, _) = try await fetch(url(Self.upload, "?uploadType=multipart" + fieldsQ), method: "POST",
                                         headers: ["Content-Type": ct], body: body)
            return stamp(d)
        }
        let (d0, _) = try await fetch(URL(string: Self.files)!, method: "POST",
                                      headers: ["Content-Type": "application/json"],
                                      body: try JSONSerialization.data(withJSONObject: meta))
        guard let id = ((try? JSONSerialization.jsonObject(with: d0)) as? [String: Any])?["id"] as? String else {
            throw HTTPError(status: 0)
        }
        let (d, _) = try await fetch(url(Self.upload + "/" + id, "?uploadType=media" + fieldsQ), method: "PATCH",
                                     headers: ["Content-Type": "application/octet-stream"], body: bytes)
        return stamp(d)
    }

    /// `onBytes` hears the bytes as they land (a tile's progress bar), on the
    /// main queue.
    func download(_ id: String, onBytes: ((Int) -> Void)? = nil) async throws -> Data {
        let url = URL(string: Self.files + "/" + id + "?alt=media")!
        guard let onBytes else { return try await fetch(url).0 }
        // Streamed, for progress. Renewal and retries as fetch().
        var req = URLRequest(url: url)
        if let t = token() { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        var (out, res) = try await Streamed.get(req, timeout: session.configuration.timeoutIntervalForRequest, onBytes: onBytes)
        if (res as? HTTPURLResponse)?.statusCode == 401 {
            guard await renew() else { throw HTTPError(status: 401) }
            try live()
            if let t = token() { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
            (out, res) = try await Streamed.get(req, timeout: session.configuration.timeoutIntervalForRequest, onBytes: onBytes)
        }
        guard let http = res as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return try await fetch(url).0
        }
        return out
    }

    /// One streamed GET: URLSession hands the body over in the chunks it
    /// arrives in, on a queue of its own, into a buffer sized from
    /// Content-Length; progress reaches the main queue every 256 KB. (Reading
    /// a 32 MB ROM a byte at a time through AsyncBytes, on the main actor,
    /// hung the app while the network piled up behind it.)
    private final class Streamed: NSObject, URLSessionDataDelegate {
        private var data = Data()
        private var pending = 0
        private var response: URLResponse?
        private let onBytes: (Int) -> Void
        private var done: CheckedContinuation<(Data, URLResponse), Error>?

        private init(_ onBytes: @escaping (Int) -> Void) { self.onBytes = onBytes }

        static func get(_ req: URLRequest, timeout: TimeInterval,
                        onBytes: @escaping (Int) -> Void) async throws -> (Data, URLResponse) {
            let me = Streamed(onBytes)
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = timeout
            c.waitsForConnectivity = false
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 1
            let s = URLSession(configuration: c, delegate: me, delegateQueue: q)
            defer { s.finishTasksAndInvalidate() }
            let task = s.dataTask(with: req)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    q.addOperation {
                        me.done = cont
                        task.resume()
                    }
                }
            } onCancel: { task.cancel() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response
            let n = response.expectedContentLength
            if n > 0 && n <= 64 << 20 { data.reserveCapacity(Int(n)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            data.append(chunk)
            pending += chunk.count
            if pending >= 256 << 10 { flush() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            flush()
            if let error { done?.resume(throwing: error) }
            else if let response { done?.resume(returning: (data, response)) }
            else { done?.resume(throwing: URLError(.badServerResponse)) }
            done = nil
        }

        private func flush() {
            guard pending > 0 else { return }
            let n = pending, cb = onBytes
            pending = 0
            DispatchQueue.main.async { cb(n) }
        }
    }

    func delete(_ id: String) async throws {
        _ = try await fetch(URL(string: Self.files + "/" + id)!, method: "DELETE")
    }

    /// Metadata-only rename; the new modifiedTime comes back.
    func rename(_ id: String, to name: String) async throws -> String? {
        let (d, _) = try await fetch(URL(string: Self.files + "/" + id + "?fields=id,name,modifiedTime")!,
                                     method: "PATCH", headers: ["Content-Type": "application/json"],
                                     body: try JSONSerialization.data(withJSONObject: ["name": name]))
        return stamp(d)
    }
}
