import Foundation
import EveilIPC
import Darwin

public final class PMSetPowerDriver: PowerDriver {
    public init() {}
    private func run(_ arguments: [String]) throws -> String {
        try BoundedCommandRunner.run(executable: "/usr/bin/pmset", arguments: arguments)
    }
    public func read() throws -> PowerSettings {
        try Self.parse(custom: run(["-g", "custom"]), global: run(["-g"]))
    }
    public static func parse(custom: String, global: String) throws -> PowerSettings {
        var source: PowerSource?; var values: [PowerSource: Int] = [:]
        for line in custom.components(separatedBy: .newlines) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case "Battery Power:": source = .battery
            case "AC Power:": source = .ac
            case "UPS Power:": source = .ups
            default:
                if line.hasSuffix(":") { source = nil }
                let pieces = line.split(whereSeparator: { $0.isWhitespace })
                if pieces.first == "lowpowermode", let source {
                    guard pieces.count == 2, let value = Int(pieces[1]), [0, 1].contains(value), values[source] == nil else { throw SessionFailure("Réglage économie d’énergie illisible.") }
                    values[source] = value
                }
            }
        }
        let sleepValues = global.components(separatedBy: .newlines).compactMap { line -> Int? in
            let pieces = line.split(whereSeparator: { $0.isWhitespace })
            guard pieces.first == "SleepDisabled", pieces.count == 2 else { return nil }
            return Int(pieces[1])
        }
        guard !values.isEmpty, sleepValues.count == 1, let sleep = sleepValues.first, [0, 1].contains(sleep) else { throw SessionFailure("Impossible de lire les réglages d’alimentation.") }
        return PowerSettings(lowPower: values, sleepDisabled: sleep == 1)
    }
    public func setLowPower(_ value: Int, source: PowerSource) throws {
        guard [0, 1].contains(value) else { throw SessionFailure("Valeur d’alimentation non autorisée.") }
        let selector: String
        switch source { case .battery: selector = "-b"; case .ac: selector = "-c"; case .ups: selector = "-u" }
        _ = try run([selector, "lowpowermode", String(value)])
    }
    public func setSleepDisabled(_ disabled: Bool) throws { _ = try run(["-a", "disablesleep", disabled ? "1" : "0"]) }
    public func requestSleep() throws { _ = try run(["sleepnow"]) }
}
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk.prefix(max(0, 8192 - data.count))) }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// Internal only: XPC never accepts an executable or command arguments.
enum BoundedCommandRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 3) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let output = Pipe(); task.standardOutput = output; task.standardError = output
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try task.run()
        // pmset has small, trusted output. Read concurrently so a full pipe cannot block termination.
        let reader = DispatchGroup(); reader.enter()
        let buffer = OutputBuffer()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            reader.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 1)
            throw SessionFailure("La commande d’alimentation n’a pas répondu dans le délai autorisé.")
        }
        guard reader.wait(timeout: .now() + 1) == .success else { throw SessionFailure("Lecture pmset interrompue.") }
        let result = buffer.string
        guard task.terminationReason == .exit && task.terminationStatus == 0 else {
            throw SessionFailure("pmset a échoué (\(task.terminationStatus)) : \(result.prefix(500))")
        }
        return result
    }
}
