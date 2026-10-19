import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
    var trimmedOutput: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs system tools by absolute path with stdout and stderr merged.
enum Shell {
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// Blocks the calling thread until the tool exits (or is killed after `timeout`).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: "failed to run \(path): \(error)")
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Same, without blocking the caller: the wait happens on a GCD thread.
    static func runAsync(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: run(path, arguments, timeout: timeout))
            }
        }
    }
}
