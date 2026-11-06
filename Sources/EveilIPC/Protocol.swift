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
}

public struct ServiceProof: Codable, Equatable {
    public let protocolVersion: Int
    public let build: String
    public let pid: Int32
    public let euid: UInt32
    public let nonce: String
    public init(pid: Int32, euid: UInt32, nonce: String) {
        self.protocolVersion = 1; self.build = "2.0.0-proof.1"
        self.pid = pid; self.euid = euid; self.nonce = nonce
    }
    public func validates(nonce: String) -> Bool {
        protocolVersion == 1 && self.nonce == nonce && euid == 0 && pid > 1
    }
}
