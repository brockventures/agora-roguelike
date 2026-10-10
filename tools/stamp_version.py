#!/usr/bin/env python3
"""Write a version into `application/config/version` of a Godot project.godot.

Usage: tools/stamp_version.py game/project.godot 1.2.3
Idempotent: replaces an existing config/version line, else inserts one after
config/name in the [application] section.
"""
import re
import sys

VERSION_RE = re.compile(r'^[0-9A-Za-z][0-9A-Za-z.+_-]*$')


def stamp(text: str, version: str) -> str:
    if not VERSION_RE.match(version):
        raise ValueError(f'bad version {version!r}')
    line = f'config/version="{version}"'
    if re.search(r'^config/version=.*$', text, re.M):
        return re.sub(r'^config/version=.*$', line, text, count=1, flags=re.M)
    if not re.search(r'^\[application\]\s*$', text, re.M):
        raise ValueError('no [application] section')
    m = re.search(r'^(config/name=.*)$', text, re.M)
    if m:
        return text[:m.end()] + '\n' + line + text[m.end():]
    m = re.search(r'^\[application\]\s*$', text, re.M)
    return text[:m.end()] + '\n' + line + text[m.end():]


def main(argv) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, version = argv[1], argv[2]
    with open(path, encoding='utf-8') as f:
        text = f.read()
    with open(path, 'w', encoding='utf-8') as f:
        f.write(stamp(text, version))
    print(f'{path}: application/config/version = {version}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
