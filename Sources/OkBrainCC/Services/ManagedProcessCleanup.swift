import Foundation

enum ManagedProcessCleanup {
  static func terminate(_ process: Process, timeout: TimeInterval = 2) {
    guard process.isRunning else {
      return
    }

    let semaphore = DispatchSemaphore(value: 0)
    let originalTerminationHandler = process.terminationHandler
    process.terminationHandler = { terminatedProcess in
      originalTerminationHandler?(terminatedProcess)
      semaphore.signal()
    }

    process.terminate()

    if semaphore.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
      signal(processID: process.processIdentifier, signal: "KILL")
    }
  }

  static func terminateProcesses(matching pattern: String, timeout: TimeInterval = 1) {
    guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    runPkill(signal: "TERM", pattern: pattern)
    Thread.sleep(forTimeInterval: timeout)
    runPkill(signal: "KILL", pattern: pattern)
  }

  private static func runPkill(signal: String, pattern: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-\(signal)", "-f", pattern]

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return
    }
  }

  private static func signal(processID: Int32, signal: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/kill")
    process.arguments = ["-\(signal)", String(processID)]

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return
    }
  }
}
