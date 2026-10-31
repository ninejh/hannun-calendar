"""Verify an ad hoc native production bundle without launching the application."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from check_resources import (NATIVE_RESOURCES, PRODUCTION_ENTITLEMENTS, read_json, regular,
                             require, validate_cities, validate_icon, validate_plist, validate_strings)

TEST_MARKERS = (b'--fixture', b'--scratch-root', b'--scenario', b'testControl', b'__hannunTest',
                b'--suite', b'--native-tests', b'--runner-dom-probe',
                b'Test exceeded 90 seconds', b'WKWebView', b'WKScriptMessage')


SPARKLE_MANIFEST_SHA256 = 'd66c838f412e29e252f92d02c09bd670047892b2af3ca01c524ce1be0c74921e'
SPARKLE_VENDOR = Path(__file__).resolve().parents[1] / 'Vendor/Sparkle'
SPARKLE_LICENSE_SHA256 = '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe'
# These are the only files modified when re-signing the official framework.
SIGNED_MEMBERS = {
    'Versions/B/Sparkle', 'Versions/B/Autoupdate',
    'Versions/B/Updater.app/Contents/MacOS/Updater',
    'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
    'Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
}


def sparkle_manifest():
    data = regular(SPARKLE_VENDOR / 'framework-manifest.json').read_bytes()
    require(hashlib.sha256(data).hexdigest() == SPARKLE_MANIFEST_SHA256, 'Sparkle manifest digest mismatch')
    return json.loads(data)


def inspect_sparkle(framework, signed=False):
    require(framework.is_dir() and not framework.is_symlink(), 'Missing regular Sparkle framework')
    expected, actual = sparkle_manifest(), {}
    for folder, dirs, files in os.walk(framework, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            relative = path.relative_to(framework).as_posix()
            require(relative in expected, 'Unexpected Sparkle member: ' + relative)
            entry = expected[relative]
            if path.is_symlink():
                require(entry['type'] == 'symlink' and os.readlink(path) == entry['target'], 'Unsafe Sparkle symlink: ' + relative)
                require(path.resolve().is_relative_to(framework.resolve()), 'Escaping Sparkle symlink: ' + relative)
            elif path.is_dir():
                require(entry['type'] == 'dir', 'Unexpected Sparkle directory: ' + relative)
            else:
                require(path.is_file() and entry['type'] == 'file', 'Unexpected Sparkle file: ' + relative)
                require(bool(path.stat().st_mode & 0o111) == entry['executable'], 'Sparkle executable mode mismatch: ' + relative)
                if not signed or (relative not in SIGNED_MEMBERS and '/_CodeSignature/' not in '/' + relative):
                    require(hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], 'Sparkle member hash mismatch: ' + relative)
            actual[relative] = True
    require(set(actual) == set(expected), 'Sparkle inventory mismatch')


def verify_sparkle_code(framework):
    for relative in ('Versions/B/XPCServices/Installer.xpc', 'Versions/B/XPCServices/Downloader.xpc',
                     'Versions/B/Autoupdate', 'Versions/B/Updater.app', '.'):
        subprocess.run(['codesign', '--verify', '--strict', str((framework / relative).resolve())], check=True)


def inspect_bundle(app):
    require(not app.is_symlink(), 'Symlink application refused')
    expected = {'Contents/Info.plist', 'Contents/MacOS/HannunCalendar',
                'Contents/_CodeSignature/CodeResources', 'Contents/Resources/LICENSE'}
    expected.update('Contents/Resources/' + name for name in NATIVE_RESOURCES)
    expected.add('Contents/Resources/Sparkle-LICENSE')
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    inspect_sparkle(framework, signed=True)
    found = set()
    directories = {'Contents', 'Contents/MacOS', 'Contents/Resources', 'Contents/_CodeSignature'}
    for path in app.rglob('*'):
        relative = path.relative_to(app).as_posix()
        if relative == 'Contents/Frameworks':
            require(path.is_dir() and not path.is_symlink(), 'Unsafe Frameworks directory')
            continue
        if relative == 'Contents/Frameworks/Sparkle.framework' or relative.startswith('Contents/Frameworks/Sparkle.framework/'):
            continue  # Only this exact subtree was checked by inspect_sparkle above.
        require(not path.is_symlink(), 'Symlink bundle member refused: ' + relative)
        if path.is_dir():
            require(relative in directories, 'Unexpected bundle directory: ' + relative)
        else:
            regular(path)
            found.add(relative)
    require(found == expected, 'Native bundle inventory differs: missing=' + str(sorted(expected - found))
            + ', unexpected=' + str(sorted(found - expected)))
    validate_plist(plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
    resource_dir = app / 'Contents/Resources'
    validate_strings(read_json(resource_dir / 'Strings.json'))
    validate_cities(read_json(resource_dir / 'Cities.json'))
    validate_icon((resource_dir / 'AppIcon.icns').read_bytes())
    require((resource_dir / 'LICENSE').read_text().startswith('MIT License'), 'Missing MIT license notice')
    license_data = (resource_dir / 'Sparkle-LICENSE').read_bytes()
    require(hashlib.sha256(license_data).hexdigest() == SPARKLE_LICENSE_SHA256, 'Missing or modified Sparkle license')
    binary = app / 'Contents/MacOS/HannunCalendar'
    require(os.access(binary, os.X_OK), 'Production executable is not executable')
    data = binary.read_bytes()
    require(not any(marker in data for marker in TEST_MARKERS), 'Test control/fixture code leaked into production')
    return binary


def validate_binary_metadata(architectures, build_version, libraries, signature, entitlements, arch):
    require(architectures.split() == [arch], 'Expected a single host architecture')
    require(re.search(r'\bminos\s+14\.0(?:\.0)?\b', build_version), 'Expected macOS 14 deployment target')
    require(not any(name + '.framework' in libraries for name in ('WebKit', 'JavaScriptCore', 'SwiftUI')),
            'Forbidden web/hosting framework in native production binary')
    for name in ('AppKit', 'EventKit', 'ServiceManagement', 'UserNotifications'):
        require(name + '.framework' in libraries, 'Missing native framework: ' + name)
    require('Signature=adhoc' in signature, 'Expected local ad hoc signature')
    require(entitlements == PRODUCTION_ENTITLEMENTS, 'Unexpected production entitlements')


SYSTEM_FRAMEWORKS = frozenset(('AppKit', 'EventKit', 'Combine', 'Foundation', 'CFNetwork', 'CoreFoundation', 'CoreGraphics',
                               'CryptoKit', 'ImageIO', 'QuartzCore', 'ServiceManagement', 'UserNotifications'))


def verify_linked_libraries(libraries):
    entries = []
    for line in libraries.splitlines()[1:]:
        match = re.match(r'\s*(\S+)\s+\(', line)
        require(match is not None, 'Unparseable dynamic library entry')
        path = match.group(1)
        system = re.fullmatch(r'/System/Library/Frameworks/([A-Za-z0-9]+)\.framework/Versions/[A-Za-z0-9]+/\1', path)
        swift = re.fullmatch(r'/usr/lib/swift/libswift[A-Za-z0-9_]+\.dylib', path)
        allowed = (path == '@rpath/Sparkle.framework/Versions/B/Sparkle' or
                   path in ('/usr/lib/libSystem.B.dylib', '/usr/lib/libobjc.A.dylib', '/usr/lib/libc++.1.dylib') or
                   (system is not None and system.group(1) in SYSTEM_FRAMEWORKS) or swift is not None)
        require(allowed, 'Unexpected dynamic library: ' + path)
        entries.append(path)
    require('@rpath/Sparkle.framework/Versions/B/Sparkle' in entries, 'Missing linked Sparkle framework')


def verify_runpaths(load_commands):
    paths = re.findall(r'\bcmd LC_RPATH\s+cmdsize \d+\s+path (\S+) \(offset \d+\)', load_commands)
    require(paths.count('@executable_path/../Frameworks') == 1 and paths.count('/usr/lib/swift') <= 1
            and all(path in ('@executable_path/../Frameworks', '/usr/lib/swift') for path in paths),
            'Unexpected executable runpath')


def verify(app):
    app = Path(os.path.abspath(app))
    binary = inspect_bundle(app)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    verify_sparkle_code(app / 'Contents/Frameworks/Sparkle.framework')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                 capture_output=True, check=True)
    signature = subprocess.run(['codesign', '-d', '-v', str(app)], capture_output=True, text=True, check=True)
    libraries = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    verify_linked_libraries(libraries)
    verify_runpaths(subprocess.check_output(['otool', '-l', str(binary)], text=True))
    validate_binary_metadata(
        subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True),
        subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True),
        libraries,
        signature.stdout + signature.stderr, plistlib.loads(entitlements.stdout), os.uname().machine)
    print('PASS: native resource inventory, host architecture/macOS14, ad hoc signature, entitlements, no WebKit/test injection')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        verify(args.app)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print('FAIL: production bundle: ' + str(error), file=sys.stderr)
        sys.exit(1)
