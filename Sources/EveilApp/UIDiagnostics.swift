import AppKit
import EveilIPC

/// Read-only, user-level UI diagnostics. It never changes visibility, service state or power.
/// Requests carry only a UUID; the output path is fixed and contains no user document data.
enum UIDiagnostics {
    static let requestName = Notification.Name("fr.eveil2.app.ui-state-request")
    static var outputURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Éveil/Diagnostics/ui-state.json")
    }
    static func write(_ state: [String: Any], requestID: String) {
        guard UUID(uuidString: requestID) != nil else { return }
        var result = state; result["requestID"] = requestID; result["timestamp"] = Date().ISO8601Format()
        do {
            let directory = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        } catch { NSLog("Éveil UI diagnostic: %@", error.localizedDescription) }
    }
    static func request(completion: @escaping (Result<Data, Error>) -> Void) {
        let requestID = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(requestName, object: nil, userInfo: ["requestID": requestID], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        func read() {
            if let data = try? Data(contentsOf: outputURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["requestID"] as? String == requestID {
                completion(.success(data)); return
            }
            guard Date() < deadline else {
                completion(.failure(NSError(domain: "EveilUIDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "L’interface ouverte n’a pas répondu sous 3 secondes. Aucun état n’a été modifié."]))); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: read)
        }
        read()
    }
}
