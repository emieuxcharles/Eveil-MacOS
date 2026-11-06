import Foundation
import Darwin

/// Root-only directory, no symlink following, atomic replacement and file + directory fsync.
public final class SecureSessionJournal: SessionJournal {
    public static let productionDirectory = "/var/db/fr.eveil2"
    private let directory: String
    private let owner: uid_t
    public init(directory: String = productionDirectory, requiredOwner: uid_t = 0) { self.directory = directory; self.owner = requiredOwner }
    private func failure(_ operation: String) -> SessionFailure { SessionFailure("Journal : \(operation) (\(String(cString: strerror(errno)))).") }
    private func directoryFD() throws -> Int32 {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw failure("création du dossier") }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("ouverture du dossier") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == owner, metadata.st_mode & 0o777 == 0o700 else { close(fd); throw SessionFailure("Journal : dossier non privé ou propriétaire incorrect.") }
        return fd
    }
    public func load() throws -> SessionRecord? {
        let dir = try directoryFD(); defer { close(dir) }
        let fd = openat(dir, "session.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("lecture") }; defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == owner, metadata.st_mode & 0o777 == 0o600, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 65536 else { throw SessionFailure("Journal : fichier non sûr ou taille invalide.") }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("lecture") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 65536 else { throw SessionFailure("Journal trop volumineux.") }
        }
        let record = try JSONDecoder().decode(SessionRecord.self, from: data)
        guard record.version == 1, SessionEngine.supportedDurations.contains(record.duration), !record.originalLowPower.isEmpty, record.originalLowPower.values.allSatisfy({ [0, 1].contains($0) }), record.startedAt.timeIntervalSince1970.isFinite, (record.duration == 0) == (record.deadline == nil), record.deadline?.timeIntervalSince1970.isFinite != false else { throw SessionFailure("Journal : contenu invalide.") }
        return record
    }
    public func save(_ record: SessionRecord) throws {
        let dir = try directoryFD(); defer { close(dir) }
        let name = ".session-" + UUID().uuidString
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("création du fichier") }
        defer { close(fd); unlinkat(dir, name, 0) }
        let data = try JSONEncoder().encode(record)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("écriture") }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("synchronisation du fichier") }
        guard renameat(dir, name, dir, "session.json") == 0 else { throw failure("remplacement atomique") }
        guard fsync(dir) == 0 else { throw failure("synchronisation du dossier") }
    }
    public func remove() throws {
        let dir = try directoryFD(); defer { close(dir) }
        if unlinkat(dir, "session.json", 0) != 0 && errno != ENOENT { throw failure("suppression") }
        guard fsync(dir) == 0 else { throw failure("synchronisation après suppression") }
    }
}
