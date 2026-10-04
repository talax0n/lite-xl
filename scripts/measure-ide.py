#!/usr/bin/env python3
"""Measure the editor process itself; Git and shell children are excluded."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int)
parser.add_argument('--seconds', type=float, default=10)
args = parser.parse_args()
if args.seconds <= 0:
    parser.error('--seconds must be positive')


def read():
    values = subprocess.check_output(
        ['ps', '-p', str(args.pid), '-o', 'time=,rss='], text=True
    ).split()
    if len(values) != 2:
        raise SystemExit('Editor process is no longer running')
    timestamp, rss = values
    days = 0
    if '-' in timestamp:
        days, timestamp = timestamp.split('-', 1)
    parts = [float(part) for part in timestamp.split(':')]
    duration = 0
    for part in parts:
        duration = duration * 60 + part
    return int(days) * 86400 + duration, int(rss)


before, rss_before = read()
started = time.monotonic()
time.sleep(args.seconds)
after, rss_after = read()
elapsed = time.monotonic() - started
print(json.dumps({
    'elapsed_seconds': round(elapsed, 2),
    'cpu_seconds': round(after - before, 3),
    'average_cpu_percent_of_one_core': round(100 * (after - before) / elapsed, 2),
    'rss_mib_before': round(rss_before / 1024, 2),
    'rss_mib_after': round(rss_after / 1024, 2),
}, indent=2))
