"""Validate native resources without requiring the retired web renderer or Node."""
import argparse
import base64
import hashlib
import ast
import json
import math
from pathlib import Path
import plistlib
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

NATIVE_RESOURCES = ('AppIcon.icns', 'Cities.json', 'Strings.json')
PRODUCTION_ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.personal-information.calendars': True,
    'com.apple.security.network.client': True,
    'com.apple.security.temporary-exception.mach-lookup.global-name': [
        'io.github.ninejh.hannuncalendar-spks', 'io.github.ninejh.hannuncalendar-spki'],
}


def require(good, message):
    if not good:
        raise ValueError(message)


def regular(path):
    require(not path.is_symlink() and not any(p.is_symlink() for p in path.parents)
            and path.is_file(), 'Expected regular file without symlinks: ' + str(path))
    return path


def json_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate JSON key: ' + key)
        value[key] = item
    return value


def reject_constant(value):
    raise ValueError('Nonfinite JSON: ' + value)


def read_json(path):
    regular(path)
    return json.loads(path.read_text(), object_pairs_hook=json_object, parse_constant=reject_constant)


def validate_strings(value):
    require(isinstance(value, dict) and set(value) == {'en', 'ko'}, 'Expected English/Korean dictionaries')
    en, ko = value['en'], value['ko']
    require(isinstance(en, dict) and bool(en) and isinstance(ko, dict), 'Invalid translation dictionaries')
    require(all(isinstance(k, str) and isinstance(v, str) and v.strip() for k, v in en.items()),
            'English strings must be nonempty text')
    for key, text in ko.items():
        require(key in en and isinstance(text, str), 'Korean key lacks English fallback: ' + key)
        if text.strip():
            require(set(re.findall(r'\{([^{}]+)\}', text)) == set(re.findall(r'\{([^{}]+)\}', en[key])),
                    'Translation placeholder mismatch: ' + key)
    return en


def validate_cities(value):
    require(isinstance(value, list) and bool(value), 'City catalog must be a nonempty array')
    seen = set()
    for city in value:
        require(isinstance(city, dict) and set(city) == {'id', 'nameEN', 'nameKO', 'timeZone', 'latitude', 'longitude', 'aliases'},
                'Unexpected city fields')
        require(all(isinstance(city[k], str) and city[k].strip() for k in ('id', 'nameEN', 'nameKO', 'timeZone')),
                'Invalid city identity/name/time zone')
        require(city['id'] not in seen, 'Duplicate city ID: ' + city['id'])
        seen.add(city['id'])
        try:
            ZoneInfo(city['timeZone'])
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError('Invalid city time zone: ' + city['id']) from None
        for key, maximum in (('latitude', 90), ('longitude', 180)):
            number = city[key]
            require(type(number) in (int, float) and math.isfinite(number) and abs(number) <= maximum,
                    'Invalid city coordinate: ' + city['id'])
        require(isinstance(city['aliases'], list) and all(isinstance(x, str) and x for x in city['aliases']),
                'Invalid city aliases')


def validate_plist(info):
    require(info.get('CFBundleIdentifier') == 'io.github.ninejh.hannuncalendar', 'Unexpected production bundle ID')
    require(info.get('CFBundleExecutable') == 'HannunCalendar', 'Unexpected executable')
    require(info.get('CFBundleShortVersionString') == '1.0', 'Unexpected application version')
    updater_keys = {'SUFeedURL', 'SUPublicEDKey', 'SUEnableInstallerLauncherService',
                    'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed', 'SUSignedFeedFailureExpirationInterval',
                    'SUEnableSystemProfiling', 'SUShowReleaseNotes', 'SUEnableAutomaticChecks',
                    'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates'}
    require({key for key in info if key.startswith('SU')} == updater_keys, 'Unexpected updater plist keys')
    version = info.get('CFBundleVersion')
    require(isinstance(version, str) and version.isdecimal() and int(version) >= 2, 'Invalid monotonic updater build version')
    require(info.get('SUFeedURL') == 'https://hannun-calendar.vercel.app/appcast.xml', 'Unexpected update feed')
    try:
        public_key = base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)
    except (ValueError, TypeError):
        raise ValueError('Invalid update public key') from None
    require(len(public_key) == 32, 'Invalid update public key')
    require(hashlib.sha256(public_key).hexdigest() == '271600c76ea44b59bfcd8ea8f4d7308790919a5f05bb2adf557789a01f1056e1',
            'Unexpected update public key')
    for key in ('SUEnableInstallerLauncherService', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed', 'SUEnableAutomaticChecks'):
        require(info.get(key) is True, 'Missing updater security setting: ' + key)
    for key in ('SUEnableSystemProfiling', 'SUShowReleaseNotes', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates'):
        require(info.get(key) is False, 'Unexpected updater setting: ' + key)
    require(type(info.get('SUSignedFeedFailureExpirationInterval')) is int and info['SUSignedFeedFailureExpirationInterval'] == 0,
            'Signed feed failure must not expire')
    require(info.get('LSMinimumSystemVersion') == '14.0', 'Expected macOS 14 minimum')
    require(set(info.get('CFBundleLocalizations', [])) == {'en', 'ko'}, 'Missing supported localizations')


def validate_icon(icon):
    require(icon[:4] == b'icns' and int.from_bytes(icon[4:8], 'big') == len(icon), 'Invalid ICNS container')


def check(root, sources=()):
    resources = root / 'Resources'
    for name in NATIVE_RESOURCES:
        regular(resources / name)
    validate_icon((resources / 'AppIcon.icns').read_bytes())
    en = validate_strings(read_json(resources / 'Strings.json'))
    validate_cities(read_json(resources / 'Cities.json'))
    validate_plist(plistlib.loads(regular(resources / 'Info.plist').read_bytes()))
    require(plistlib.loads(regular(resources / 'HannunCalendar.entitlements').read_bytes()) == PRODUCTION_ENTITLEMENTS,
            'Unexpected production entitlements')
    for path in sources:
        if path.name == 'TestSupport.swift' or 'Testing' in path.relative_to(root / 'Sources').parts:
            continue  # Test-only missing-key fixtures deliberately exercise fallback.
        text = regular(path).read_text()
        for key in re.findall(r'\bt\("([\w.]+)"(?!\s*\+)', text):
            require(key in en, 'Missing native English key: ' + key + ' in ' + path.name)
    for folder in ('scripts', '.github'):
        for path in sorted((root / folder).rglob('*.py')):
            if '__pycache__' not in path.parts:
                ast.parse(regular(path).read_text(), filename=str(path))
    print(f'PASS: native resource allowlist, {len(en)} English keys, Korean placeholders, cities and plist')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    check(args.root)
