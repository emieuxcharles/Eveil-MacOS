#!/usr/bin/env python3
"""Developer-only, real bounded settings checks. Always restore through authenticated stop."""
import json, os, select, signal, subprocess, sys, time, tempfile
from pathlib import Path
APP = '/Applications/Eveil.app/Contents/MacOS/Eveil2'
LOG = Path(sys.argv[1] if len(sys.argv) > 1 else '/private/tmp/eveil2-sessions.json')
results = []
children = []
def run(*args, check=True):
    if args and args[0] in ('--register', '--unregister', '--restart-service'):
        # A harness deadline must not kill the owner of an uncancellable native operation.
        with tempfile.TemporaryFile(mode='w+') as output, tempfile.TemporaryFile(mode='w+') as error:
            process = subprocess.Popen([APP, *args], stdout=output, stderr=error, text=True)
            try:
                process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                raise RuntimeError(f'{args}: native operation remains owned by PID {process.pid}; not killed and not retried')
            output.seek(0); error.seek(0)
            result = subprocess.CompletedProcess([APP, *args], process.returncode, output.read(), error.read())
    else:
        result = subprocess.run([APP, *args], capture_output=True, text=True, timeout=35)
    if check and result.returncode:
        raise RuntimeError(f'{args}: exit={result.returncode}; stdout={result.stdout!r}; stderr={result.stderr!r}')
    return result
def settings():
    outputs = [subprocess.check_output(['/usr/bin/pmset', *args], text=True, timeout=5) for args in [('-g', 'custom'), ('-g',)]]
    current = None; low = {}; sleep = None
    for line in outputs[0].splitlines():
        if line.strip() in ['Battery Power:', 'AC Power:', 'UPS Power:']:
            current = line.strip()
        elif line.split()[:1] == ['lowpowermode']:
            low[current] = int(line.split()[1])
    for line in outputs[1].splitlines():
        if line.split()[:1] == ['SleepDisabled']:
            sleep = int(line.split()[1])
    assert low and sleep in (0, 1), outputs
    return {'lowPower': low, 'sleepDisabled': sleep}
def status():
    result = run('--session-status')
    return json.loads(result.stdout.removeprefix('reply ').strip())['snapshot']
def restored(before):
    after = settings()
    assert after['lowPower'] == before['lowPower'] and after['sleepDisabled'] == 0, (before, after)
    return after
def owner(extra=()):
    child = subprocess.Popen([APP, '--session-start', '3600', *extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    children.append(child)
    # Wait by service snapshot so Python text buffering cannot conceal readiness.
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise AssertionError(child.communicate())
        snapshot = status()
        if snapshot['phase'] == 'active':
            assert settings()['sleepDisabled'] == 1
            return child, snapshot
        time.sleep(.2)
    raise AssertionError('owner did not activate')
def idle(cause=None):
    deadline = time.monotonic() + 28
    while time.monotonic() < deadline:
        snapshot = status()
        if snapshot['phase'] == 'idle':
            if cause: assert snapshot.get('stopCause') == cause, snapshot
            return snapshot
        time.sleep(.5)
    raise AssertionError(snapshot)
def record(name, before, active, after, **extra):
    entry = dict(test=name, before=before, active=active, after=after, **extra)
    results.append(entry); LOG.write_text(json.dumps(results, indent=2)); print(name + ': PASS', flush=True)

initial = settings()
try:
    if '--helper-only' not in sys.argv:
        before = settings(); child, active = owner()
        child.terminate(); output, error = child.communicate(timeout=15)
        assert child.returncode == 0, (output, error)
        after_state = idle('user'); record('normal-controller-quit', before, active, restored(before), final=after_state)

        before = settings(); child, active = owner()
        observer = status(); assert observer['sessionID'] == active['sessionID'] and observer['ownerConnected']
        second = run('--session-start', '3600', '--hold-seconds', '1', check=False)
        assert second.returncode == 1 and status()['sessionID'] == active['sessionID'], second.stdout
        child.kill(); child.communicate(timeout=5)
        after_state = idle('disconnected'); record('killed-controller-and-second-owner-rejection', before, active, restored(before), final=after_state)

        before = settings(); child, active = owner(('--without-heartbeats',))
        started = time.monotonic(); observations = 0
        while True:
            current = status(); observations += 1
            if current['phase'] == 'idle': break
            assert time.monotonic() - started < 27, current
            time.sleep(2)
        assert current.get('stopCause') == 'heartbeatLost', current
        child.terminate(); child.communicate(timeout=15)
        record('read-only-observers-do-not-renew-heartbeat', before, active, restored(before), final=current, elapsedSeconds=round(time.monotonic()-started, 2), readOnlyObservations=observations)

    before = settings(); child, active = owner()
    old_proof = json.loads(run('--probe').stdout)
    run('--unregister')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        observed = settings()
        if observed['sleepDisabled'] == 0 and observed['lowPower'] == before['lowPower']: break
        time.sleep(.3)
    after = restored(before)
    deadline = time.monotonic() + 10
    while subprocess.run(['/bin/ps', '-p', str(old_proof['pid'])], capture_output=True).returncode == 0:
        assert time.monotonic() < deadline, 'old helper did not finish exiting'
        time.sleep(.3)
    registration = run('--register').stdout.strip(); assert registration == 'enabled', registration
    new_proof = json.loads(run('--probe').stdout)
    assert old_proof['pid'] != new_proof['pid']
    final = idle()
    child.terminate(); child.communicate(timeout=15)
    record('helper-graceful-restart-via-SMAppService', before, active, after, oldPID=old_proof['pid'], newPID=new_proof['pid'], final=final)
finally:
    # On a registration failure, preserve exact OS state for diagnosis rather than retrying.
    print('final registration:', run('--status', check=False).stdout.strip(), flush=True)
    stop = run('--session-stop', check=False)
    if stop.returncode != 0:
        print('cleanup service reply:', stop.stdout, stop.stderr, flush=True)
    for child in children:
        if child.poll() is None:
            child.kill(); child.communicate(timeout=5)
    final = settings()
    print('final settings:', json.dumps(final), flush=True)
    assert final['sleepDisabled'] == 0 and final['lowPower'] == initial['lowPower'], (stop.stdout, stop.stderr, initial, final)
