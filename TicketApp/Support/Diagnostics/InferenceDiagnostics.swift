import Foundation
import OSLog
import Darwin

/// A run-correlated, content-free trace. The timer is independent of the UI/model actors.
nonisolated final class InferenceTrace: @unchecked Sendable {
    private static let logger = Logger(subsystem: "kaiusjin.TicketApp", category: "InferenceDiagnostics")
    private let id = UUID().uuidString.prefix(8)
    private let started = ContinuousClock.now
    private let lock = NSLock()
    private var stage = "starting"
    private var stageStarted = ContinuousClock.now
    private var timer: DispatchSourceTimer?
    private var generation = GenerationProgress()
    private var generationIndex = 0
    private var lines: [String] = []

    init(operation: String) {
        event("run_start operation=\(operation) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        var system = utsname()
        uname(&system)
        let device = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        event("diagnostics_version=6 device=\(device) physical_memory_MiB=\(ProcessInfo.processInfo.physicalMemory / 1048576) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        #if DEBUG
        event("build=Debug")
        #else
        event("build=Release")
        #endif
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "TicketApp.Diagnostics", qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        self.timer = timer
        timer.resume()
    }

    func phase(_ name: String) {
        lock.lock()
        let previous = stage
        let duration = seconds(stageStarted.duration(to: .now))
        stage = name
        stageStarted = .now
        lock.unlock()
        event("phase=\(name) previous=\(previous) previous_seconds=\(duration)")
    }

    func event(_ message: String) {
        let line = "run=\(id) elapsed=\(seconds(started.duration(to: .now)))s \(message)"
        lock.lock()
        lines.append(line)
        // Keep the initial configuration and the most recent events for copying in the app.
        if lines.count > 240 { lines.remove(at: 24) }
        lock.unlock()
        Self.logger.notice("\(line, privacy: .public)")
    }

    func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func beginGeneration(model: String) {
        lock.lock()
        generationIndex += 1
        let index = generationIndex
        generation = GenerationProgress()
        generation.enter("input_prepare", at: elapsedSeconds)
        lock.unlock()
        event("generation_start index=\(index) model=\(model)")
    }

    func consumerStep(_ name: String) {
        lock.lock()
        generation.enter(name, at: elapsedSeconds)
        lock.unlock()
    }

    func receivedToken(_ token: Int) {
        lock.lock()
        generation.receive(token, at: elapsedSeconds)
        lock.unlock()
    }

    func decodedText(_ text: String, boundary: JSONObjectBoundary? = nil) {
        lock.lock()
        generation.append(text, state: boundary?.diagnosticState ?? "disabled", depth: boundary?.nestingDepth ?? 0, at: elapsedSeconds)
        lock.unlock()
    }

    func generationSnapshot(_ label: String) {
        lock.lock()
        let snapshot = generation.snapshot(at: elapsedSeconds)
        lock.unlock()
        event("\(label) \(snapshot)")
    }

    private var elapsedSeconds: Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func failure(_ error: Error) {
        let nsError = error as NSError
        // Error descriptions/userInfo may contain OCR text, file paths or prompts.
        event("error_type=\(String(reflecting: type(of: error))) domain=\(nsError.domain) code=\(nsError.code)")
        if let receiptError = error as? ReceiptError {
            event("receipt_error=\(String(describing: receiptError))")
        }
    }

    func finish(_ outcome: String) {
        timer?.cancel()
        timer = nil
        event("run_end outcome=\(outcome) \(Self.memory())")
    }

    private func heartbeat() {
        lock.lock()
        let name = stage
        let duration = seconds(stageStarted.duration(to: .now))
        let progress = generation.snapshot(at: elapsedSeconds)
        let index = generationIndex
        lock.unlock()
        event("heartbeat generation_index=\(index) phase=\(name) phase_seconds=\(duration) \(progress) \(Self.memory()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    private func seconds(_ duration: Duration) -> String {
        String(format: "%.2f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return "footprint_unavailable=\(status)" }
        return "footprint_MiB=\(info.phys_footprint / 1048576) resident_MiB=\(info.resident_size / 1048576)"
    }

    deinit { timer?.cancel() }
}

nonisolated enum InferenceDiagnostics {
    @TaskLocal static var current: InferenceTrace?
}
