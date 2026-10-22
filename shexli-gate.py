#!/usr/bin/env python3
"""Fail if Shexli reported errors or warnings. manual_review is allowed."""
import json
import sys

result = json.load(open(sys.argv[1], encoding='utf-8'))
findings = result.get('findings') or []
review = [f for f in findings if f.get('severity') == 'manual_review']
bad = [f for f in findings if f.get('severity') in ('error', 'warning')]

for item in review:
    print(f"manual_review {item['rule_id']}: {item['title']}")

if bad:
    for item in bad:
        print(f"{item['severity']} {item['rule_id']}: {item['title']}", file=sys.stderr)
        for ev in item.get('evidence') or []:
            print(f"  {ev.get('path')}:{ev.get('line')}", file=sys.stderr)
    sys.exit(1)

print('shexli: no errors or warnings')
