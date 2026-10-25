import AppKit
import Darwin

/// What is running, for owner guards: executable names (every process this
/// user can inspect, CLI tools included) and GUI apps' bundle IDs.
public struct ProcessSnapshot: Sendable {
    public let executableNames: Set<String>
    public let bundleIDs: Set<String>

    public init(executableNames: Set<String>, bundleIDs: Set<String>) {
        self.executableNames = Set(executableNames.map { $0.lowercased() })
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
    }

    public static let empty = ProcessSnapshot(executableNames: [], bundleIDs: [])

    public static func current() -> ProcessSnapshot {
        var names = Set<String>()
        let capacity = proc_listallpids(nil, 0)
        if capacity > 0 {
            var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
                if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                    names.insert((String(cString: buffer) as NSString).lastPathComponent)
                }
            }
        }
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return ProcessSnapshot(executableNames: names, bundleIDs: Set(ids))
    }
}
