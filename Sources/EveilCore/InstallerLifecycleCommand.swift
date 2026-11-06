import Foundation

public struct UnresolvedNativeOperation: LocalizedError {
    public init() {}
    public var errorDescription: String? { "macOS n’a pas encore confirmé la fin de l’opération. Aucun remplacement n’a eu lieu ; un nouvel essai reste bloqué jusqu’à sa confirmation." }
}

/// Only the installer's native-unregister child uses this retained command path.
/// The reader retains the child after either deadline. Late completion unlocks retry, never copy.
public final class InstallerLifecycleCommand {
    private final class Call {
        let process = Process()
        let pipe = Pipe()
        let signal = DispatchSemaphore(value: 0)
        var output = Data()
        var deadlineReported = false
        var finished = false
        var confirmed = false
        var exitCode: Int32 = -1
    }
    private let mutex = NSLock()
    private var current: Call?
    public init() {}
    public var isBusy: Bool { mutex.lock(); defer { mutex.unlock() }; return current != nil }
    public func run(executable: URL, arguments: [String], timeout: TimeInterval = 45) throws -> Data {
        mutex.lock()
        guard current == nil else { mutex.unlock(); throw UnresolvedNativeOperation() }
        let call = Call(); current = call; mutex.unlock()
        call.process.executableURL = executable; call.process.arguments = arguments
        call.process.standardOutput = call.pipe; call.process.standardError = call.pipe
        do { try call.process.run() }
        catch { mutex.lock(); current = nil; mutex.unlock(); throw error }
        DispatchQueue.global(qos: .utility).async { [self, call] in
            while true {
                let data = call.pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                mutex.lock()
                if call.output.count < 65536 { call.output.append(data.prefix(65536 - call.output.count)) }
                let output = String(decoding: call.output, as: UTF8.self)
                if output.contains(LifecycleCLIResult.pendingMarker), !call.deadlineReported {
                    call.deadlineReported = true; call.signal.signal()
                }
                mutex.unlock()
            }
            call.process.waitUntilExit()
            mutex.lock()
            call.finished = true; call.exitCode = call.process.terminationStatus
            let lines = String(decoding: call.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            // Old signed versions have no marker, but their successful unregister waits for settling.
            call.confirmed = lines.contains(LifecycleCLIResult.settledMarker) || (call.exitCode == 0 && lines.contains("notRegistered"))
            if call.confirmed, current === call { current = nil }
            // An old child's ambiguous error cannot prove native completion; remain excluded.
            call.signal.signal(); mutex.unlock()
        }
        let wait = call.signal.wait(timeout: .now() + timeout)
        mutex.lock(); defer { mutex.unlock() }
        if wait == .timedOut { call.deadlineReported = true; throw UnresolvedNativeOperation() }
        guard call.finished, !call.deadlineReported, call.confirmed else { throw UnresolvedNativeOperation() }
        guard call.exitCode == 0 else { throw SessionFailure(String(decoding: call.output, as: UTF8.self)) }
        return call.output
    }
}
