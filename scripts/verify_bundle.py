"""Verify an ad hoc native production bundle without launching the application."""
import argparse
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


def inspect_bundle(app):
    require(not app.is_symlink(), 'Symlink application refused')
    expected = {'Contents/Info.plist', 'Contents/MacOS/HannunCalendar',
                'Contents/_CodeSignature/CodeResources', 'Contents/Resources/LICENSE'}
    expected.update('Contents/Resources/' + name for name in NATIVE_RESOURCES)
    found = set()
    directories = {'Contents', 'Contents/MacOS', 'Contents/Resources', 'Contents/_CodeSignature'}
    for path in app.rglob('*'):
        relative = path.relative_to(app).as_posix()
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


def verify(app):
    app = Path(os.path.abspath(app))
    binary = inspect_bundle(app)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                 capture_output=True, check=True)
    signature = subprocess.run(['codesign', '-d', '-v', str(app)], capture_output=True, text=True, check=True)
    validate_binary_metadata(
        subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True),
        subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True),
        subprocess.check_output(['otool', '-L', str(binary)], text=True),
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
