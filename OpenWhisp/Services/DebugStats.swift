#if OPENWHISP_INSTRUMENTATION
import Foundation
import Darwin

// MARK: - Debug Stats sampler (dev-only)
//
// Lightweight process resource sampling for the debug HUD. Compiled in ONLY under
// OPENWHISP_INSTRUMENTATION. Reads:
//   * this app's resident memory + CPU% via Mach task APIs, and
//   * an arbitrary child pid's (the llama-server) RSS + CPU% via `ps`.
// No third-party deps; cheap enough to poll a few times a second.
enum DebugStats {

    struct ProcSample {
        var rssMB: Int
        var cpuPercent: Double
    }

    /// This process's resident memory (MB) via Mach task_info.
    static func selfResidentMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        // phys_footprint is the closest match to what Activity Monitor shows.
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// `ps`-derived RSS (MB) + CPU% for a pid (the llama-server lives in its own
    /// process). Returns nil if the pid isn't running. CPU% from ps is a
    /// since-launch average, fine for a coarse HUD reading.
    static func sample(pid: Int32) -> ProcSample? {
        guard pid > 0 else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=,%cpu=", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2,
              let rssKB = Int(parts[0]),
              let cpu = Double(parts[1]) else {
            return nil
        }
        return ProcSample(rssMB: rssKB / 1024, cpuPercent: cpu)
    }

    /// This process's CPU% as a sum across threads, computed as a delta between
    /// two calls. Stateless callers should keep the previous reading; the HUD does
    /// this via a tiny cache below.
    static func selfCPUPercent() -> Double {
        // Reuse ps for the app pid too — keeps one code path and matches the
        // child-process reading semantics.
        sample(pid: ProcessInfo.processInfo.processIdentifier)?.cpuPercent ?? -1
    }
}
#endif
