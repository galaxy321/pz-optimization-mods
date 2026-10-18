"""Compare two Test Ground runs.

python3 test-ground/compare.py TestGround_before_123.txt TestGround_after_456.txt

Prints, per step (median over the plan's repeats): fps, p99 frame, hitches and Lua ms/s for both
runs, the mods whose Lua cost changed most, the mods that were on in only one run, and every
Walk To case whose outcome differs. The traces (<report>_trace.txt, found next to the reports)
are compared for Walk To outcomes and walk-leg arrivals.
"""
import os
import re
import statistics
import sys

STEP = re.compile(r'^== pass (\d+) step (\d+): (.+?) \((\d+) s\)')
FRAMES = re.compile(r'^frames: (\d+), ([\d.]+) fps, mean ([\d.]+) ms, p50 (\d+), p95 (\d+), p99 (\d+), worst (\d+) ms, (\d+) over 33 ms, (\d+) hitches')
LUA = re.compile(r'Lua in handlers: ([\d.]+) ms/s')
MODLINE = re.compile(r'^\[LuaEventProfiler\]\s+([\d.]+) ms/s\s+\d+ calls\s+[\d.]+ us/call max\s+\d+ ms\s+\[([^\]]+)\] (\S+)$')
WALKTO = re.compile(r'walkto (\S+): (arrive|fail)')
# 18 Oct: the baseline's steps are keyed by their name, with the names from before Test Ground 1.13.7
# mapped to the new ones, so runs from before and after the rename line up. A row whose two runs ran
# different step lines (glide_fog was 40 s, now 60 s) is marked with * under the table.
NAME_MAP = {
    'drive': 'glide_south', 'drive_back': 'glide_north', 'drive_trees': 'glide_trees', 'drive_fog': 'glide_fog',
    'corpse_lay': 'setup_corpses', 'corpse_clear': 'cleanup_corpses', 'fight_real': 'fight_swing',
}
NUM = re.compile(r'^-?[\d.]+$')


def step_sig(text):
    """The step line without its name, in any order: what has to match for two rows to be the same step."""
    words = text.split()
    if not words or words[0] == 'weather':
        return tuple(words)
    at = [i for i, w in enumerate(words) if i > 0 and '=' not in w and not NUM.match(w)]
    return tuple(sorted(w for i, w in enumerate(words) if not at or i != at[-1]))


def step_key(text):
    words = text.split()
    if not words or words[0] == 'weather':
        return text
    names = [w for w in words[1:] if '=' not in w and not NUM.match(w)]
    name = names[-1] if names else text
    return NAME_MAP.get(name, name)


DRIVE = re.compile(r'^drive: left the street (\d+) times, .*?, (\d+) fresh cars, ')
# Test Ground 1.13.10 gave the legs-only average ("average N km/h in the car"); 1.13.11 on gives the
# whole drive ("average N km/h from the first car to the end") and the legs ("N km/h in the legs")
DRIVE_WHOLE = re.compile(r'; average (\d+) km/h from the first car')
DRIVE_LEGS = re.compile(r'; average (\d+) km/h in the car|, (\d+) km/h in the legs')


def parse(path):
    run = {'label': os.path.basename(path), 'steps': {}, 'order': [], 'mods': set(), 'walkto': {}, 'lines': {}, 'sigs': {}}
    cur = None
    section = None
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('mods: '):
                run['mods'] = set(m for m in line[6:].split(';') if m)
            m = STEP.match(line)
            if m:
                line_text = m.group(3).split(',')[0].strip()
                text = step_key(line_text)
                run['lines'][text] = line_text
                run['sigs'][text] = step_sig(line_text)
                cur = {'pass': int(m.group(1)), 'mods': {}}
                if text not in run['steps']:
                    run['steps'][text] = []
                    run['order'].append(text)
                run['steps'][text].append(cur)
                section = None
                continue
            if cur is None:
                w = WALKTO.search(line)
                continue
            m = FRAMES.match(line)
            if m:
                cur['fps'] = float(m.group(2))
                cur['p99'] = int(m.group(6))
                cur['worst'] = int(m.group(7))
                cur['hitches'] = int(m.group(9))
                # Test Ground 1.13.8+: a step with screenshots says its numbers include them
                cur['shots'] = 'NOT A MEASUREMENT' in line
                continue
            m = LUA.search(line)
            if m:
                cur['lua'] = float(m.group(1))
                continue
            m = DRIVE.match(line)
            if m:
                cur['off'], cur['fresh'] = int(m.group(1)), int(m.group(2))
                mw = DRIVE_WHOLE.search(line)
                if mw:
                    cur['avgkmh'] = int(mw.group(1))
                ml = DRIVE_LEGS.search(line)
                if ml:
                    cur['legkmh'] = int(ml.group(1) or ml.group(2))
                continue
            if line.endswith('-- by mod --'):
                section = 'mod'
                continue
            if line.endswith('-- by handler --'):
                section = 'handler'
                continue
            if section == 'mod':
                m = MODLINE.match(line)
                if m:
                    cur['mods'][m.group(2)] = float(m.group(1))
            w = WALKTO.search(line)
            if w:
                run['walkto'].setdefault(w.group(1), []).append(w.group(2))
    return run


def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def fmt(v, spec):
    return format(v, spec) if v is not None else '-'


def trace_events(report_path):
    path = report_path[:-4] + '_trace.txt'
    events = []
    if not os.path.exists(path):
        return None
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            body = parts[1].strip()
            if body.startswith('leg ') or body.startswith('walkto ') and ': ' in body or body.startswith('note '):
                # Drop timings and exact positions; keep what happened.
                body = re.sub(r' in [\d.]+ s', '', body)
                body = re.sub(r', [\d.]+ s, walked [\d.]+ tiles', '', body)
                body = re.sub(r' at [\d.]+,[\d.]+,(\d+)', r' floor \1', body)
                events.append(body)
    return events


def main(a_path, b_path):
    a, b = parse(a_path), parse(b_path)
    print(f'A: {a["label"]}')
    print(f'B: {b["label"]}')
    only_a, only_b = sorted(a['mods'] - b['mods']), sorted(b['mods'] - a['mods'])
    if only_a or only_b:
        print(f'mods only in A: {", ".join(only_a) or "-"}')
        print(f'mods only in B: {", ".join(only_b) or "-"}')
    print()
    print(f'{"step":<18} {"fps A":>7} {"fps B":>7} {"p99 A":>6} {"p99 B":>6} {"hitch A":>7} {"hitch B":>7} {"Lua A":>7} {"Lua B":>7}  (medians, Lua in ms/s)')
    shot_rows = []
    for text in a['order'] + [t for t in b['order'] if t not in a['steps']]:
        sa, sb = a['steps'].get(text, []), b['steps'].get(text, [])
        row = [med([s.get(k) for s in sa]) for k in ('fps', 'p99', 'hitches', 'lua')]
        rowb = [med([s.get(k) for s in sb]) for k in ('fps', 'p99', 'hitches', 'lua')]
        star = '*' if text in a['sigs'] and text in b['sigs'] and a['sigs'][text] != b['sigs'][text] else ''
        if any(s.get('shots') for s in sa + sb):
            star += '!'
            shot_rows.append(text)
        print(f'{text + star:<18} {fmt(row[0], ".1f"):>7} {fmt(rowb[0], ".1f"):>7} {fmt(row[1], ".0f"):>6} {fmt(rowb[1], ".0f"):>6} '
              f'{fmt(row[2], ".0f"):>7} {fmt(rowb[2], ".0f"):>7} {fmt(row[3], ".1f"):>7} {fmt(rowb[3], ".1f"):>7}')
        if any('off' in s for s in sa + sb):
            da = [med([s.get(k) for s in sa]) for k in ('off', 'fresh', 'avgkmh', 'legkmh')]
            db = [med([s.get(k) for s in sb]) for k in ('off', 'fresh', 'avgkmh', 'legkmh')]
            print(f'{"":<18}   drive: left the street {fmt(da[0], ".0f")} -> {fmt(db[0], ".0f")}, fresh cars {fmt(da[1], ".0f")} -> {fmt(db[1], ".0f")}, '
                  f'average km/h over the whole drive {fmt(da[2], ".0f")} -> {fmt(db[2], ".0f")}, in the legs {fmt(da[3], ".0f")} -> {fmt(db[3], ".0f")}')
        mods = set()
        for s in sa + sb:
            mods.update(s['mods'].keys())
        deltas = []
        for m in mods:
            va = med([s['mods'].get(m, 0.0) for s in sa]) or 0.0
            vb = med([s['mods'].get(m, 0.0) for s in sb]) or 0.0
            if abs(vb - va) >= 0.5:
                deltas.append((vb - va, m, va, vb))
        deltas.sort(key=lambda d: -abs(d[0]))
        for d, m, va, vb in deltas[:5]:
            print(f'{"":<18}   {m}: {va:.1f} -> {vb:.1f} ms/s ({d:+.1f})')
    if shot_rows:
        print(f'! {", ".join(shot_rows)}: screenshots were taken in this step in A or B, so its fps and hitches are not a measurement')
    marked = [t for t in a['sigs'] if t in b['sigs'] and a['sigs'][t] != b['sigs'][t]]
    for t in marked:
        print(f'* {t}: A ran "{a["lines"][t]}", B ran "{b["lines"][t]}"')
    print()
    cases = sorted(set(a['walkto']) | set(b['walkto']))
    diff = [(c, a['walkto'].get(c, []), b['walkto'].get(c, [])) for c in cases
            if a['walkto'].get(c) != b['walkto'].get(c)]
    if cases:
        print(f'Walk To cases: {len(cases)}, outcomes differ in {len(diff)}')
        for c, oa, ob in diff:
            print(f'  {c}: A {"/".join(oa) or "-"}  B {"/".join(ob) or "-"}')
    ta, tb = trace_events(a_path), trace_events(b_path)
    if ta is not None and tb is not None:
        same = ta == tb
        print(f'behaviour log: {"same events" if same else "events differ"} ({len(ta)} vs {len(tb)})')
        if not same:
            for i, (x, y) in enumerate(zip(ta, tb)):
                if x != y:
                    print(f'  first difference at event {i + 1}:\n    A: {x}\n    B: {y}')
                    break
            else:
                print('  one log is a prefix of the other')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
