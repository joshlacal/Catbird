#!/usr/bin/env python3
"""Compare runtime receipts from normal and accessibility simulator text sizes."""
import json
import sys
from pathlib import Path

normal = json.loads(Path(sys.argv[1]).read_text())
accessible = json.loads(Path(sys.argv[2]).read_text())
assert normal['passed'] == accessible['passed'] == 40
assert normal['preferredContentSizeCategory'] != accessible['preferredContentSizeCategory']
assert 'Accessibility' in accessible['preferredContentSizeCategory']
expected = {'title1', 'title2', 'headline', 'body', 'bodyLarge', 'callout', 'caption', 'footnote'}
normal_roles = {row['role']: row for row in normal['samples']}
large_roles = {row['role']: row for row in accessible['samples']}
assert normal_roles.keys() == large_roles.keys() == expected
for role in sorted(expected):
    before = normal_roles[role]
    after = large_roles[role]
    assert after['dynamicHeight'] > before['dynamicHeight'], f'{role} height did not grow with Dynamic Type'
    assert after['dynamicWidth'] > before['dynamicWidth'], f'{role} width did not grow with Dynamic Type'
    assert after['normalHeight'] == before['normalHeight'], f'{role} ignored disabled Dynamic Type'
    assert after['normalWidth'] == before['normalWidth'], f'{role} ignored disabled Dynamic Type'
    print(f"{role}: Dynamic Type {before['dynamicWidth']}x{before['dynamicHeight']} -> {after['dynamicWidth']}x{after['dynamicHeight']}; disabled size unchanged")
print('PASS: 80 preference checks and 32 cross-launch Dynamic Type assertions')
