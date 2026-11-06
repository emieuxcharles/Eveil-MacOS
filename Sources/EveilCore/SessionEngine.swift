import Foundation
import EveilIPC
import Darwin

public protocol SessionClock: AnyObject { var wall: Date { get }; var monotonic: TimeInterval { get } }
public final class SystemSessionClock: SessionClock {
    public init() {}
    public var wall: Date { Date() }
    public var monotonic: TimeInterval {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
public protocol PowerDriver: AnyObject {
    func read() throws -> PowerSettings
    func setLowPower(_ value: Int, source: PowerSource) throws
    func setSleepDisabled(_ disabled: Bool) throws
    func requestSleep() throws
}
public struct SessionRecord: Codable {
    public var version = 1
    public var id: UUID
    public var originalLowPower: [PowerSource: Int]
    public var startedAt: Date
    public var deadline: Date?
    public var duration: Int
    public var stopCause: StopCause?
    // Write intent durably before sleep: a crash cannot repeat a successful sleep after wake.
    public var sleepAttempted = false
    public var sleepRequested = false
}
public protocol SessionJournal: AnyObject {
    func load() throws -> SessionRecord?
    func save(_ record: SessionRecord) throws
    func remove() throws
}
public struct SessionFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// All access belongs to the daemon's single serial coordinator queue.
public final class SessionEngine {
    public static let supportedDurations = [0, 3600, 7200, 10800]
    private let clock: SessionClock
    private let power: PowerDriver
    private let journal: SessionJournal
    private var record: SessionRecord?
    private var owner: String?
    private var lastHeartbeat: TimeInterval = 0
    private var monotonicDeadline: TimeInterval?
    private var phase: SessionPhase = .idle
    private var lastError: String?
    private var lastCause: StopCause?
    private var verified: PowerSettings?
    private var journalUnreadable = false
    public var thermal: ThermalLevel = .nominal
    public init(clock: SessionClock, power: PowerDriver, journal: SessionJournal) {
        self.clock = clock; self.power = power; self.journal = journal
        recoverJournal()
    }
    public var snapshot: ServiceSnapshot {
        var remaining: Int?
        if phase == .active, let deadline = record?.deadline, let mono = monotonicDeadline {
            remaining = max(0, Int(ceil(min(deadline.timeIntervalSince(clock.wall), mono - clock.monotonic))))
        }
        return ServiceSnapshot(phase: phase, sessionID: record?.id, startedAt: record?.startedAt, deadline: record?.deadline, duration: record?.duration, remainingSeconds: remaining, ownerConnected: owner != nil, thermal: thermal, stopCause: record?.stopCause ?? lastCause, settings: verified, error: lastError)
    }
    private func recoverJournal() {
        do {
            record = try journal.load(); journalUnreadable = false
            if record != nil {
                if record?.stopCause == nil { record?.stopCause = .daemonRestart }
                phase = .recovering; try restore()
            } else { phase = .idle; lastError = nil; verified = try power.read() }
        } catch {
            phase = .recovering; lastError = error.localizedDescription
            if record == nil { journalUnreadable = true; allowSleepAfterUnreadableJournal() }
        }
    }
    private func allowSleepAfterUnreadableJournal() {
        do { try power.setSleepDisabled(false); let state = try power.read(); guard !state.sleepDisabled else { throw SessionFailure("La veille reste désactivée.") }; verified = state }
        catch { lastError = "Journal illisible ; \(error.localizedDescription)" }
    }
    public func start(duration: Int, owner: String) throws {
        guard Self.supportedDurations.contains(duration) else { throw SessionFailure("Durée autorisée : 1, 2, 3 heures ou illimitée.") }
        guard phase == .idle && record == nil && !journalUnreadable else { throw SessionFailure("Une session ou une restauration est déjà en cours.") }
        guard !thermal.unsafe else { throw SessionFailure("Température trop élevée pour démarrer.") }
        let original = try power.read()
        guard !original.lowPower.isEmpty else { throw SessionFailure("Aucune alimentation compatible détectée.") }
        let now = clock.wall
        let next = SessionRecord(id: UUID(), originalLowPower: original.lowPower, startedAt: now, deadline: duration == 0 ? nil : now.addingTimeInterval(Double(duration)), duration: duration)
        do { try journal.save(next) } // No power mutation may precede this sync.
        catch {
            record = next; record?.stopCause = .commandFailed; phase = .recovering; lastError = error.localizedDescription
            throw error
        }
        record = next; phase = .recovering; verified = original; lastError = nil; lastCause = nil
        do {
            for source in PowerSource.allCases where original.lowPower[source] != nil {
                try power.setLowPower(1, source: source)
                guard try power.read().lowPower[source] == 1 else { throw SessionFailure("Le mode économie d’énergie n’a pas été confirmé pour \(source.rawValue).") }
            }
            try power.setSleepDisabled(true)
            let actual = try power.read()
            guard actual.sleepDisabled && original.lowPower.keys.allSatisfy({ actual.lowPower[$0] == 1 }) else { throw SessionFailure("Les réglages actifs n’ont pas été confirmés.") }
            verified = actual; self.owner = owner; lastHeartbeat = clock.monotonic
            monotonicDeadline = duration == 0 ? nil : clock.monotonic + Double(duration)
            phase = .active
        } catch {
            let initialError = error
            record?.stopCause = .commandFailed
            do { try restore() } catch { lastError = error.localizedDescription }
            throw initialError
        }
    }
    public func heartbeat(owner: String) throws {
        tick()
        guard phase == .active && self.owner == owner else { throw SessionFailure("Cette connexion ne contrôle pas la session.") }
        lastHeartbeat = clock.monotonic
    }
    public func disconnected(owner: String) { if self.owner == owner { try? stop(cause: .disconnected) } }
    public func wake() { if phase == .active { try? stop(cause: .wake) } }
    public func stop(cause: StopCause) throws {
        if record == nil {
            if journalUnreadable { allowSleepAfterUnreadableJournal(); throw SessionFailure(lastError ?? "Journal illisible.") }
            // An explicit stop must verify current OS state, never trust the idle cache.
            // No journal means no known low-power originals: do not change those settings.
            verified = nil
            do {
                try power.setSleepDisabled(false)
                let actual = try power.read()
                guard !actual.sleepDisabled else { throw SessionFailure("La veille reste désactivée.") }
                verified = actual; phase = .idle; lastError = nil; lastCause = cause
            } catch { lastError = error.localizedDescription; throw error }
            return
        }
        if record?.stopCause == nil { record?.stopCause = cause }
        owner = nil; monotonicDeadline = nil; phase = .recovering
        try restore()
    }
    public func tick() {
        if phase == .recovering {
            if journalUnreadable { recoverJournal() } else { do { try restore() } catch { lastError = error.localizedDescription } }
            return
        }
        guard phase == .active else { return }
        if thermal.unsafe { try? stop(cause: .thermal) }
        else if let deadline = record?.deadline, clock.wall >= deadline || clock.monotonic >= (monotonicDeadline ?? .infinity) { try? stop(cause: .expired) }
        else if clock.monotonic - lastHeartbeat >= 20 { try? stop(cause: .heartbeatLost) }
    }
    private func restore() throws {
        guard var saved = record else { return }
        phase = .recovering; owner = nil; monotonicDeadline = nil
        var failures: [String] = []
        func attempt(_ operation: () throws -> Void) { do { try operation() } catch { failures.append(error.localizedDescription) } }
        attempt { try journal.save(saved) }
        // Always allow sleep first, even when the journal or another source fails.
        attempt {
            try power.setSleepDisabled(false)
            guard try !power.read().sleepDisabled else { throw SessionFailure("La veille reste désactivée.") }
        }
        for source in PowerSource.allCases {
            guard let original = saved.originalLowPower[source] else { continue }
            attempt {
                try power.setLowPower(original, source: source)
                guard try power.read().lowPower[source] == original else { throw SessionFailure("Restauration non confirmée pour \(source.rawValue).") }
            }
        }
        if saved.stopCause == .thermal && !saved.sleepAttempted {
            attempt {
                var intent = saved; intent.sleepAttempted = true
                try journal.save(intent); saved = intent; record = saved
                do {
                    try power.requestSleep(); saved.sleepRequested = true; record = saved; try journal.save(saved)
                } catch {
                    // Only a failed command may retry. A successful sleep followed by a failed save must never repeat.
                    if !saved.sleepRequested { saved.sleepAttempted = false; record = saved; try? journal.save(saved) }
                    throw error
                }
            }
        }
        record = saved
        attempt { verified = try power.read() }
        if failures.isEmpty { attempt { try journal.remove() } }
        if !failures.isEmpty {
            lastError = failures.joined(separator: " ; "); throw SessionFailure(lastError!)
        }
        lastCause = saved.stopCause; record = nil; phase = .idle; lastError = nil; journalUnreadable = false
    }
}
