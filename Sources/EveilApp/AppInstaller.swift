import AppKit
import Security
import EveilIPC
import EveilCore

/// One explicit, bounded install transaction. No automatic repair, deletion or registration retry.
/// The existing signed application owns unregister; its CLI waits for the native callback + settling.
enum AppInstaller {
    private static func failure(_ text: String) -> Error { SessionFailure(text) }
    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: ServiceIdentity.installedPath)
        guard source.standardizedFileURL != destination else { completion(.failure(failure("Éveil est déjà installé dans Applications."))); return }
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: ServiceIdentity.app).filter { $0.processIdentifier != getpid() }
        for app in existing { _ = app.terminate() }
        // terminate() asks the old app's normal stop-before-quit path. Never force termination.
        let deadline = Date().addingTimeInterval(35)
        func awaitExit() {
            guard existing.allSatisfy(\.isTerminated) else {
                guard Date() < deadline else { completion(.failure(failure("L’ancienne application est encore ouverte. Arrêtez sa session et quittez-la avant de réessayer."))); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: awaitExit); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try replace(source: source, destination: destination) }
                DispatchQueue.main.async {
                    switch result {
                    case .failure: completion(result)
                    case .success:
                        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.createsNewApplicationInstance = true
                        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                            DispatchQueue.main.async { completion(error.map { .failure($0) } ?? .success(())) }
                        }
                    }
                }
            }
        }
        awaitExit()
    }
    private static func verify(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw failure("Impossible de vérifier la signature de l’application.") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(ServiceIdentity.requirement(for: ServiceIdentity.app) as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw failure("La signature de cette version d’Éveil n’est pas valide.") }
    }
    private static func command(_ executable: URL, _ argument: String, timeout: TimeInterval = 45) throws -> Data {
        let process = Process(); process.executableURL = executable; process.arguments = [argument]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Do not kill an outstanding native ServiceManagement operation, replace, or retry it.
            throw failure("L’ancienne version ne confirme pas la fin de l’opération. Aucun fichier n’a été remplacé. Attendez la fin de l’opération macOS.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw failure(String(data: data, encoding: .utf8) ?? "L’ancienne version a refusé l’opération.") }
        return data
    }
    static func decodeStopReply(_ data: Data) throws -> ServiceReply {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("reply ") else { throw failure("La réponse de restauration est illisible.") }
        return try JSONDecoder().decode(ServiceReply.self, from: Data(text.dropFirst(6).utf8))
    }
    private static func replace(source: URL, destination: URL) throws {
        let files = FileManager.default
        try verify(source)
        let exists = files.fileExists(atPath: destination.path)
        if exists {
            try verify(destination)
            let executable = destination.appendingPathComponent("Contents/MacOS/Eveil2")
            let statusData = try command(executable, "--status")
            let status = String(data: statusData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var oldPID: Int32?
            if status == "enabled" {
                oldPID = try JSONDecoder().decode(ServiceProof.self, from: command(executable, "--probe")).pid
                let reply = try decodeStopReply(command(executable, "--session-stop"))
                guard reply.accepted, AppModel.confirmsRestoration(reply.snapshot) else { throw failure("La restauration n’est pas confirmée. L’installation s’arrête sans remplacer l’application.") }
            }
            if status != "notRegistered" && status != "notFound" {
                let result = try command(executable, "--unregister")
                guard String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "notRegistered" else { throw failure("Le retrait de l’ancien service n’est pas confirmé.") }
            }
            if let pid = oldPID {
                let deadline = Date().addingTimeInterval(10)
                while kill(pid, 0) == 0 || errno != ESRCH {
                    if Date() >= deadline { throw failure("L’ancien service est encore présent. Aucun fichier n’a été remplacé.") }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: ServiceIdentity.app).allSatisfy({ $0.processIdentifier == getpid() }) else { throw failure("Une autre version d’Éveil a été rouverte. Quittez-la avant de réessayer.") }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Eveil2-install-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try verify(staging)
        var backup: URL?
        if exists {
            let folder = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Éveil/Anciennes versions", isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("Eveil-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).app")
            // Copy first: a backup on another volume is supported, and a failed copy preserves the installed app.
            try files.copyItem(at: destination, to: target); try verify(target); backup = target
            try files.removeItem(at: destination)
        }
        do { try files.moveItem(at: staging, to: destination) }
        catch {
            if let backup, !files.fileExists(atPath: destination.path) { try? files.copyItem(at: backup, to: destination) }
            throw error
        }
        // New app opens its native setup. Registration happens there, after replacement, with real probe.
    }
}
