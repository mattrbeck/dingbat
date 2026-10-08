import Foundation
import Network
import SwiftUI

/// Online link play (web/netplay.js): both players type the same code, the
/// signaling server pairs them, and a WebRTC data channel carries the game.
/// Input rollback (the web's only online path): each side runs both
/// players' cores and only per-frame buttons cross the network, so an iPhone
/// and a browser link as two browsers do.
///
/// Wire protocol, first byte = kind, big-endian (web RB_*):
///   0 hello [epoch u32][romHash u32][len u32][crc32 u32][fnv u32]
///   1 input [frame i32][bits u16]
///   2 state-begin [len u32]            3 state-chunk [bytes]
///   4 rom-begin [len u32]              5 rom-chunk [bytes]
///   6 ready   7 speed [on u8]   8 pause [on u8]   9 have-rom   10 need-rom
/// Core 0 is the host's game, core 1 the guest's. When the ROMs differ (a
/// cross-game trade) each side also needs the other's: a side whose hello
/// names its whole ROM answers the friend's with have-rom (it is in the
/// library, so it is not sent) or need-rom, and a ROM goes over only on
/// need-rom; to an older build (a 9-byte hello, no answer) it goes at once.
///
/// With the server unreachable (or by choice) the manual exchange pairs
/// instead: each side mints a code holding its whole description
/// (SDPCodec), sends it any way it likes and pastes the friend's.
///
/// Left out from the web: the same-browser BroadcastChannel path.
final class NetLink: ObservableObject {
    static let shared = NetLink()

    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    /// Dialing or waiting: the spinner, and Connect reads Cancel.
    @Published private(set) var connecting = false
    /// The session runs: the game ticks linked.
    @Published private(set) var linked = false
    /// The manual exchange is on screen instead of the shared code.
    @Published private(set) var manualView = false
    /// Our code, nil while it is being minted.
    @Published private(set) var manualCode: String?
    /// The friend's code field, and whether it is locked in (confirmed).
    @Published var friendCode = ""
    @Published private(set) var friendLocked = false

    /// The session owns the core (from rollback_init, before it starts).
    var holdsCore: Bool { session?.rb?.inited == true }
    /// This side's player in the session (0 hosts), once there is one.
    var localPlayer: Int? { session?.rb?.localPlayer }

    // web NET_ICE_SERVERS, timings
    static let iceServers = ["stun:stun.l.google.com:19302"]
    static let dialTimeout: TimeInterval = 4
    static let rendezvousTimeout: TimeInterval = 2
    static let redialDelays: [TimeInterval] = [1, 2, 4]
    static let rtcDeadline: TimeInterval = 20
    /// Manual codes: ICE gathering's cap once a public address is in hand,
    /// and without one (cellular STUN can be slow); a code's useful life.
    static let gatherTimeout: TimeInterval = 3.5
    static let gatherExtended: TimeInterval = 8
    static let codeMaxAge: TimeInterval = 45

    /// Sent with every rendezvous: the server drops a stale seat of ours
    /// instead of pairing us with it (web NET_PAGE_ID).
    private static let pageID: String = (0..<4).map { _ in
        String(format: "%08x", UInt32.random(in: 0 ... .max))
    }.joined()

    private final class Session {
        var code = ""
        var ws: LinkSignaling?
        var peer: RTCPeer?
        var isHost: Bool?
        var rtcConnected = false
        var sdpIn = false
        var strikes = 0
        var rewaited = false
        var redials = 0
        var started = false
        var timer: DispatchWorkItem?
        var rb: RB?
        var manual = false
    }

    private final class RB {
        var localPlayer = 0
        var epoch: UInt32 = 0
        var ext = ".gba"
        var gamePath = ""
        var romBytes = Data()
        var romHash: UInt32 = 0
        var romId = RomIdentity(len: 0, crc: 0, fnv: 0)
        var remoteRomId: RomIdentity?
        /// The friend's ROM came from this library; ours is already theirs.
        var romFromLibrary = false
        var friendHasRom = false
        var localState = Data()
        var remoteState: Data?
        var stateBuf = Data()
        var stateLen = 0
        var remoteHello = false
        var needRom = false
        var remoteRomHash: UInt32 = 0
        var remoteRomLen = 0
        var romBuf = Data()
        var remoteRom: Data?
        var romSent = 0
        var romSendStarted = false
        var localReady = false
        var remoteReady = false
        var inited = false
    }

    private var session: Session?

    /// The server's last known liveness (nil: never tried): an open sheet
    /// goes straight to the manual exchange when it was last seen down.
    private var serverUp: Bool?
    private var probeAt = Date.distantPast
    private var online = true
    private let pathMonitor = NWPathMonitor()
    private var codeShared = false
    private var freshTimer: DispatchWorkItem?
    private var hiddenAt = Date()

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.online = path.status == .satisfied }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hiddenAt = Date()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.cameBack()
        }
    }

    private var sheetUp: Bool {
        if case .link = AppModel.shared.sheet { return true }
        return false
    }

    // web RB_* kinds
    private static let hello: UInt8 = 0, input: UInt8 = 1, stateBegin: UInt8 = 2, stateChunk: UInt8 = 3
    private static let romBegin: UInt8 = 4, romChunk: UInt8 = 5, ready: UInt8 = 6, speed: UInt8 = 7, pause: UInt8 = 8
    private static let haveRom: UInt8 = 9, needRom: UInt8 = 10
    private static let helloLen = 21  // with the whole-ROM identity
    private static let chunk = 16384
    private static let highWater = 4 * 1024 * 1024
    private static let romMax = 48 * 1024 * 1024

    // MARK: the sheet

    /// A fresh connect sheet (web openNetConnect): the game is frozen while
    /// it is up (AppModel.openSheet pauses it).
    func openSheet() {
        if session != nil { shutdown(keepSheet: true) }
        setStatus("")
        connecting = false
        resetManual()
        AppModel.shared.openSheet(.link)
        // The screen stays on while the sheet is up: an auto-lock suspends
        // the app and kills the NAT mappings behind the wait.
        UIApplication.shared.isIdleTimerDisabled = true
        if serverUp == false && online {
            NSLog("netlink: last probe saw the server down — opening onto the manual exchange")
            probeServer(force: true)
            enterManual(attemptFailed: false)
        } else {
            probeServer()
        }
    }

    /// The sheet's Connect button; while connecting it reads Cancel.
    func connectTapped(code raw: String) {
        if connecting {
            dismiss()
            return
        }
        let code = raw.uppercased().filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        guard code.count >= 3 else {
            setStatus("Pick a code of at least 3 letters/numbers", error: true)
            return
        }
        guard GameSession.shared.game != nil else { return }
        let s = Session()
        s.code = code
        session = s
        connecting = true
        setStatus("Connecting…")
        dial(s)
    }

    /// The sheet went away: a session that has not started ends with it.
    func sheetClosed() {
        if let s = session, !s.started { shutdown(keepSheet: true) }
        connecting = false
        resetManual()
        let gs = GameSession.shared
        UIApplication.shared.isIdleTimerDisabled = gs.game != nil && !gs.paused
    }

    private func dismiss() {
        if let s = session, !s.started { shutdown(keepSheet: true) }
        if case .link = AppModel.shared.sheet { AppModel.shared.sheet = nil }
    }

    /// Liveness probe (web probeSignalServer): at most every 30 s.
    private func probeServer(force: Bool = false) {
        guard force || Date().timeIntervalSince(probeAt) >= 30 else { return }
        probeAt = Date()
        let ws = LinkSignaling()
        var settled = false
        let timeout = DispatchWorkItem { [weak self] in
            guard !settled else { return }
            settled = true
            self?.serverUp = false
            ws.close()
        }
        ws.onOpen = { [weak self] in
            guard !settled else { return }
            settled = true
            timeout.cancel()
            self?.serverUp = true
            ws.close()
        }
        ws.onClose = { [weak self] _ in
            guard !settled else { return }
            settled = true
            timeout.cancel()
            self?.serverUp = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        ws.connect()
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
        if error { connecting = false }
    }

    // MARK: signaling

    private func dial(_ s: Session) {
        let ws = LinkSignaling()
        s.ws = ws
        ws.onOpen = { [weak self] in
            guard let self, self.session === s, s.ws === ws else { return }
            self.serverUp = true
            ws.send(["t": "rendezvous", "code": s.code, "id": Self.pageID])
            // No answer in time: the manual exchange instead.
            self.arm(s, after: Self.rendezvousTimeout) { [weak self] in
                self?.serverUp = false
                self?.enterManual(attemptFailed: true)
            }
        }
        ws.onClose = { [weak self] opened in
            guard let self, self.session === s, s.ws === ws else { return }
            s.ws = nil
            if !opened && s.redials == 0 && !s.rewaited {
                self.serverUp = false
                self.fail("Couldn't reach the linking server — check your connection")
                return
            }
            // A drop while waiting: the room died with it, so redial and
            // rendezvous again (a linked session no longer needs the server;
            // a pairing in flight is the deadline's to resolve).
            if s.rtcConnected || s.started || s.peer != nil { return }
            self.redial(s)
        }
        ws.onMessage = { [weak self] msg in
            guard let self, self.session === s, s.ws === ws else { return }
            self.onSignal(msg, s)
        }
        arm(s, after: Self.dialTimeout) { [weak self] in
            self?.serverUp = false
            self?.enterManual(attemptFailed: true)
        }
        ws.connect()
    }

    private func redial(_ s: Session) {
        let attempt = s.redials
        s.redials += 1
        guard attempt < Self.redialDelays.count else {
            serverUp = false
            enterManual(attemptFailed: true)
            return
        }
        setStatus("Reconnecting to the linking server…")
        arm(s, after: Self.redialDelays[attempt]) { [weak self] in
            guard let self, self.session === s, s.peer == nil, !s.started else { return }
            self.dial(s)
        }
    }

    /// One timer per session at a time (dial, rendezvous, redial, pairing).
    private func arm(_ s: Session, after t: TimeInterval, _ f: @escaping () -> Void) {
        s.timer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard self?.session === s else { return }
            f()
        }
        s.timer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    private func onSignal(_ msg: [String: Any], _ s: Session) {
        // Any reply is proof of life.
        s.timer?.cancel()
        s.redials = 0
        serverUp = true
        switch msg["t"] as? String {
        case "waiting":
            setStatus("Waiting for your friend…")
        case "paired":
            s.isHost = (msg["role"] as? String) == "host"
            setStatus("Friend found — connecting…")
            startRtc(s)
        case "sdp":
            guard let peer = s.peer, let d = msg["d"] as? [String: Any],
                  let sdp = d["sdp"] as? String, let type = d["type"] as? String else { return }
            s.sdpIn = true
            // The answer, if this was an offer, comes back by itself.
            if !peer.setRemoteDescription(sdp: sdp, type: type) {
                fail("Connection setup failed")
            }
        case "ice":
            guard let peer = s.peer, let c = msg["c"] as? [String: Any],
                  let cand = c["candidate"] as? String else { return }
            peer.addRemoteCandidate(cand, mid: c["sdpMid"] as? String)
        case "peer-closed":
            if s.rtcConnected { return }
            // With the descriptions crossed the friend has most likely linked
            // and left the server a moment before our channel opens.
            if s.sdpIn { return }
            rewait(s, "friend left before pairing")
        case "error":
            fail((msg["msg"] as? String) ?? "Connection error")
        default:
            break
        }
    }

    /// This pairing ended before linking but the friend may still come: drop
    /// it and rendezvous again on the same code (web sigRewait).
    private func rewait(_ s: Session, _ why: String) {
        guard session === s, !s.rtcConnected, !s.started else { return }
        NSLog("netlink: %@ — back to waiting", why)
        s.peer?.close()
        s.peer = nil
        s.isHost = nil
        s.sdpIn = false
        s.rewaited = true
        s.ws?.close()
        s.ws = nil
        if s.redials >= Self.redialDelays.count {
            serverUp = false
            enterManual(attemptFailed: true)
            return
        }
        s.redials += 1
        setStatus("Waiting for your friend…")
        dial(s)
    }

    // MARK: WebRTC

    private func startRtc(_ s: Session) {
        guard let isHost = s.isHost, let peer = RTCPeer(iceServers: Self.iceServers, offerer: isHost) else {
            fail("Couldn't start the connection")
            return
        }
        s.peer = peer
        s.sdpIn = false
        arm(s, after: Self.rtcDeadline) { [weak self] in
            self?.rtcGaveUp(s, "no link \(Int(Self.rtcDeadline)) s after pairing")
        }
        peer.onLocalDescription = { [weak s] sdp, type in
            s?.ws?.send(["t": "sdp", "d": ["type": type, "sdp": sdp]])
        }
        peer.onLocalCandidate = { [weak s] cand, mid in
            s?.ws?.send(["t": "ice", "c": ["candidate": cand, "sdpMid": mid, "sdpMLineIndex": 0]])
        }
        wire(peer, s)
    }

    /// The channel's events, for either pairing path.
    private func wire(_ peer: RTCPeer, _ s: Session) {
        peer.onState = { [weak self] st in
            guard let self, self.session === s, s.peer === peer else { return }
            if st == "failed" {
                if s.rtcConnected { self.fail("Peer connection lost") }
                else if s.manual { self.manualFailed() }
                else { self.rtcGaveUp(s, "ICE failed") }
            } else if (st == "disconnected" || st == "closed") && s.started {
                self.peerGone("Peer connection lost")
            }
        }
        peer.onOpen = { [weak self] in
            guard let self, self.session === s, s.peer === peer, !s.rtcConnected else { return }
            s.rtcConnected = true
            s.timer?.cancel()
            // Linked: closing the socket releases our room on the server.
            s.ws?.close()
            s.ws = nil
            self.setStatus("Connected — linking…")
            self.rbConnect(s)
        }
        peer.onClosed = { [weak self] in
            guard let self, self.session === s else { return }
            if s.started { self.peerGone("Peer disconnected") }
            else if s.rb != nil && s.rb?.inited == false { self.fail("Connection lost during setup") }
        }
        peer.onMessage = { [weak self] data in
            guard let self, self.session === s else { return }
            self.rbMessage(data, s)
        }
        peer.onBufferedLow = { [weak self] in
            guard let self, self.session === s else { return }
            self.pumpRom(s)
        }
    }

    /// The pairing deadline or ICE giving up: two crossed pairings that never
    /// opened are the NAT verdict; otherwise wait for the friend again.
    private func rtcGaveUp(_ s: Session, _ why: String) {
        guard session === s, !s.rtcConnected, !s.started else { return }
        if s.sdpIn {
            s.strikes += 1
            if s.strikes >= 2 {
                fail("Could not connect peer-to-peer (a strict NAT on one side may be blocking it)")
                return
            }
        }
        rewait(s, why)
    }

    // MARK: the manual exchange

    /// Switch the sheet to the manual exchange (web manualEnter).
    /// `attemptFailed`: a live attempt found the server unreachable.
    func enterManual(attemptFailed: Bool) {
        guard sheetUp, !manualView else { return }
        guard online else {
            setStatus("No network connection — join the same Wi-Fi as your friend and retry", error: true)
            return
        }
        if let s = session {
            guard !s.rtcConnected, !s.started else { return }
            s.timer?.cancel()
            s.ws?.close()
            s.ws = nil
        }
        if attemptFailed { NSLog("netlink: server attempt failed — switching to the manual code exchange") }
        connecting = false
        setStatus(attemptFailed ? "Couldn't connect — the linking server didn't respond" : "", error: attemptFailed)
        manualView = true
        prepareManual(keepFriendBox: false)
    }

    /// Back to the shared code; the prepared offer is dropped.
    func manualBack() {
        if let s = session, s.rtcConnected || s.started { return }
        shutdown(keepSheet: true)
        resetManual()
        setStatus("")
    }

    private func resetManual() {
        manualView = false
        manualCode = nil
        friendCode = ""
        friendLocked = false
        codeShared = false
        freshTimer?.cancel()
    }

    /// Mint our code: an offer with ICE gathered to the end (nothing can
    /// trickle), encoded. It waits unwired for which side we turn out to be.
    private func prepareManual(keepFriendBox: Bool) {
        let s = session ?? Session()
        session = s
        s.manual = true
        s.peer?.close()
        s.peer = nil
        manualCode = nil
        codeShared = false
        freshTimer?.cancel()
        if !keepFriendBox {
            friendCode = ""
            friendLocked = false
        }
        guard let peer = RTCPeer(iceServers: Self.iceServers, offerer: true, manual: true) else {
            setStatus("Couldn't prepare a code: the connection could not be made", error: true)
            return
        }
        s.peer = peer
        wire(peer, s)
        let t0 = CACurrentMediaTime()
        var sawSrflx = false
        var done = false
        let finish = { [weak self] in
            guard let self, !done, self.session === s, s.peer === peer else { return }
            done = true
            guard let d = peer.localDescription, let code = SDPCodec.encode(type: d.type, sdp: d.sdp) else {
                self.setStatus("Couldn't prepare a code: couldn't encode the offer", error: true)
                return
            }
            self.manualCode = code
            let kinds = SDPCodec.candidateKinds(d.sdp)
            NSLog("netlink: manual code minted in %dms: %@", Int((CACurrentMediaTime() - t0) * 1000),
                  kinds.isEmpty ? "no candidates" : kinds.joined(separator: " "))
            if !kinds.contains(where: { $0.hasPrefix("srflx") }) {
                NSLog("netlink: manual code has no public address — it can only pair on this network")
            }
            self.armFresh(s)
            #if DEBUG
            self.debugCodeMinted(code)
            #endif
        }
        peer.onLocalCandidate = { cand, _ in if cand.contains(" srflx ") { sawSrflx = true } }
        peer.onGatheringComplete = { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gatherTimeout) { if sawSrflx { finish() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gatherExtended) { finish() }
    }

    /// NAT mappings behind a code decay within a minute: an unshared code is
    /// minted again before then. A shared one is kept (the friend has it).
    private func armFresh(_ s: Session) {
        freshTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.session === s, !self.codeShared, !s.rtcConnected, self.manualView,
                  self.friendCode.isEmpty, !self.friendLocked else { return }
            self.prepareManual(keepFriendBox: true)
        }
        freshTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.codeMaxAge, execute: w)
    }

    /// Back in the foreground: an unshared code is minted again quietly; a
    /// shared one only after long enough away for it to have died.
    private func cameBack() {
        guard sheetUp else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        guard manualView, let s = session, !s.rtcConnected, !s.started, !friendLocked,
              manualCode != nil else { return }
        if !codeShared {
            prepareManual(keepFriendBox: true)
        } else if Date().timeIntervalSince(hiddenAt) > Self.codeMaxAge {
            prepareManual(keepFriendBox: true)
            setStatus("Away a while — your code was refreshed, share the new one")
        }
    }

    func copyCode() {
        guard let code = manualCode else { return }
        codeShared = true
        freshTimer?.cancel()
        UIPasteboard.general.string = code
        AppModel.shared.toast("Code copied")
    }

    /// The share sheet with the bare code: whatever the friend pastes back
    /// must decode.
    func shareCode() {
        guard let code = manualCode else { return }
        codeShared = true
        freshTimer?.cancel()
        Share.present([code])
    }

    /// Confirm: the friend's code becomes the answer to our offer, on both
    /// sides; comparing the two codes picks the DTLS roles and the host seat.
    func confirmManual() {
        guard let s = session, let peer = s.peer, let mine = manualCode, !friendLocked else { return }
        let friend = friendCode.filter { !$0.isWhitespace }
        guard !friend.isEmpty else { return }
        if friend == mine {
            setStatus("That's your own code — paste your friend's", error: true)
            return
        }
        if let fd = SDPCodec.decode(friend) {
            let age = fd.mintedAt.map { "\(max(0, Int(Date().timeIntervalSince1970) - Int($0)))s old" } ?? "age unknown"
            NSLog("netlink: friend's code: %@ — %@", SDPCodec.candidateKinds(fd.sdp).joined(separator: " "), age)
        }
        // Byte order, as the browser compares its strings.
        let isHost = friend.utf8.lexicographicallyPrecedes(mine.utf8)
        guard let remote = SDPCodec.answerFrom(friend, setup: isHost ? "active" : "passive") else {
            setStatus("That code didn't read cleanly — recopy it and try again", error: true)
            return
        }
        s.isHost = isHost
        if isHost { peer.useOwnChannel() } else { peer.useFriendsChannel() }
        guard peer.setRemoteDescription(sdp: remote, type: "answer") else {
            setStatus("Pairing failed: the code was refused", error: true)
            return
        }
        friendLocked = true
        freshTimer?.cancel()
        setStatus("Connecting…")
        // A list with nothing routable leaves ICE checking forever.
        arm(s, after: Self.rtcDeadline) { [weak self] in
            NSLog("netlink: manual pairing deadline — no connection in %ds", Int(Self.rtcDeadline))
            self?.manualFailed()
        }
    }

    /// The traded codes are spent with the connection: both sides fail
    /// together, so both mint again together.
    private func manualFailed() {
        fail("Couldn't connect with those codes")
        if manualView && sheetUp {
            setStatus("Couldn't connect — trade these fresh codes and try again", error: true)
        }
    }

    #if DEBUG
    /// `-link-manual`: the manual exchange, with our code written to
    /// tmp/linkcode.txt and the friend's read from tmp/friendcode.txt
    /// (ios/e2e/link.mjs).
    func debugManual() {
        openSheet()
        enterManual(attemptFailed: false)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let theirs = tmp.appendingPathComponent("friendcode.txt")
        try? FileManager.default.removeItem(at: theirs)
        func poll() {
            if let code = try? String(contentsOf: theirs, encoding: .utf8), !code.isEmpty, manualCode != nil {
                friendCode = code
                confirmManual()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
        }
        poll()
    }

    private func debugCodeMinted(_ code: String) {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkcode.txt")
        try? code.write(to: f, atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: rollback setup

    private static func fnv1a(_ d: Data) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        d.prefix(1 << 20).forEach { h = (h ^ UInt32($0)) &* 0x01000193 }
        return h
    }

    private func send(_ bytes: [UInt8], _ s: Session) { s.peer?.send(Data(bytes)) }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private static func read32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    private func rbConnect(_ s: Session) {
        let gs = GameSession.shared
        guard let game = gs.game, let rom = try? Data(contentsOf: game.url),
              let state = gs.captureState() else {
            fail("Couldn't start the session: no game to link")
            return
        }
        // Frozen at the snapshot so the game cannot run past it.
        if !gs.paused { gs.setPaused(true) }
        let rb = RB()
        rb.localPlayer = s.isHost == true ? 0 : 1
        rb.epoch = s.isHost == true ? UInt32(Date().timeIntervalSince1970) : 0
        rb.ext = "." + game.ext
        rb.gamePath = game.coreURL.path
        rb.romBytes = rom
        rb.romHash = Self.fnv1a(rom)
        rb.romId = RomIdentity(rom)
        rb.localState = state
        s.rb = rb
        setStatus("Syncing…")
        send([Self.hello] + Self.be32(rb.epoch) + Self.be32(rb.romHash)
             + Self.be32(rb.romId.len) + Self.be32(rb.romId.crc) + Self.be32(rb.romId.fnv), s)
        send([Self.stateBegin] + Self.be32(UInt32(state.count)), s)
        var off = 0
        while off < state.count {
            let end = min(off + Self.chunk, state.count)
            var frame = Data([Self.stateChunk])
            frame.append(state[(state.startIndex + off) ..< (state.startIndex + end)])
            s.peer?.send(frame)
            off = end
        }
    }

    /// ROM streaming with backpressure (web rbSendRom): chunks while the
    /// send buffer is under the high water, the rest on bufferedAmountLow.
    private func pumpRom(_ s: Session) {
        guard let rb = s.rb, rb.romSendStarted, let peer = s.peer, rb.romSent < rb.romBytes.count else { return }
        while rb.romSent < rb.romBytes.count && peer.bufferedAmount <= Self.highWater {
            let end = min(rb.romSent + Self.chunk, rb.romBytes.count)
            var frame = Data([Self.romChunk])
            frame.append(rb.romBytes[(rb.romBytes.startIndex + rb.romSent) ..< (rb.romBytes.startIndex + end)])
            guard peer.send(frame) else { return }
            rb.romSent = end
        }
        showTransfer(rb)
    }

    private func sendOurRom(_ s: Session) {
        guard let rb = s.rb, !rb.romSendStarted else { return }
        rb.romSendStarted = true
        s.peer?.setBufferedLowThreshold(Self.highWater)
        send([Self.romBegin] + Self.be32(UInt32(rb.romBytes.count)), s)
        pumpRom(s)
    }

    private func showTransfer(_ rb: RB) {
        guard rb.needRom else { return }
        // The friend's ROM is estimated at ours until its rom-begin lands.
        let total = rb.romBytes.count + (rb.remoteRomLen > 0 ? rb.remoteRomLen : rb.romBytes.count)
        guard total > 0 else { return }
        let pct = min(100, (rb.romSent + rb.romBuf.count + (rb.remoteRom?.count ?? 0)) * 100 / total)
        setStatus("Transferring games… \(pct)%")
    }

    private func rbMessage(_ data: Data, _ s: Session) {
        guard let rb = s.rb, let kind = data.first else { return }
        switch kind {
        case Self.input:
            guard rb.inited, data.count >= 7 else { return }
            let frame = Int32(bitPattern: Self.read32(data, 1))
            let i = data.startIndex + 5
            let bits = Int32(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
            dingbat_rollback_feed(frame, bits)
            return
        case Self.ready:
            rb.remoteReady = true
            startIfReady(s)
            return
        case Self.speed:
            if data.count >= 2 { GameSession.shared.remoteSpeed(data[data.startIndex + 1] == 1) }
            return
        case Self.pause:
            if data.count >= 2 { GameSession.shared.remotePause(data[data.startIndex + 1] == 1) }
            return
        case Self.haveRom:
            // Our ROM is already on the friend's side.
            rb.friendHasRom = true
            rb.romSendStarted = true
            rb.romSent = rb.romBytes.count
            showTransfer(rb)
            return
        case Self.needRom:
            sendOurRom(s)
            return
        case Self.hello:
            guard data.count >= 9 else { return }
            rb.remoteRomHash = Self.read32(data, 5)
            if s.isHost != true { rb.epoch = Self.read32(data, 1) }  // the host's clock
            rb.remoteHello = true
            // A friend that names its whole ROM also answers for ours; both
            // sides then compare whole ROMs, an older build the first 1 MB.
            let answers = data.count >= Self.helloLen
            if answers {
                rb.remoteRomId = RomIdentity(len: Self.read32(data, 9), crc: Self.read32(data, 13),
                                             fnv: Self.read32(data, 17))
            }
            if answers ? rb.remoteRomId != rb.romId : rb.remoteRomHash != rb.romHash {
                rb.needRom = true
                showTransfer(rb)
                if let want = rb.remoteRomId { answerRom(want, rb, s) } else { sendOurRom(s) }
            }
        case Self.stateBegin:
            guard data.count >= 5 else { return }
            rb.stateLen = Int(Self.read32(data, 1))
            rb.stateBuf = Data()
            rb.stateBuf.reserveCapacity(rb.stateLen)
        case Self.stateChunk:
            rb.stateBuf.append(data.dropFirst())
            if rb.stateBuf.count >= rb.stateLen { rb.remoteState = rb.stateBuf }
        case Self.romBegin:
            guard data.count >= 5 else { return }
            let len = Int(Self.read32(data, 1))
            guard len > 0 && len <= Self.romMax else {
                fail("Your friend's game looks invalid — try again")
                return
            }
            rb.remoteRomLen = len
            rb.romBuf = Data()
            rb.romBuf.reserveCapacity(len)
            showTransfer(rb)
        case Self.romChunk:
            guard rb.remoteRomLen > 0, rb.remoteRom == nil else { return }
            rb.romBuf.append(data.dropFirst())
            showTransfer(rb)
            if rb.romBuf.count >= rb.remoteRomLen {
                guard Self.fnv1a(rb.romBuf) == rb.remoteRomHash,
                      rb.remoteRomId.map({ RomIdentity(rb.romBuf) == $0 }) ?? true else {
                    fail("Game transfer was corrupted — try again")
                    return
                }
                rb.remoteRom = rb.romBuf
                rb.romBuf = Data()
            }
        default:
            return
        }
        tryInit(s)
    }

    /// The friend named its whole ROM: look for it in the library (off the
    /// main thread), and say whether it needs to come over.
    private func answerRom(_ want: RomIdentity, _ rb: RB, _ s: Session) {
        let entries = RomLibrary.shared.entries
        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = LinkRomLookup.find(want, in: entries)
            DispatchQueue.main.async { [weak self] in
                guard let self, s.rb === rb else { return }
                if let bytes {
                    rb.remoteRom = bytes
                    rb.remoteRomLen = bytes.count
                    rb.romFromLibrary = true
                    print("netlink: the friend's game is in the library — not transferred")
                    self.send([Self.haveRom], s)
                } else {
                    self.send([Self.needRom], s)
                }
                self.showTransfer(rb)
                self.tryInit(s)
            }
        }
    }

    /// The friend's hello, state and (cross-game) ROM in hand: build both
    /// cores, load each player's snapshot, say ready.
    private func tryInit(_ s: Session) {
        guard let rb = s.rb, !rb.inited, rb.remoteHello, let remoteState = rb.remoteState else { return }
        if rb.needRom && rb.remoteRom == nil { return }
        rb.inited = true
        // This player's core runs on the game's own files (its battery save
        // is the game's); the friend's on a copy in Caches/link.
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("link")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let remote = dir.appendingPathComponent("rbrom\(1 - rb.localPlayer)\(rb.ext)")
        try? fm.removeItem(at: remote)
        try? fm.removeItem(at: remote.deletingPathExtension().appendingPathExtension("sav"))
        do {
            try (rb.needRom ? rb.remoteRom! : rb.romBytes).write(to: remote)
        } catch {
            fail("Couldn't start the session: \(error.localizedDescription)")
            return
        }
        let rom0 = rb.localPlayer == 0 ? rb.gamePath : remote.path
        let rom1 = rb.localPlayer == 0 ? remote.path : rb.gamePath
        GameSession.shared.linkWillStart()
        guard dingbat_rollback_init(rom0, rom1, Int32(rb.localPlayer), Double(rb.epoch)) == 1 else {
            let state = rb.localState
            fail("Couldn't start the link session")
            GameSession.shared.restoreAfterFailedLink(state)
            return
        }
        let host = rb.localPlayer == 0 ? rb.localState : remoteState
        let guest = rb.localPlayer == 0 ? remoteState : rb.localState
        func load(_ p: Int32, _ d: Data) -> Bool {
            d.withUnsafeBytes { dingbat_rollback_load_state(p, $0.baseAddress, Int32($0.count)) == 1 }
        }
        guard load(0, host), load(1, guest) else {
            fail("Couldn't sync game state — are you both on the latest dingbat?")
            return
        }
        rb.localReady = true
        send([Self.ready], s)
        setStatus(rb.needRom ? "Ready — waiting for your friend…" : "Waiting for your friend…")
        startIfReady(s)
    }

    private func startIfReady(_ s: Session) {
        guard let rb = s.rb, rb.inited, rb.localReady, rb.remoteReady, !s.started else { return }
        s.started = true
        linked = true
        connecting = false
        setStatus("")
        let model = AppModel.shared
        model.sheetPausedGame = false
        if case .link = model.sheet { model.sheet = nil }
        // Begun from the paused hero's ⋯: the session plays on the play screen.
        if model.screen != .play { withAnimation(.easeOut(duration: 0.25)) { model.screen = .play } }
        GameSession.shared.enterLinked()
        model.toast(s.isHost == true ? "Player 2 connected — full speed" : "Connected — full speed")
        // The ROMs and states now live in the cores.
        rb.romBytes = Data()
        rb.remoteRom = nil
        rb.romBuf = Data()
        rb.localState = Data()
        rb.remoteState = nil
        rb.stateBuf = Data()
    }

    // MARK: the running session

    func sendInput(frame: Int32, bits: UInt16) {
        guard let s = session, s.started else { return }
        send([Self.input] + Self.be32(UInt32(bitPattern: frame)) + [UInt8(bits >> 8), UInt8(bits & 0xff)], s)
    }

    /// 2x and pause drive both sides (a one-sided 2x or pause just stalls
    /// the friend at the prediction window).
    func sendSpeed(_ on: Bool) {
        guard let s = session, s.started else { return }
        send([Self.speed, on ? 1 : 0], s)
    }

    func sendPause(_ on: Bool) {
        guard let s = session, s.started else { return }
        send([Self.pause, on ? 1 : 0], s)
    }

    // MARK: endings

    /// Setup failed: say why on the sheet, which stays up for a retry.
    private func fail(_ msg: String) {
        if session?.started == true {
            peerGone(msg)
            return
        }
        NSLog("netlink: %@", msg)
        shutdown(keepSheet: true)
        setStatus(msg, error: true)
        if manualView && sheetUp { prepareManual(keepFriendBox: false) }
    }

    /// The friend is gone: this game keeps running with the cable pulled.
    private func peerGone(_ msg: String) {
        guard let s = session else { return }
        let started = s.started
        shutdown()
        if started { AppModel.shared.toast(msg + " — your game keeps running") }
        else { setStatus(msg, error: true) }
    }

    /// The player's Disconnect.
    func disconnect() {
        shutdown()
        AppModel.shared.toast("Disconnected")
    }

    /// The link went quiet (GameSession's idle watch).
    func idleDisconnect() {
        shutdown()
        AppModel.shared.toast("Link idle — disconnected")
    }

    /// End everything. A session that built its cores hands this player's
    /// core back as the solo game, in whatever pause state it is in.
    func shutdown(keepSheet: Bool = false) {
        guard let s = session else {
            connecting = false
            return
        }
        session = nil
        s.timer?.cancel()
        if s.rb?.inited == true {
            if dingbat_rollback_exit_to_single() != 1 { dingbat_rollback_exit() }
            GameSession.shared.leaveLinked()
        }
        s.peer?.close()
        s.peer = nil
        s.ws?.close()
        s.ws = nil
        linked = false
        connecting = false
        if !keepSheet, case .link = AppModel.shared.sheet { AppModel.shared.sheet = nil }
    }
}
