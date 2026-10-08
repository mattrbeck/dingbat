import Foundation

/// The compact SDP codec of the manual (serverless) code exchange, byte for
/// byte the web's (web/sdputil.js), so a code minted here pastes into a
/// browser and back. Only what differs between peers travels: the DTLS setup
/// role, the SHA-256 fingerprint, ICE ufrag/pwd and the udp candidates;
/// decode() rebuilds a valid SDP from a fixed template.
///
/// Wire format (then base64url, no padding):
///   u8 version (1) · u8 flags (bits 0-1 setup: actpass/active/passive,
///   bit 2 answer) · u8 len + ufrag · u8 len + pwd · 32 B fingerprint ·
///   u8 candidate count · per candidate: u8 (bits 0-1 address kind: IPv4,
///   IPv6, mDNS UUID, hostname; bits 2-3 type: host, srflx, prflx, relay),
///   u32 priority, u16 port, the address (4 / 16 / 16 bytes, or u8 len +
///   UTF-8) · u32 mint time (epoch seconds; older codes lack it).
enum SDPCodec {
    static let version: UInt8 = 1
    private static let setups = ["actpass", "active", "passive"]
    private static let types = ["host", "srflx", "prflx", "relay"]

    struct Candidate {
        let type: String, priority: UInt32, address: String, port: UInt16
    }

    // MARK: encode

    /// Our description as a code, or nil when it lacks what WebRTC needs.
    static func encode(type: String, sdp: String) -> String? {
        guard let ufrag = first(sdp, "a=ice-ufrag:"), let pwd = first(sdp, "a=ice-pwd:"),
              let fpLine = first(sdp, "a=fingerprint:sha-256 "),
              ufrag.utf8.count <= 255, pwd.utf8.count <= 255 else { return nil }
        let fp = fpLine.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard fp.count == 32 else { return nil }
        let setup = first(sdp, "a=setup:") ?? "actpass"
        var cands = candidates(sdp)
        guard !cands.isEmpty else { return nil }
        if cands.count > 255 { cands = Array(cands.prefix(255)) }

        var w: [UInt8] = [version]
        w.append(UInt8(setups.firstIndex(of: setup) ?? 0) | (type == "answer" ? 4 : 0))
        w.append(UInt8(ufrag.utf8.count)); w += Array(ufrag.utf8)
        w.append(UInt8(pwd.utf8.count)); w += Array(pwd.utf8)
        w += fp
        w.append(UInt8(cands.count))
        for c in cands {
            let kind: UInt8
            var addr: [UInt8]
            if isMdns(c.address) { kind = 2; addr = uuidBytes(c.address) }
            else if let v4 = v4Bytes(c.address) { kind = 0; addr = v4 }
            else if c.address.contains(":"), let v6 = v6Bytes(c.address) { kind = 1; addr = v6 }
            else { kind = 3; addr = [UInt8(min(255, c.address.utf8.count))] + Array(c.address.utf8.prefix(255)) }
            w.append(kind | UInt8(types.firstIndex(of: c.type) ?? 0) << 2)
            w += be32(c.priority)
            w += [UInt8(c.port >> 8), UInt8(c.port & 0xff)]
            w += addr
        }
        // The mint time: NAT mappings behind a code decay within a minute,
        // so its age says whether it can still connect.
        w += be32(UInt32(Date().timeIntervalSince1970))
        return Data(w).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: decode

    /// A code back into (type, sdp, mintedAt).
    static func decode(_ code: String) -> (type: String, sdp: String, mintedAt: UInt32?)? {
        var b64 = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let d = [UInt8](data)
        var i = 0
        func u8() throws -> UInt8 { guard i < d.count else { throw Eof() }; i += 1; return d[i - 1] }
        func bytes(_ n: Int) throws -> [UInt8] {
            guard i + n <= d.count else { throw Eof() }
            i += n
            return Array(d[(i - n)..<i])
        }
        func u32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
        func str() throws -> String { String(decoding: try bytes(Int(try u8())), as: UTF8.self) }
        do {
            guard try u8() == version else { return nil }
            let flags = try u8()
            let setup = setups[Int(flags & 3) < 3 ? Int(flags & 3) : 0]
            let kind = (flags >> 2) & 1 == 1 ? "answer" : "offer"
            let ufrag = try str(), pwd = try str()
            let fp = try bytes(32).map { String(format: "%02X", $0) }.joined(separator: ":")
            let n = Int(try u8())
            var lines: [String] = []
            for k in 0..<n {
                let cb = try u8()
                let ctype = types[Int((cb >> 2) & 3)]
                let priority = try u32()
                let port = UInt16(try u8()) << 8 | UInt16(try u8())
                let addr: String
                switch cb & 3 {
                case 0: addr = try bytes(4).map(String.init).joined(separator: ".")
                case 1:
                    let b = try bytes(16)
                    addr = (0..<8).map { String(UInt16(b[$0 * 2]) << 8 | UInt16(b[$0 * 2 + 1]), radix: 16) }
                        .joined(separator: ":")
                case 2: addr = uuidString(try bytes(16))
                default: addr = try str()
                }
                // Foundation regenerated per index; srflx and relay get a
                // placeholder raddr/rport.
                let rel = ctype == "srflx" || ctype == "relay" ? " raddr 0.0.0.0 rport 0" : ""
                lines.append("a=candidate:\(k + 1) 1 udp \(priority) \(addr) \(port) typ \(ctype)\(rel) generation 0")
            }
            guard !ufrag.isEmpty, !pwd.isEmpty, !lines.isEmpty else { return nil }
            let sdp =
                "v=0\r\n" +
                "o=- 4611686018427387904 2 IN IP4 127.0.0.1\r\n" +
                "s=-\r\n" +
                "t=0 0\r\n" +
                "a=group:BUNDLE 0\r\n" +
                "a=extmap-allow-mixed\r\n" +
                "a=msid-semantic: WMS\r\n" +
                "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" +
                "c=IN IP4 0.0.0.0\r\n" +
                lines.map { $0 + "\r\n" }.joined() +
                "a=ice-ufrag:" + ufrag + "\r\n" +
                "a=ice-pwd:" + pwd + "\r\n" +
                "a=ice-options:trickle\r\n" +
                "a=fingerprint:sha-256 " + fp + "\r\n" +
                "a=setup:" + setup + "\r\n" +
                "a=mid:0\r\n" +
                "a=sctp-port:5000\r\n" +
                "a=max-message-size:262144\r\n"
            let minted = d.count - i >= 4 ? try u32() : nil
            return (kind, sdp, minted)
        } catch {
            return nil
        }
    }

    /// The friend's offer code rewritten as the answer to our own offer (the
    /// exchange is symmetric: both sides offer). `setup` is "active" on the
    /// side that will be the DTLS server, "passive" on the other, from a
    /// comparison both sides compute.
    static func answerFrom(_ code: String, setup: String) -> String? {
        guard setup == "active" || setup == "passive", let d = decode(code) else { return nil }
        return d.sdp.replacingOccurrences(of: #"a=setup:\S+"#, with: "a=setup:" + setup,
                                          options: .regularExpression)
    }

    /// "srflx/v4 host/mdns" for the log: srflx = reachable over the
    /// internet; host only = this network only.
    static func candidateKinds(_ sdp: String) -> [String] {
        candidates(sdp).map { c in
            c.type + (c.address.contains(":") ? "/v6" : c.address.hasSuffix(".local") ? "/mdns" : "/v4")
        }
    }

    // MARK: helpers

    private struct Eof: Error {}

    private static func first(_ sdp: String, _ prefix: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix(prefix) {
            let v = line.dropFirst(prefix.count).split(separator: " ").first.map(String.init) ?? ""
            return v.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The udp candidates; scoped IPv6 (link-local "%en0") cannot travel.
    static func candidates(_ sdp: String) -> [Candidate] {
        sdp.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("a=candidate:") else { return nil }
            let t = line.dropFirst(12).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 8, t[2].lowercased() == "udp", t[6] == "typ", types.contains(t[7]),
                  let pri = UInt32(t[3]), let port = UInt16(t[5]), !t[4].contains("%") else { return nil }
            return Candidate(type: t[7], priority: pri, address: t[4], port: port)
        }
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private static func isMdns(_ h: String) -> Bool {
        h.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.local$"#,
                options: .regularExpression) != nil
    }

    private static func uuidBytes(_ h: String) -> [UInt8] {
        let hex = Array(h.split(separator: ".")[0].replacingOccurrences(of: "-", with: ""))
        return (0..<16).map { UInt8(String(hex[$0 * 2 ... $0 * 2 + 1]), radix: 16) ?? 0 }
    }

    private static func uuidString(_ b: [UInt8]) -> String {
        let s = b.map { String(format: "%02x", $0) }.joined()
        let c = Array(s)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32])).local"
    }

    private static func v4Bytes(_ h: String) -> [UInt8]? {
        let p = h.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        let b = p.compactMap { Int($0) }
        guard b.count == 4, b.allSatisfy({ (0...999).contains($0) }) else { return nil }
        return b.map { UInt8($0 & 0xff) }
    }

    private static func v6Bytes(_ h: String) -> [UInt8]? {
        var head: [Substring], tail: [Substring] = []
        if let r = h.range(of: "::") {
            head = h[..<r.lowerBound].split(separator: ":")
            tail = h[r.upperBound...].split(separator: ":")
        } else {
            head = h.split(separator: ":", omittingEmptySubsequences: false)
        }
        let fill = 8 - head.count - tail.count
        guard fill >= 0 else { return nil }
        let groups = (head + Array(repeating: "0", count: fill) + tail).map { UInt16($0.isEmpty ? "0" : $0, radix: 16) ?? 0 }
        return groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
    }
}
