import Foundation
import EveilCore
let args = CommandLine.arguments
let lock: NativeLifecycleLock
do { lock = try NativeLifecycleLock(path: args[1]) }
catch { print("REFUSED"); exit(4) }
var status: RegistrationState = .enabled
if args[2] == "legacy-error" { print("unconfirmed legacy failure"); exit(1) }
let delay = Double(args[2])!
let coordinator = ServiceLifecycleCoordinator(unregister: { completion in
    print("UNREGISTER_CALLED"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if args.count > 3 { try! Data("callback".utf8).write(to: URL(fileURLWithPath: args[3])) }
        status = .notRegistered; completion(nil)
    }
}, register: { _ in fatalError("Fixture must not register") }, status: { status }, schedule: { seconds, operation in
    DispatchQueue.main.asyncAfter(deadline: .now() + (seconds == 2 ? 0.2 : seconds * 0.01), execute: operation)
})
let bridge = LifecycleCLIResult(coordinator: coordinator, expected: .notRegistered, emit: { print($0); fflush(stdout) }, terminate: { exit($0) })
coordinator.unregister(completion: bridge.complete)
withExtendedLifetime((lock, bridge)) { RunLoop.main.run() }
