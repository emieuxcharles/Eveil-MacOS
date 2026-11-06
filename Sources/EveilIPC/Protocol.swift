import Foundation

public enum ServiceIdentity {
    public static let app = "fr.eveil2.app"
    public static let daemon = "fr.eveil2.daemon"
    public static let plist = daemon + ".plist"
    public static let team = "4Y79TY2592"
    public static let installedPath = "/Applications/Eveil2.app"
    public static func requirement(for identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }
}

@objc public protocol EveilServiceProtocol {
    func ping(_ nonce: String, reply: @escaping (Data) -> Void)
    func status(reply: @escaping (Data) -> Void)
    func start(_ duration: Int, reply: @escaping (Data) -> Void)
    func heartbeat(reply: @escaping (Data) -> Void)
    func stop(reply: @escaping (Data) -> Void)
}

public struct ServiceProof: Codable, Equatable {
    public let protocolVersion: Int
    public let build: String
    public let pid: Int32
    public let euid: UInt32
    public let nonce: String
    public init(pid: Int32, euid: UInt32, nonce: String) {
        self.protocolVersion = 1; self.build = "2.0.0"
        self.pid = pid; self.euid = euid; self.nonce = nonce
    }
    public func validates(nonce: String) -> Bool {
        protocolVersion == 1 && self.nonce == nonce && euid == 0 && pid > 1
    }
}

public enum SessionPhase: String, Codable { case idle, active, recovering }
public enum StopCause: String, Codable { case user, expired, heartbeatLost, disconnected, thermal, wake, daemonRestart, daemonStopping, commandFailed }
public enum ThermalLevel: String, Codable { case nominal, fair, serious, critical
    public var unsafe: Bool { self == .serious || self == .critical }
}
public enum PowerSource: String, Codable, CaseIterable, CodingKeyRepresentable { case battery, ac, ups }
public struct PowerSettings: Codable, Equatable {
    public var lowPower: [PowerSource: Int]
    public var sleepDisabled: Bool
    public init(lowPower: [PowerSource: Int], sleepDisabled: Bool) { self.lowPower = lowPower; self.sleepDisabled = sleepDisabled }
}
public struct ServiceSnapshot: Codable {
    public var protocolVersion = 2
    public var phase: SessionPhase
    public var sessionID: UUID?
    public var startedAt: Date?
    public var deadline: Date?
    public var duration: Int?
    public var remainingSeconds: Int?
    public var ownerConnected: Bool
    public var thermal: ThermalLevel
    public var stopCause: StopCause?
    public var settings: PowerSettings?
    public var error: String?
    public init(phase: SessionPhase, sessionID: UUID?, startedAt: Date?, deadline: Date?, duration: Int?, remainingSeconds: Int?, ownerConnected: Bool, thermal: ThermalLevel, stopCause: StopCause?, settings: PowerSettings?, error: String?) {
        self.phase = phase; self.sessionID = sessionID; self.startedAt = startedAt; self.deadline = deadline; self.duration = duration; self.remainingSeconds = remainingSeconds; self.ownerConnected = ownerConnected; self.thermal = thermal; self.stopCause = stopCause; self.settings = settings; self.error = error
    }
}
public struct ServiceReply: Codable {
    public let accepted: Bool
    public let snapshot: ServiceSnapshot
    public let error: String?
    public init(accepted: Bool, snapshot: ServiceSnapshot, error: String? = nil) { self.accepted = accepted; self.snapshot = snapshot; self.error = error }
}
