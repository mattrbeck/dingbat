#if DEBUG
import Foundation

/// `-stall-log`: how long the main thread takes to answer, measured from a
/// background thread every 50 ms. tmp/stall.txt gets one line per wait over
/// 100 ms, "<uptime ms> <wait ms>" (ios/e2e/drive-big.mjs reads it). A hang
/// is a long wait.
enum StallLog {
    static func startIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-stall-log") else { return }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stall.txt")
        let thread = Thread {
            var lines = ""
            while true {
                let sent = ProcessInfo.processInfo.systemUptime
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = (ProcessInfo.processInfo.systemUptime - sent) * 1000
                if ms > 100 {
                    lines += String(format: "%.0f %.0f\n", sent * 1000, ms)
                    try? lines.write(to: file, atomically: true, encoding: .utf8)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.start()
    }
}
#endif
