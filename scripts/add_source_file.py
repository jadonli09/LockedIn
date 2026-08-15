#!/usr/bin/env python3
"""Register new .swift files with the boringNotch app target.

Usage: add_source_file.py <group-name> <FileName.swift> [<group-name> <FileName.swift> ...]
Group name must match an existing PBXGroup (e.g. managers, components, extensions,
helpers, models, observers). The file must already exist inside that folder on disk.
"""
import re, sys, secrets

PBX = 'boringNotch.xcodeproj/project.pbxproj'

def newid():
    return secrets.token_hex(12).upper()

def main():
    args = sys.argv[1:]
    assert args and len(args) % 2 == 0, __doc__
    src = open(PBX).read()

    for group, fname in zip(args[::2], args[1::2]):
        if re.search(r'/\* ' + re.escape(fname) + r' \*/ = \{isa = PBXFileReference', src):
            print(f'skip {fname}: already referenced'); continue
        ref_id, build_id = newid(), newid()

        # PBXFileReference: insert before the End marker
        fileref = f'\t\t{ref_id} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fname}; sourceTree = "<group>"; }};\n'
        src = src.replace('/* End PBXFileReference section */', fileref + '/* End PBXFileReference section */')

        # PBXBuildFile
        buildfile = f'\t\t{build_id} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {fname} */; }};\n'
        src = src.replace('/* End PBXBuildFile section */', buildfile + '/* End PBXBuildFile section */')

        # group children: find the group block and its children list
        m = re.search(r'([0-9A-F]{24}) /\* ' + re.escape(group) + r' \*/ = \{\s*isa = PBXGroup;\s*children = \(\n', src)
        assert m, f'group {group} not found'
        insert_at = m.end()
        src = src[:insert_at] + f'\t\t\t\t{ref_id} /* {fname} */,\n' + src[insert_at:]

        # app target Sources phase (the XPC helper's phase is empty/synced)
        m = re.search(r'14CEF40E2C5CAED300855D72 /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \(\n', src)
        assert m, 'sources phase not found'
        insert_at = m.end()
        src = src[:insert_at] + f'\t\t\t\t{build_id} /* {fname} in Sources */,\n' + src[insert_at:]
        print(f'added {group}/{fname}')

    open(PBX, 'w').write(src)

if __name__ == '__main__':
    main()
