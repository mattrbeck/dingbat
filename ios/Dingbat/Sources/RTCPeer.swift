import Foundation

/// One WebRTC peer connection with the "link" data channel (the web's
/// RTCPeerConnection + RTCDataChannel), over libdatachannel's C API
/// (ios/build-webrtc.sh). libdatachannel calls back on its own threads; every
/// event is handed to the main queue, and nothing arrives after close().
final class RTCPeer {
    private(set) var pc: Int32 = -1
    private(set) var dc: Int32 = -1
    private var closed = false

    var onLocalDescription: ((_ sdp: String, _ type: String) -> Void)?
    var onLocalCandidate: ((_ candidate: String, _ mid: String) -> Void)?
    /// "connecting", "connected", "disconnected", "failed", "closed".
    var onState: ((String) -> Void)?
    var onOpen: (() -> Void)?
    var onClosed: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onBufferedLow: (() -> Void)?

    /// `offerer`: create the channel (and with it the offer); the answerer
    /// waits for the friend's.
    init?(iceServers: [String], offerer: Bool) {
        var urls = iceServers.map { strdup($0) }
        defer { urls.forEach { free($0) } }
        var config = rtcConfiguration()
        let pc: Int32 = urls.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                config.iceServers = p
                config.iceServersCount = Int32(buf.count)
                return rtcCreatePeerConnection(&config)
            }
        }
        guard pc >= 0 else { return nil }
        self.pc = pc
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Callbacks fire only once a user pointer is set.
        rtcSetUserPointer(pc, me)
        rtcSetLocalDescriptionCallback(pc) { _, sdp, type, ptr in
            guard let ptr, let sdp, let type else { return }
            let (s, t) = (String(cString: sdp), String(cString: type))
            RTCPeer.from(ptr).post { $0.onLocalDescription?(s, t) }
        }
        rtcSetLocalCandidateCallback(pc) { _, cand, mid, ptr in
            guard let ptr, let cand else { return }
            let c = String(cString: cand)
            let m = mid.map { String(cString: $0) } ?? "0"
            RTCPeer.from(ptr).post { $0.onLocalCandidate?(c, m) }
        }
        rtcSetStateChangeCallback(pc) { _, state, ptr in
            guard let ptr else { return }
            let name: String
            switch state {
            case RTC_CONNECTING: name = "connecting"
            case RTC_CONNECTED: name = "connected"
            case RTC_DISCONNECTED: name = "disconnected"
            case RTC_FAILED: name = "failed"
            case RTC_CLOSED: name = "closed"
            default: name = "new"
            }
            RTCPeer.from(ptr).post { $0.onState?(name) }
        }
        if offerer {
            var init_ = rtcDataChannelInit()  // reliable and ordered
            let dc = rtcCreateDataChannelEx(pc, "link", &init_)
            guard dc >= 0 else { rtcDeletePeerConnection(pc); return nil }
            wire(dc)
        } else {
            rtcSetDataChannelCallback(pc) { _, dc, ptr in
                guard let ptr else { return }
                let peer = RTCPeer.from(ptr)
                // Wired here, on libdatachannel's thread: the channel may open
                // before the main queue gets to it.
                if peer.dc < 0 && !peer.closed { peer.wire(dc) }
                if rtcIsOpen(dc) { peer.post { $0.onOpen?() } }
            }
        }
    }

    private static func from(_ ptr: UnsafeMutableRawPointer) -> RTCPeer {
        Unmanaged<RTCPeer>.fromOpaque(ptr).takeUnretainedValue()
    }

    /// On the main queue, unless closed by then. The peer is kept alive by
    /// its owner; close() blocks until no callback is running.
    private func post(_ f: @escaping (RTCPeer) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            f(self)
        }
    }

    private func wire(_ dc: Int32) {
        self.dc = dc
        rtcSetUserPointer(dc, Unmanaged.passUnretained(self).toOpaque())
        rtcSetOpenCallback(dc) { _, ptr in
            guard let ptr else { return }
            RTCPeer.from(ptr).post { $0.onOpen?() }
        }
        rtcSetClosedCallback(dc) { _, ptr in
            guard let ptr else { return }
            RTCPeer.from(ptr).post { $0.onClosed?() }
        }
        rtcSetMessageCallback(dc) { _, msg, size, ptr in
            // size < 0 is a text message; the link speaks binary only.
            guard let ptr, let msg, size >= 0 else { return }
            let data = Data(bytes: msg, count: Int(size))
            RTCPeer.from(ptr).post { $0.onMessage?(data) }
        }
        rtcSetBufferedAmountLowCallback(dc) { _, ptr in
            guard let ptr else { return }
            RTCPeer.from(ptr).post { $0.onBufferedLow?() }
        }
    }

    var isOpen: Bool { dc >= 0 && !closed && rtcIsOpen(dc) }

    func setRemoteDescription(sdp: String, type: String) -> Bool {
        !closed && rtcSetRemoteDescription(pc, sdp, type) >= 0
    }

    func addRemoteCandidate(_ candidate: String, mid: String?) {
        guard !closed, !candidate.isEmpty else { return }
        _ = rtcAddRemoteCandidate(pc, candidate, mid ?? "0")
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard isOpen else { return false }
        return data.withUnsafeBytes { raw in
            rtcSendMessage(dc, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(data.count)) >= 0
        }
    }

    var bufferedAmount: Int { dc >= 0 && !closed ? Int(max(0, rtcGetBufferedAmount(dc))) : 0 }

    func setBufferedLowThreshold(_ n: Int) {
        if dc >= 0 && !closed { rtcSetBufferedAmountLowThreshold(dc, Int32(n)) }
    }

    /// Close and free. Blocks until libdatachannel has finished any callback
    /// in flight, so it must not run on one of its threads.
    func close() {
        guard !closed else { return }
        closed = true
        if dc >= 0 { rtcClose(dc); rtcDelete(dc) }
        if pc >= 0 { rtcClosePeerConnection(pc); rtcDeletePeerConnection(pc) }
    }

    deinit { close() }
}
