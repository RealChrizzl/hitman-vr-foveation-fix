"""Read the production 3.290.1 literal profile as data; never execute PowerShell.

Used by Test-VerifiedProfiles.ps1. Requires only the Python standard library.
"""
import argparse
import json
import re
from pathlib import Path


def fields(body):
    result = {}
    for key, val in re.findall(r'(\w+)\s*=\s*"([^"\r\n]*)"', body):
        result[key] = val
    for key, val in re.findall(r'(\w+)\s*=\s*(0x[\da-fA-F]+|\d+)L?\b', body):
        result[key] = int(val, 0)
    for key, val in re.findall(r'(\w+)\s*=\s*\[byte\[\]\]\(([^)]*)\)', body):
        result[key] = [int(x.strip(), 0) for x in val.split(',')]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    source = args.source.read_text(encoding='utf-8-sig')
    region = source.split('$VERIFIED_BUILDS[1792593790] = [pscustomobject]@{', 1)[1]
    region = region.split('foreach ($build in $VERIFIED_BUILDS.Values)', 1)[0]
    profile = fields(region.split('Code=@(', 1)[0])
    for key, end in [('Code', 'Guards=@('), ('Contexts', 'Hooks=@('), ('Hooks', None)]:
        body = region.split(key + '=@(', 1)[1]
        if end:
            body = body.split(end, 1)[0]
        profile[key] = [fields(x) for x in re.findall(r'\[pscustomobject\]@\{(.*?)\}', body, re.S)]
    assert 'Guards=@()' in region, 'Review new guard table parsing'
    profile['Guards'] = []
    assert len(profile['Code']) == 8 and len(profile['Contexts']) == 13 and len(profile['Hooks']) == 3
    legacy = source.split('$VERIFIED_BUILDS[$VERIFIED_TIMESTAMP] = [pscustomobject]@{', 1)[1].split('\n}', 1)[0]
    for expected in ['Code=@($VERIFIED_CODE)', 'Guards=@($VERIFIED_GUARDS)',
                     'Contexts=@($VERIFIED_DIAGNOSTIC_CONTEXTS)',
                     'Hooks=@($COPY_DEPTH_CALL_A,$COPY_DEPTH_CALL_B,$TRANSPARENT_PASS_CALL)']:
        assert expected in legacy, 'Legacy profile routing changed: ' + expected
    print(json.dumps(profile))


if __name__ == '__main__':
    main()
