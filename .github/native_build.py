"""Shared, dependency-free native source/build/test policy used by the shell entry points."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import check_resources as resources
import verify_bundle

FRAMEWORKS = ('AppKit', 'EventKit', 'Combine', 'ServiceManagement', 'UserNotifications')
VALIDATOR_SOURCES = ('Core.swift',)  # Layout3/profile/resolver live in Foundation-only Core.
BASE = ('Core.swift', 'BoardModel.swift', 'CalendarService.swift', 'NativePreferences.swift', 'NativeColor.swift',
        'PanelDomain.swift', 'ExternalDataService.swift', 'ExternalCache.swift', 'NetworkBudget.swift',
        'CityCatalog.swift', 'WeatherProviderAdapter.swift', 'RateProviderAdapter.swift',
        'FocusService.swift', 'NotificationService.swift')
TARGETS = {
    'CoreTests': ('Core.swift',),
    'PanelDomainTests': ('Core.swift', 'PanelDomain.swift'),
    'ExternalDataTests': ('Core.swift', 'PanelDomain.swift', 'ExternalDataService.swift', 'ExternalCache.swift',
                          'NetworkBudget.swift', 'CityCatalog.swift', 'WeatherProviderAdapter.swift', 'RateProviderAdapter.swift'),
    'PanelServiceTests': ('Core.swift', 'PanelDomain.swift', 'FocusService.swift', 'NotificationService.swift'),
    'NativeApplicationTests': ('Application',),
    'CalendarRefreshTests': ('Application',),
    'UIKitNativeTests': ('Application', 'Presentation', 'UI/Kit'),
    'PresentationTests': ('Application', 'Presentation', 'UI/Kit'),
    'BoardLayoutTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Board', 'UI/Calendar'),
    'CalendarLayoutNativeTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Board', 'UI/Calendar'),
    'AgendaNotesTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Panels/Agenda', 'UI/Panels/Notes'),
    'ProjectDeadlineViewTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Panels/Projects', 'UI/Panels/Deadlines'),
    'OverlayTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Overlays'),
    'PanelEditingTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Panels/Subscriptions', 'UI/Panels/Todos', 'UI/Panels/Habits'),
    'ClockFocusViewTests': ('Application', 'Presentation', 'UI/Kit', 'UI/Panels/WorldClock', 'UI/Panels/Focus'),
    'AppCompositionTests': ('Application', 'Presentation', 'UI', 'App.swift', 'DesktopBridge.swift'),
    'NativeHostTests': ('Application', 'Presentation', 'UI', 'App.swift', 'DesktopBridge.swift', 'Testing', 'TestSupport.swift'),
}
GUI_TARGETS = set(TARGETS) - {'CoreTests', 'PanelDomainTests', 'ExternalDataTests', 'PanelServiceTests', 'NativeApplicationTests', 'CalendarRefreshTests'}
ALIASES = {'t012-domain': 'PanelDomainTests', 't014-external': 'ExternalDataTests', 't015-services': 'PanelServiceTests'}


def machine_capacity():
    logical = min(12, os.cpu_count() or 1)
    try:
        memory = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True, timeout=2))
    except (OSError, ValueError, subprocess.SubprocessError):
        memory = 8 * 1024**3  # Conservative fallback for an unfamiliar host.
    return logical, memory


def downward_override(name, default):
    value = os.environ.get(name, str(default))
    resources.require(value.isdecimal() and 1 <= int(value) <= default,
                      f'{name} must be an integer from 1 to {default} (downward override only)')
    return int(value)


def cpu_configuration():
    logical, memory = machine_capacity()
    capacity = downward_override('HANNUN_CPU_BUDGET', min(6, logical, max(1, (memory // 1024**3 - 4) // 2)))
    return (capacity, downward_override('HANNUN_SWIFT_JOBS', min(3, capacity)),
            downward_override('HANNUN_NATIVE_TARGET_JOBS', min(3, capacity)))


def available_memory():
    try:
        text = subprocess.check_output(['vm_stat'], text=True, timeout=2)
        page = int(re.search(r'page size of (\d+) bytes', text)[1])
        # Reclaimable inactive pages count; compressed/wired pages do not.
        return page * sum(int(re.search(r'Pages ' + name + r':\s+(\d+)', text)[1])
                          for name in ('free', 'inactive', 'speculative'))
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return None


def admission_slots(capacity, active, logical, load, memory):
    # Subtract managed reservations from load so our own jobs are not counted twice.
    cpu = max(0, logical - math.ceil(max(0, load - active)) - active)
    memory_slots = capacity if memory is None else max(0, (memory - 2 * 1024**3) // (1280 * 1024**2))
    return max(0, min(capacity - active, cpu, memory_slots))


def cpu_ticks():
    """macOS runnable load includes waiting tasks; use actual host CPU ticks."""
    try:
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        library.mach_host_self.restype = ctypes.c_uint
        info, count = (ctypes.c_uint32 * 4)(), ctypes.c_uint(4)
        if library.host_statistics(library.mach_host_self(), 3, info, ctypes.byref(count)) == 0:
            return list(info)  # user, system, idle, nice
    except OSError:
        pass
    return None


class CPUBudget:
    """FIFO weighted leases shared by every compiler() caller under this app root.

    The lease's flock FD is inherited by the Swift driver: killing a controller
    cannot make its still-running compiler's reservation disappear. No PID reuse
    heuristics, GUI locks, external daemon or third-party dependency are involved.
    """
    def __init__(self, root=ROOT, capacity=None, requested=None, pressure=True, timeout=None):
        configured, jobs, _ = cpu_configuration()
        self.capacity = capacity if capacity is not None else configured
        self.requested = min(requested if requested is not None else jobs, self.capacity)
        resources.require(1 <= self.requested <= self.capacity <= 12, 'Invalid shared CPU budget')
        self.folder = root / 'build/build-cpu/scheduler'
        resources.require(not any(p.is_symlink() for p in [self.folder, *self.folder.parents]), 'Symlink CPU budget path refused')
        self.folder.mkdir(parents=True, exist_ok=True)
        self.pressure = pressure
        self.timeout = float(timeout if timeout is not None else os.environ.get('HANNUN_CPU_WAIT_SECONDS', '1800'))
        resources.require(math.isfinite(self.timeout) and self.timeout > 0, 'CPU wait timeout must be positive and finite')

    def open_regular(self, path):
        return os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), 'r+')

    @contextmanager
    def state(self):
        with self.open_regular(self.folder / 'admission.lock') as mutex:
            fcntl.flock(mutex, fcntl.LOCK_EX)
            path = self.folder / 'state.json'
            resources.require(not path.is_symlink(), 'Symlink CPU state refused')
            entries = json.loads(path.read_text()) if path.exists() else []
            live = []
            for entry in entries:
                owner = self.folder / entry['id']
                with self.open_regular(owner) as stream:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        live.append(entry)
                    else:
                        owner.unlink()
            try:
                yield live
            finally:
                # The mutex has a stable inode; state replacement can be atomic.
                temp = self.folder / ('state-' + uuid.uuid4().hex)
                with self.open_regular(temp) as stream:
                    json.dump(live, stream); stream.flush()
                os.replace(temp, path)

    def event(self, kind, **fields):
        record = {'event': kind, 'time': subprocess.check_output(['date', '+%Y-%m-%d %H:%M %Z'], text=True).strip(),
                  'monotonicNS': time.monotonic_ns(), **fields}
        with self.open_regular(self.folder / 'events.jsonl') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.seek(0, os.SEEK_END)
            if stream.tell() > 4 * 1024**2:
                stream.seek(0); stream.truncate()
            stream.write(json.dumps(record) + '\n'); stream.flush()

    def pressure_sample(self, logical):
        # Called under the shared admission mutex; sample at most four times/s.
        path = self.folder / 'cpu-pressure.json'
        with self.open_regular(path) as stream:
            previous = json.loads(stream.read() or 'null')
            now = time.monotonic()
            if previous and now - previous['sampled'] < .25:
                return previous['busy'], previous.get('memory'), previous.get('pressure', 1)
            current = cpu_ticks()
            if current is None:
                return 0, available_memory(), 1  # The hard hardware/memory cap still applies.
            if previous is None:
                previous = {'ticks': current}
                time.sleep(.05)
                current = cpu_ticks() or current
            delta = [(a-b) % 2**32 for a,b in zip(current, previous['ticks'])]
            busy = logical * (1 - delta[2] / sum(delta)) if sum(delta) else 0
            memory = available_memory()
            try:
                pressure = int(subprocess.check_output(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'],
                                                      text=True, timeout=2))
            except (OSError, ValueError, subprocess.SubprocessError):
                pressure = 1
            stream.seek(0); stream.truncate()
            json.dump({'ticks': current, 'sampled': now, 'busy': busy, 'memory': memory, 'pressure': pressure}, stream)
            return busy, memory, pressure

    @contextmanager
    def lease(self):
        identifier = 'lease-' + uuid.uuid4().hex
        owner_path = self.folder / identifier
        with self.open_regular(owner_path) as owner:
            fcntl.flock(owner, fcntl.LOCK_EX)
            entry = {'id': identifier, 'pid': os.getpid(), 'capacity': self.capacity, 'jobs': 0, 'policy': 2}
            try:
                with self.state() as entries: entries.append(entry)
                started = time.monotonic()
                while True:
                    with self.state() as entries:
                        active = sum(e['jobs'] for e in entries)
                        capacity = min(e['capacity'] for e in entries)
                        # A waiter from a superseded admission implementation
                        # cannot head-of-line block corrected invocations.
                        first = next((e['id'] for e in entries if not e['jobs'] and e.get('policy') == 2), None)
                        logical = min(12, os.cpu_count() or 1)
                        if self.pressure:
                            busy, memory, pressure = self.pressure_sample(logical)
                            pressure_cap = 0 if pressure >= 4 else min(2, capacity) if pressure >= 2 else capacity
                            slots = admission_slots(pressure_cap, active, logical, busy, memory)
                        else:
                            slots = capacity - active
                        if first == identifier and slots > 0:
                            self.jobs = min(self.requested, slots)
                            next(e for e in entries if e['id'] == identifier)['jobs'] = self.jobs
                            break
                    if time.monotonic() - started >= self.timeout:
                        raise TimeoutError(f'CPU budget wait exceeded {self.timeout:g}s; compiler NOT RUN')
                    time.sleep(.1)
                self.fd = owner.fileno()
                self.event('acquired', id=identifier, pid=os.getpid(), jobs=self.jobs, capacity=capacity,
                           activeJobs=active + self.jobs, waitedSeconds=time.monotonic() - started)
                yield self
            finally:
                with self.state() as entries:
                    entries[:] = [e for e in entries if e['id'] != identifier]
                owner_path.unlink(missing_ok=True)


def scheduled_swift(output, command):
    # Keep this wrapper in compiler() so native host/preflight callers also share
    # the budget, even though they launch the returned command themselves.
    return [sys.executable, str(Path(__file__).resolve()), 'swift', str(output), '--', *command]


def swift_job_plan(command, jobs, scratch):
    # This driver cannot multithread batch jobs. Do not pass -num-threads:
    # it is ignored with a warning, and does not describe real parallelism.
    planned = command + ['-j', str(jobs), '-enable-batch-mode', '-driver-batch-count', str(jobs)]
    if '-typecheck' not in command:
        # Swift 6.3.1's implicit temporary names disagree between the batch
        # frontend and linker. A map also isolates duplicate file basenames.
        mapping = {source: {'object': str(scratch / f'{index:04}.o')}
                   for index, source in enumerate(p for p in command if p.endswith('.swift'))}
        path = scratch / 'outputs.json'
        path.write_text(json.dumps(mapping))
        planned += ['-output-file-map', str(path)]
    result = subprocess.run(planned + ['-driver-print-jobs'], capture_output=True, text=True, check=True)
    frontends = [shlex.split(line) for line in result.stdout.splitlines() if ' -frontend ' in line]
    resources.require(bool(frontends), 'Swift driver reported no frontend jobs')
    partitions = [line.count('-primary-file') for line in frontends]
    resources.require(len(frontends) <= jobs, 'Swift driver did not honor bounded batch partitioning')
    return planned, partitions


def run_scheduled_swift(output, command):
    output.mkdir(parents=True, exist_ok=True)
    requested = min(cpu_configuration()[1], max(1, sum(p.endswith('.swift') for p in command)))
    with CPUBudget(requested=requested).lease() as lease, \
         tempfile.TemporaryDirectory(prefix='swift-driver-', dir=output) as folder:
        planned, partitions = swift_job_plan(command, lease.jobs, Path(folder))
        lease.event('driver', pid=os.getpid(), jobs=lease.jobs, frontendJobs=len(partitions),
                    primaryFiles=partitions, typecheck='-typecheck' in command, command=planned)
        process = subprocess.Popen(planned, start_new_session=True, pass_fds=(lease.fd,))
        try:
            code = process.wait()
        except BaseException:
            stop_unit_group(process)
            raise
        lease.event('finished', pid=os.getpid(), jobs=lease.jobs, exitCode=code)
        return code


class GUILockBlocked(RuntimeError):
    """The test never started because its separate GUI lock budget expired."""


LOCKED_UNIT_EXEC = '''import json,os,sys,time
ready,executable,*arguments=sys.argv[1:]
descriptor=os.open(ready,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(descriptor,'w') as stream:
    json.dump({'pid':os.getpid(),'acquiredNS':time.monotonic_ns()},stream)
    stream.flush()
    os.fsync(stream.fileno())
# The controller must authorize execution. EOF/cancellation can never launch a late test.
if sys.stdin.buffer.read(1)!=b'G': sys.exit(75)
os.execvp(executable,[executable,*arguments])
'''


def swift_sources(root, testing=False, components=False):
    folder = root / 'Sources'
    resources.require(folder.is_dir() and not folder.is_symlink(), 'Missing regular Sources directory')
    result = []
    for path in sorted(folder.rglob('*'), key=lambda p: p.relative_to(root).as_posix()):
        resources.require(not path.is_symlink(), 'Symlink source entry refused: ' + str(path))
        if path.suffix != '.swift' or not path.is_file():
            continue
        relative = path.relative_to(folder)
        if not testing and (relative.parts[0] == 'Testing' or relative.as_posix() == 'TestSupport.swift'):
            continue
        if components and relative.as_posix() in ('App.swift', 'DesktopBridge.swift', 'TestSupport.swift'):
            continue
        resources.regular(path)
        result.append(path)
    resources.require(bool(result), 'No Swift sources discovered')
    return result


def active_text(text, testing):
    """Filter known build guards; conservatively inspect both branches of other conditions."""
    visible, stack, output = True, [], []
    for line in text.splitlines():
        match = re.match(r'\s*#(if|elseif|else|endif)\b\s*(.*)', line)
        if not match:
            if visible:
                output.append(line)
            continue
        kind, expression = match.groups()
        expression = expression.split('//', 1)[0].strip()
        condition = testing if expression == 'HANNUN_TESTING' else not testing if expression == '!HANNUN_TESTING' else None
        if kind == 'if':
            stack.append([visible, condition])
            visible = visible and condition is not False
        elif kind in ('else', 'elseif'):
            resources.require(bool(stack), 'Unmatched Swift conditional')
            parent, taken = stack[-1]
            branch = (not taken if taken is not None else None) if kind == 'else' else condition
            visible = parent and taken is not True and branch is not False
            stack[-1][1] = True if taken is True or branch is True else None if taken is None or branch is None else False
        else:
            resources.require(bool(stack), 'Unmatched Swift endif')
            visible = stack.pop()[0]
    resources.require(not stack, 'Unclosed Swift conditional')
    return '\n'.join(output)


def validate_sources(paths, testing=False):
    for path in paths:
        text = active_text(path.read_text(), testing)
        # Comments are not dependency declarations. Literal test flags remain visible.
        text = re.sub(r'""".*?"""|"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*',
                      lambda m: '' if m.group().startswith(('/*', '//')) else m.group(), text, flags=re.S)
        resources.require(not re.search(r'\b(?:import\s+(?:WebKit|JavaScriptCore|SwiftUI)|WKWebView|WKScriptMessage|JSContext)\b', text),
                          'Retired web/hosting dependency in ' + str(path))
        if not testing:
            resources.require(not any(marker.decode() in text for marker in verify_bundle.TEST_MARKERS),
                              'Unguarded test control/fixture in production source: ' + str(path))


def compiler(output, testing=False, executable_tests=False, typecheck=False, optimized=False):
    command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors',
               '-target', os.uname().machine + '-apple-macosx14.0', '-module-cache-path', str(output / 'module-cache')]
    resources.require(not (output / 'module-cache').is_symlink(), 'Symlink module cache refused')
    (output / 'module-cache').mkdir(parents=True, exist_ok=True)
    if testing:
        command += ['-D', 'HANNUN_TESTING']
    if executable_tests:
        resources.require(testing, 'Executable unit tests also require HANNUN_TESTING')
        command += ['-D', 'HANNUN_EXECUTABLE_TESTS']
    if optimized:
        command += ['-O']
    if typecheck:
        command += ['-typecheck']
    for framework in FRAMEWORKS:
        command += ['-framework', framework]
    return scheduled_swift(output, command)


def snapshot(root, paths, workspace):
    """Preserve exact source bytes and #filePath-relative test fixtures under this run."""
    hashes = {}
    for path in paths:
        resources.regular(path)
        data = path.read_bytes()
        relative = path.relative_to(root)
        target = workspace / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[str(relative)] = hashlib.sha256(data).hexdigest()
    for path in paths:
        resources.require(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(root))],
                          'Input file was modified while snapshotting: ' + str(path))
    (workspace / 'source-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    return [workspace / path.relative_to(root) for path in paths]


def copy_resources(root, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for name in resources.NATIVE_RESOURCES:
        shutil.copyfile(resources.regular(root / 'Resources' / name), destination / name)
    shutil.copyfile(resources.regular(root / 'LICENSE'), destination / 'LICENSE')


@contextmanager
def staged_directory(output, prefix):
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=output))
    try:
        yield path
    except GUILockBlocked:
        print('Retained blocked test inputs: ' + str(path), file=sys.stderr)
        raise
    except BaseException:
        print('Retained failed build/test inputs: ' + str(path), file=sys.stderr)
        raise
    else:
        shutil.rmtree(path)


def run_check(root, output, components=False, testing=False):
    for path in sorted((root / 'scripts').glob('*.sh')):
        subprocess.run(['zsh', '-n', str(path)], check=True)
    sources = swift_sources(root, testing=testing, components=components)
    validate_sources(sources, testing=testing)
    resources.check(root, sources)
    output.mkdir(parents=True, exist_ok=True)
    # Typecheck a coherent immutable copy, like production/unit builds. W3 owners
    # may continue editing after admission without invalidating Swift's input files.
    with staged_directory(output, 'check-') as temporary:
        workspace = temporary / 'workspace'
        snapshot(root, sources + [root / 'scripts/MakeIcon.swift'], workspace)
        copied = [workspace / path.relative_to(root) for path in sources]
        command = compiler(temporary / 'sources', testing=testing, typecheck=True) + list(map(str, copied))
        icon = scheduled_swift(temporary / 'icon', ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-typecheck',
                        '-target', os.uname().machine + '-apple-macosx14.0', '-module-cache-path', str(temporary / 'icon-cache'),
                        str(workspace / 'scripts/MakeIcon.swift')])
        with ThreadPoolExecutor(max_workers=min(2, cpu_configuration()[2])) as pool:
            futures = [pool.submit(subprocess.run, cmd, check=True) for cmd in (command, icon)]
            for future in as_completed(futures): future.result()
        shutil.copyfile(workspace / 'source-sha256.json', output / 'check-source-sha256.json')
    print('PASS: ' + ('native components only; entry/composition NOT RUN' if components else 'native source/type/resource checks'))


def run_build(root, output):
    sources = swift_sources(root)
    validate_sources(sources)
    resources.check(root, sources)
    output.mkdir(parents=True, exist_ok=True)
    with staged_directory(output, 'stage-') as temporary:
        stage = Path(temporary)
        workspace = stage / 'workspace'
        inputs = sources + [root / 'Resources' / name for name in
                            (*resources.NATIVE_RESOURCES, 'Info.plist', 'HannunCalendar.entitlements')]
        snapshot(root, inputs + [root / 'LICENSE'], workspace)
        copied = [workspace / path.relative_to(root) for path in sources]
        app = stage / 'Hannun Calendar.app'
        binary = app / 'Contents/MacOS/HannunCalendar'
        binary.parent.mkdir(parents=True)
        # Relative production inputs prevent private build paths in Swift #filePath literals.
        relative_sources = [path.relative_to(workspace).as_posix() for path in copied]
        subprocess.run(compiler(stage, optimized=True) + relative_sources + ['-o', str(binary)],
                       cwd=workspace, check=True)
        copy_resources(workspace, app / 'Contents/Resources')
        shutil.copyfile(workspace / 'Resources/Info.plist', app / 'Contents/Info.plist')
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements',
                        str(workspace / 'Resources/HannunCalendar.entitlements'), str(app)], check=True)
        verify_bundle.verify(app)
        destination = output / app.name
        resources.require(not destination.is_symlink(), 'Symlink output application refused')
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(app), destination)
        shutil.copyfile(workspace / 'source-sha256.json', output / 'production-source-sha256.json')
    print('Built verified native production app: ' + str(destination))


def test_sources(root, name):
    group = TARGETS[name]
    paths = []
    entries = group if name in ('CoreTests', 'PanelDomainTests', 'ExternalDataTests', 'PanelServiceTests') else BASE + group
    for entry in entries:
        path = root / 'Sources' / entry
        if path.is_dir():
            paths.extend(sorted(path.rglob('*.swift')))
        elif path.is_file():
            paths.append(path)
        elif entry in ('DesktopBridge.swift', 'TestSupport.swift'):
            continue  # These transitional files may be deleted by their assigned owners.
        else:
            raise ValueError('Missing test source group: ' + str(path))
    if name not in ('CoreTests', 'PanelDomainTests', 'ExternalDataTests', 'PanelServiceTests'):
        paths.extend(sorted((root / 'Tests/Support').glob('*.swift')))
    paths = sorted(set(paths), key=lambda p: p.relative_to(root).as_posix())
    validate_sources(paths, testing=True)
    return paths + [resources.regular(root / 'Tests' / (name + '.swift'))]


def stop_unit_group(process):
    """Only this invocation's fresh process group, never the existing lock owner."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=10)


def gui_lock_owner(lock, waiter_pid):
    """Best-effort PID/executable only; avoid printing arbitrary command arguments."""
    try:
        result = subprocess.run(['/usr/sbin/lsof', '-n', '-Fpcfl', str(lock)], capture_output=True, text=True, timeout=1)
        records, locked, pid = {}, set(), '?'
        for line in result.stdout.splitlines():
            if line.startswith('p'): pid = line[1:]
            elif line.startswith('c'): records[pid] = line[1:]
            elif line.startswith('l') and line[1:] in ('W', 'w', 'R', 'r'):
                locked.add(pid)
        # macOS lsof can omit flock state ("l "). Show other open handles as
        # candidates rather than claiming every queued waiter is the owner.
        candidates = {pid: name for pid, name in records.items() if pid != str(waiter_pid)}
        selected = {pid: name for pid, name in candidates.items() if pid in locked}
        if not candidates:
            return 'owner unavailable'
        prefix = '' if selected else 'open-handle candidates: '
        return prefix + ', '.join('PID=' + pid + ' command=' + name for pid, name in (selected or candidates).items())
    except (OSError, subprocess.SubprocessError):
        return 'owner unavailable'


def run_gui_unit_command(command, cwd, timeout):
    lock = Path(command[2])
    resources.require(lock.is_absolute() and not any(p.is_symlink() for p in [lock, *lock.parents]),
                      'GUI lock requires an absolute regular path')
    lock_timeout = float(os.environ.get('HANNUN_GUI_LOCK_TIMEOUT_SECONDS', '1800'))
    resources.require(math.isfinite(lock_timeout) and lock_timeout > 0, 'GUI lock timeout must be positive and finite')
    with tempfile.TemporaryDirectory(prefix='gui-lock-', dir=Path(cwd).resolve()) as folder:
        ready = Path(folder) / 'acquired.json'
        locked = command[:3] + [sys.executable, '-c', LOCKED_UNIT_EXEC, str(ready), *command[3:]]
        started = time.monotonic_ns()
        deadline = started + int(lock_timeout * 1e9)
        process = subprocess.Popen(locked, cwd=cwd, start_new_session=True, stdin=subprocess.PIPE, bufsize=0)
        try:
            acquired, announced = None, False
            while process.poll() is None:
                if ready.exists():
                    try:
                        acquired = json.loads(ready.read_text())
                    except json.JSONDecodeError:
                        pass  # The child has not finished its tiny acquisition record yet.
                    if acquired is not None:
                        resources.require(type(acquired.get('pid')) is int and type(acquired.get('acquiredNS')) is int,
                                          'Invalid GUI lock acquisition record')
                        if acquired['acquiredNS'] <= deadline:
                            break
                now = time.monotonic_ns()
                if not announced and now - started >= 100_000_000:
                    print(f'WAIT: GUI lock {lock}; {gui_lock_owner(lock, process.pid)}; wait limit {lock_timeout:g}s; '
                          f'execution budget {timeout:g}s starts after acquisition', file=sys.stderr, flush=True)
                    announced = True
                if now >= deadline or acquired is not None:
                    raise GUILockBlocked(f'BLOCKED: GUI lock {lock}; wait limit {lock_timeout:g}s exceeded; test executable NOT RUN')
                time.sleep(.01)
            if acquired is None:
                code = process.wait()
                if code:
                    raise subprocess.CalledProcessError(code, locked)
                raise ValueError('GUI lock handshake missing; test executable NOT RUN')
            print(f'GUI lock acquired after {(acquired["acquiredNS"] - started) / 1e9:.3f}s; '
                  f'starting {Path(command[3]).name} (execution timeout {timeout:g}s)', file=sys.stderr, flush=True)
            process.stdin.write(b'G'); process.stdin.close()
            # The 180-second executable budget begins only after acquisition/authorization.
            code = process.wait(timeout=timeout)
        except BaseException:
            stop_unit_group(process)
            raise
        finally:
            if not process.stdin.closed:
                process.stdin.close()
        if code:
            raise subprocess.CalledProcessError(code, command)


def run_unit_command(command, cwd, timeout=180, lease_fd=None):
    if len(command) >= 4 and Path(command[0]).name == 'lockf' and command[1] == '-k':
        return run_gui_unit_command(command, cwd, timeout)
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True,
                               **({'pass_fds': (lease_fd,)} if lease_fd is not None else {}))
    try:
        code = process.wait(timeout=timeout)
    except BaseException:
        stop_unit_group(process)
        raise
    if code:
        raise subprocess.CalledProcessError(code, command)


def run_cpu_unit_command(command, cwd):
    with CPUBudget(requested=1).lease() as lease:
        run_unit_command(command, cwd, lease_fd=lease.fd)


def prepare_executable_test(root, output, name):
    sources = test_sources(root, name)
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=name + '-', dir=output))
    try:
        workspace = work / 'workspace'
        extra = [root / 'Resources' / n for n in resources.NATIVE_RESOURCES] + [root / 'LICENSE']
        extra += sorted((root / 'Tests/Fixtures').rglob('*'))
        extra = [p for p in extra if p.is_file()]
        snapshot(root, sources + extra, workspace)
        (workspace / 'build/tests').mkdir(parents=True, exist_ok=True)
        app = work / (name + '.app')
        binary = app / 'Contents/MacOS' / name
        binary.parent.mkdir(parents=True)
        copied = [workspace / p.relative_to(root) for p in sources]
        subprocess.run(compiler(work, testing=True, executable_tests=True) + list(map(str, copied)) + ['-o', str(binary)], check=True)
        copy_resources(workspace, app / 'Contents/Resources')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.github.ninejh.hannuncalendar.tests.' + name.lower(),
            'CFBundleExecutable': name, 'CFBundlePackageType': 'APPL', 'LSUIElement': True}))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        (work / 'build-provenance.json').write_text(json.dumps({
            'builtAt': subprocess.check_output(['date', '+%Y-%m-%d %H:%M %Z'], text=True).strip(),
            'target': name, 'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'sourceHashes': json.loads((workspace / 'source-sha256.json').read_text()),
        }, indent=2) + '\n')
    except BaseException:
        print('Retained failed build/test inputs: ' + str(work), file=sys.stderr)
        raise
    return work, workspace, binary


def execute_prepared_test(root, output, name, prepared):
    work, workspace, binary = prepared
    command = [str(binary)]
    if name in GUI_TARGETS:
        command = ['lockf', '-k', str(root / 'build/gui.lock')] + command
    print(('Prepared ' + name + '; waiting for GUI execution') if name in GUI_TARGETS else 'Running ' + name, flush=True)
    try:
        if name in GUI_TARGETS:
            run_unit_command(command, workspace)
        else:
            run_cpu_unit_command(command, workspace)
        shutil.copyfile(workspace / 'source-sha256.json', output / (name + '-source-sha256.json'))
        shutil.copyfile(work / 'build-provenance.json', output / (name + '-build.json'))
    except BaseException:
        print('Retained failed/blocked test inputs: ' + str(work), file=sys.stderr)
        raise
    else:
        shutil.rmtree(work)


def run_executable_test(root, output, name):
    execute_prepared_test(root, output, name, prepare_executable_test(root, output, name))


def run_tools_tests(root, output):
    output.mkdir(parents=True, exist_ok=True)
    with staged_directory(output, 'BuildToolsTests-') as work:
        run_tools_tests_in_workspace(root, work)


def run_tools_tests_in_workspace(root, output):
    for script in ('.github/tests/test_native_build.py', 'scripts/test_native_runner.py', 'scripts/test_e2e_runner.py'):
        subprocess.run([sys.executable, str(resources.regular(root / script))], check=True,
                       env={**os.environ, 'HANNUN_BUILD_DIR': str(output), 'PYTHONDONTWRITEBYTECODE': '1'})
    binary = output / 'ValidateBoard'
    subprocess.run(compiler(output) + [str(root / 'Sources' / name) for name in VALIDATOR_SOURCES] + [str(root / 'scripts/ValidateBoard.swift'),
                                     '-o', str(binary)], check=True)
    run_cpu_unit_command([str(binary), '--self-test'], output)
    # The actual CLI decoder handles pipes, invalid arguments and bounded input.
    with CPUBudget(requested=1).lease() as lease:
        for data, expected in ((b'{"version":1,"notes":"sample"}', 0), (b'{bad', 1),
                               (b'{"version":999}', 1), (b'x' * (8 * 1024 * 1024 + 1), 1)):
            result = subprocess.run([str(binary)], input=data, capture_output=True, pass_fds=(lease.fd,))
            resources.require(result.returncode == expected, 'ValidateBoard CLI failure propagation mismatch')
    icon = output / 'MakeIcon'
    command = compiler(output)
    command.remove('-parse-as-library')
    subprocess.run(command + [str(root / 'scripts/MakeIcon.swift'), '-o', str(icon)], check=True)
    run_cpu_unit_command([str(icon), str(output / 'icon-test.png')], output)
    resources.require((output / 'icon-test.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Icon helper did not produce PNG')
    with CPUBudget(requested=1).lease() as lease:
        resources.require(subprocess.run([str(icon)], capture_output=True, pass_fds=(lease.fd,)).returncode == 64,
                          'Icon usage must fail without output')
    print('PASS: native parser executable/CLI (4 cases), icon executable and Python build-policy tests')


def run_tests(root, output, selected, list_only=False):
    unknown = sorted(p.stem for p in (root / 'Tests').glob('*.swift') if p.stem not in TARGETS)
    resources.require(not unknown, 'Unregistered executable test files: ' + ', '.join(unknown))
    names = [ALIASES.get(name, name) for name in selected] if selected else ['BuildToolsTests', *TARGETS]
    resources.require(len(names) == len(set(names)), 'Duplicate test selection')
    resources.require(set(names) <= set(TARGETS) | {'BuildToolsTests'}, 'Unknown native test target')
    missing, available_names = [], []
    for name in names:
        available = name == 'BuildToolsTests' or (root / 'Tests' / (name + '.swift')).is_file()
        reason = 'test file not present'
        if available and name in ('AppCompositionTests', 'NativeHostTests'):
            try:
                entry_sources = [resources.regular(root / 'Sources/App.swift')]
                bridge = root / 'Sources/DesktopBridge.swift'
                if bridge.is_file():
                    entry_sources.append(resources.regular(bridge))
                validate_sources(entry_sources, testing=True)
            except ValueError as error:
                available = False
                reason = 'native entry/composition not integrated: ' + str(error)
        if list_only:
            print(name + ': ' + ('available' if available else 'NOT RUN (' + reason + ')'))
        elif not available:
            missing.append(name)
            print('NOT RUN: ' + name + ': ' + reason, flush=True)
        else:
            available_names.append(name)
    if not list_only:
        # Preparation is independent of GUI execution. A queued GUI test holds
        # neither compiler tokens nor a preparation worker; later targets can build.
        workers = cpu_configuration()[2]
        errors = []
        with ThreadPoolExecutor(max_workers=workers) as compile_pool, \
             ThreadPoolExecutor(max_workers=workers) as pure_pool, \
             ThreadPoolExecutor(max_workers=1) as gui_pool:
            preparing = {compile_pool.submit(run_tools_tests if name == 'BuildToolsTests' else prepare_executable_test,
                                             root, output, *([] if name == 'BuildToolsTests' else [name])): name
                         for name in available_names}
            executing = []
            for future in as_completed(preparing):
                name = preparing[future]
                try:
                    prepared = future.result()
                    if name != 'BuildToolsTests':
                        pool = gui_pool if name in GUI_TARGETS else pure_pool
                        executing.append(pool.submit(execute_prepared_test, root, output, name, prepared))
                except BaseException as error:
                    errors.append(error)
            for future in as_completed(executing):
                try: future.result()
                except BaseException as error: errors.append(error)
        if errors:
            for error in errors[1:]: print('Additional native test failure: ' + str(error), file=sys.stderr)
            raise errors[0]
    if missing:
        print('INCOMPLETE: restore/implement the named tests and rerun; no missing test counted as PASS.', file=sys.stderr)
        return 2
    return 0


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == 'swift':
        resources.require(sys.argv[3] == '--', 'Invalid internal Swift scheduling command')
        # SIGTERM must unwind the lease and stop only this fresh compiler group.
        def cancelled(signum, frame): raise KeyboardInterrupt('Swift scheduling cancelled')
        signal.signal(signal.SIGTERM, cancelled)
        return run_scheduled_swift(Path(sys.argv[2]), sys.argv[4:])
    parser = argparse.ArgumentParser(description=__doc__, epilog='GUI lock wait: HANNUN_GUI_LOCK_TIMEOUT_SECONDS '
                                     '(default 1800); executable timeout starts after acquisition. BLOCKED lock exits 75.')
    parser.add_argument('action', choices=('check', 'build', 'test', 'sources'))
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('HANNUN_BUILD_DIR', str(ROOT / 'build'))))
    parser.add_argument('--components', action='store_true', help='check source libraries without the application entry/composition')
    parser.add_argument('--testing', action='store_true', help='typecheck/discover Testing with HANNUN_TESTING')
    parser.add_argument('--target', action='append', default=[])
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    root = Path(os.path.abspath(args.root))
    output = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    output = Path(os.path.abspath(output))
    resources.require(root / 'build' == output or root / 'build' in output.parents, 'Build output must be inside source build/')
    resources.require(not any(p.is_symlink() for p in [output, *output.parents]), 'Symlink build path refused')
    if args.action != 'sources':
        output.mkdir(parents=True, exist_ok=True)
    if args.action == 'check':
        run_check(root, output, args.components, args.testing)
    elif args.action == 'build':
        resources.require(not args.components and not args.testing, 'Production build cannot use components/testing mode')
        run_build(root, output)
    elif args.action == 'test':
        return run_tests(root, output, args.target, args.list)
    else:
        for path in swift_sources(root, args.testing, args.components):
            print(path)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except GUILockBlocked as error:
        print(str(error), file=sys.stderr)
        sys.exit(75)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('FAIL: native build tools: ' + str(error), file=sys.stderr)
        sys.exit(1)
