import Foundation
import EveilIPC
import EveilCore
import Darwin

/// Developer diagnostics only; the service always enforces production durations and identity.
func runSessionCLI() -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--session-status") || args.contains("--session-stop") || args.contains("--session-start") || args.contains("--bounded-test") else { return false }
    let client = ServiceClient(); let power = PMSetPowerDriver()
    var signals: [DispatchSourceSignal] = []
    var finishing = false
    var before: PowerSettings?
    func emit<T: Encodable>(_ label: String, _ value: T) {
        let data = try! JSONEncoder().encode(value)
        print("\(label) \(String(decoding: data, as: UTF8.self))"); fflush(stdout)
    }
    func finish(_ result: Result<ServiceReply, Error>) {
        switch result {
        case .success(let reply): emit("reply", reply); exit(reply.accepted ? 0 : 1)
        case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
    func cleanup(code: Int32) {
        guard !finishing else { return }; finishing = true
        client.stopSession { result in
            var code = code
            switch result {
            case .success(let reply): emit("after-service", reply); if !reply.accepted || reply.snapshot.phase != .idle { code = 1 }
            case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); code = 1
            }
            do {
                let after = try power.read(); emit("after", after)
                if let before, after.sleepDisabled || after.lowPower != before.lowPower { code = 1 }
            } catch { fputs("\(error.localizedDescription)\n", stderr); code = 1 }
            client.disconnect(); exit(code)
        }
    }
    if args.contains("--session-status") { client.status(completion: finish) }
    else if args.contains("--session-stop") { client.stopSession(completion: finish) }
    else {
        let bounded = args.contains("--bounded-test")
        func argument(_ flag: String) -> Int? { guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }; return Int(args[i + 1]) }
        let duration = bounded ? 3600 : argument("--session-start")
        let hold = bounded ? (argument("--bounded-test") ?? 5) : argument("--hold-seconds")
        guard let duration, SessionEngine.supportedDurations.contains(duration), hold == nil || (1...30).contains(hold!) else { fputs("Durée : 0, 3600, 7200 ou 10800 ; maintien borné : 1 à 30 secondes.\n", stderr); exit(1) }
        do { before = try power.read(); emit("before", before!) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { cleanup(code: 0) }; source.resume(); signals.append(source)
        }
        client.onDisconnect = { error in fputs("\(error.localizedDescription)\n", stderr); cleanup(code: 1) }
        client.startSession(duration: duration, heartbeats: !args.contains("--without-heartbeats")) { result in
            switch result {
            case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); cleanup(code: 1)
            case .success(let reply):
                emit("active-service", reply)
                guard reply.accepted && reply.snapshot.phase == .active else { exit(1) }
                do {
                    let active = try power.read(); emit("active", active)
                    guard active.sleepDisabled && before!.lowPower.keys.allSatisfy({ active.lowPower[$0] == 1 }) else { cleanup(code: 1); return }
                } catch { fputs("\(error.localizedDescription)\n", stderr); cleanup(code: 1); return }
                if let hold { DispatchQueue.main.asyncAfter(deadline: .now() + Double(hold)) { cleanup(code: 0) } }
            }
        }
    }
    withExtendedLifetime((client, signals)) { RunLoop.main.run() }
    return true
}
