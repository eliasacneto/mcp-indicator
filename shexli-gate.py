#!/usr/bin/env python3
"""Fail unless Shexli reported zero findings."""
import json
import sys

result = json.load(open(sys.argv[1], encoding='utf-8'))
findings = result.get('findings') or []
if not findings:
    print('shexli: clean (0 findings)')
    sys.exit(0)

for item in findings:
    print(f"{item.get('severity')} {item['rule_id']}: {item['title']}", file=sys.stderr)
    for ev in item.get('evidence') or []:
        print(f"  {ev.get('path')}:{ev.get('line')}", file=sys.stderr)
sys.exit(1)
