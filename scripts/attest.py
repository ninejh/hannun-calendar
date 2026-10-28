#!/usr/bin/env python3
"""Record the exact standalone build inputs and executable digest."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent

def hashes():
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file() and not {'build', '.git'}.intersection(p.relative_to(root).parts)}

command, filename = sys.argv[1:]
if command == 'before':
    Path(filename).write_text(json.dumps(hashes(), sort_keys=True))
elif command == 'after':
    before = json.loads(Path(filename).read_text())
    if before != hashes():
        raise SystemExit('Source inputs changed while compiling; discard the build.')
    binary = root / 'build/Hannun Calendar.app/Contents/MacOS/HannunCalendar'
    (root / 'build/build-attestation.json').write_text(json.dumps(
        {'inputs_sha256': before, 'executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()},
        indent=2, sort_keys=True) + '\n')
else:
    raise SystemExit('Unknown command')
