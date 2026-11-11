import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the app process is doing when it publishes the PPoGATT service: in the
/// foreground or background, whether protected data is readable (the phone has
/// been unlocked since it started), and how long the process has run. Logged
/// with every publish, so a stalled link can be traced to how the process started.
enum PebbleRuntimeContext {
    /// `appState` and `protectedData` are "unknown" where UIKit isn't available.
    nonisolated static func describe(appState: String, protectedData: String, processAge: TimeInterval?) -> String {
        var parts = ["app \(appState)", "protected data \(protectedData)"]
        if let processAge {
            parts.append("process started \(duration(processAge)) ago")
        }
        return parts.joined(separator: ", ")
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }

    /// When this process started, from the kernel; nil if it can't be read.
    nonisolated static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    @MainActor
    static func current(now: Date = Date()) -> String {
        let age = processStartDate().map { now.timeIntervalSince($0) }
        #if canImport(UIKit) && !os(watchOS)
        let application = UIApplication.shared
        let appState: String
        switch application.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "in the background"
        @unknown default: appState = "unknown"
        }
        let protectedData = application.isProtectedDataAvailable ? "readable" : "locked"
        return describe(appState: appState, protectedData: protectedData, processAge: age)
        #else
        return describe(appState: "unknown", protectedData: "unknown", processAge: age)
        #endif
    }
}
