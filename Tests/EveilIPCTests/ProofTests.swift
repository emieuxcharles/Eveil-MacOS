import XCTest
@testable import EveilIPC
final class ProofTests: XCTestCase {
    func testProofRejectsStaleNonceAndNonRootService() throws {
        XCTAssertTrue(ServiceProof(pid: 123, euid: 0, nonce: "fresh").validates(nonce: "fresh"))
        XCTAssertFalse(ServiceProof(pid: 123, euid: 0, nonce: "stale").validates(nonce: "fresh"))
        XCTAssertFalse(ServiceProof(pid: 123, euid: 501, nonce: "fresh").validates(nonce: "fresh"))
        XCTAssertFalse(ServiceProof(pid: 1, euid: 0, nonce: "fresh").validates(nonce: "fresh"))
    }
    func testProofRoundTrip() throws {
        let original = ServiceProof(pid: 123, euid: 0, nonce: UUID().uuidString)
        XCTAssertEqual(try JSONDecoder().decode(ServiceProof.self, from: JSONEncoder().encode(original)), original)
    }
}
