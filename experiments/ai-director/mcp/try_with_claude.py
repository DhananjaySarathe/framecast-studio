#!/usr/bin/env python3
"""Lets Claude Code (signed in with your own Claude plan) direct a Framecast test copy through framecast_mcp.py,
and times it. Run it through try-with-claude.sh, which builds fcctl and starts the test copy first.

  oneshot  one `claude -p` call per cue (pays the CLI start-up every time)
  live     one long-running `claude -p --input-format stream-json` session fed transcript lines, like a show

What leaves the Mac: the director prompt, the rundown below and the fake transcript lines go to Anthropic under
your own Claude login. Nothing else (no camera, screen or audio).
"""
import json, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
MODE = sys.argv[1] if len(sys.argv) > 1 else "live"
MODEL = os.environ.get("MODEL", "haiku")
EFFORT = os.environ.get("EFFORT", "low")
FCCTL = os.environ["FCCTL"]
work = tempfile.mkdtemp(prefix="framecast-ai-")
LOG, STATE = os.path.join(work, "mcp.log"), os.path.join(work, "state.json")

DIRECTOR = """You are the live director of a Framecast show. Each message is the newest line the presenter said.
Decide the shot with exactly one tool call, then answer with the single word done.
- If the line is a cue in the rundown, call switch_scene with that scene's exact name.
- Otherwise call hold with a five-word reason. Never switch for small talk.
Rundown (cue → scene):
- presenter is about to show a chart or benchmark → "Screen + camera"
- presenter asks to compare side by side or switch to the screen and camera together → "Split"
- presenter turns back to talk to the audience directly, asks a question or gives the verdict → "Camera"
- presenter says goodbye or thanks for watching → "Outro"
Lines come from live speech recognition and may have errors such as "OPA" for Opus or "sonic" for Sonnet."""

CUES = [  # (transcript line, scene we expect)
    ("Hi everyone, today we're putting Opus 5.5 and Sonnet 5.5 head to head.", None),
    ("Now let me show you the benchmark chart.", "Screen + camera"),
    ("On the coding tasks OPA is ahead by a few points, which is not a huge gap.", None),
    ("Let's put them side by side so you can see the speed difference.", "Split"),
    ("So which one should you pick? Here's my honest take.", "Camera"),
    ("That's it from me, thanks for watching and see you next week.", "Outro"),
]
TOOLS = ["get_show_state", "switch_scene", "hold"]
ALLOWED = ",".join(f"mcp__framecast__{t}" for t in TOOLS)

with open(os.path.join(work, "mcp.json"), "w") as f:
    json.dump({"mcpServers": {"framecast": {"command": sys.executable, "args": ["-I", os.path.join(HERE, "framecast_mcp.py")],
               "env": {"FCCTL": FCCTL, "FRAMECAST_STATE": STATE, "FRAMECAST_MCP_LOG": LOG}}}}, f)

BASE = ["claude", "-p", "--mcp-config", os.path.join(work, "mcp.json"), "--strict-mcp-config", "--tools", "",
        "--allowedTools", ALLOWED, "--model", MODEL, "--effort", EFFORT, "--system-prompt", DIRECTOR,
        "--no-session-persistence"]

def log_lines():
    try:
        with open(LOG) as f:
            return [l.split(" ", 2) for l in f.read().splitlines()]
    except FileNotFoundError:
        return []

def calls_after(t):
    """Tool calls the MCP server logged after wall-clock time t: [(seconds after t, tool, args)]."""
    out = []
    for ts, _, rest in log_lines():
        if float(ts) >= t:
            name, _, args = rest.partition(" ")
            out.append((float(ts) - t, name, args))
    return out

def on_air():
    try:
        os.remove(STATE)
    except FileNotFoundError:
        pass
    subprocess.run([FCCTL, f"dump-state:{STATE}"])
    for _ in range(40):
        if os.path.exists(STATE):
            time.sleep(0.03)
            return json.load(open(STATE)).get("program")
        time.sleep(0.05)

def verdict(expected, calls):
    switches = [json.loads(a).get("name") for _, n, a in calls if n == "switch_scene"]
    if expected is None:
        return "ok (held)" if not switches else f"WRONG: switched to {switches[-1]}"
    return "ok" if switches and switches[-1] == expected else f"WRONG: wanted {expected}, got {switches or 'hold'}"

def report(rows, cost):
    print("\n| line | expected | tool call after | verdict |\n|---|---|---|---|")
    for line, exp, t_tool, v in rows:
        print(f"| {line[:48]} | {exp or 'hold'} | {'-' if t_tool is None else f'{t_tool:.2f} s'} | {v} |")
    timed = sorted(r[2] for r in rows if r[2] is not None)
    if timed:
        print(f"\nline sent → tool call: median {timed[len(timed)//2]:.2f} s, min {timed[0]:.2f} s, max {timed[-1]:.2f} s")
    print(f"correct: {sum(r[3].startswith('ok') for r in rows)}/{len(rows)}; "
          f"reported cost (plan users are not billed this): ${cost:.4f}")
    print(f"logs: {work}")

def oneshot():
    rows, cost = [], 0.0
    for line, expected in CUES:
        t0 = time.time()
        p = subprocess.run(BASE + ["--output-format", "json", f"Presenter just said: {line}"], capture_output=True, text=True)
        wall = time.time() - t0
        try:
            res = json.loads(p.stdout)
        except json.JSONDecodeError:
            sys.exit(f"claude failed: {p.stderr.strip() or p.stdout.strip()}")
        if res.get("is_error") or res.get("terminal_reason") == "api_error":
            sys.exit(f"claude failed: {res.get('result') or res}\nIf it says the login expired, run `claude` once and sign in.")
        cost += res.get("total_cost_usd") or 0
        calls = [c for c in calls_after(t0) if c[1] != "get_show_state"]
        rows.append((line, expected, calls[0][0] if calls else None, verdict(expected, calls)))
        print(f"{wall:5.2f} s total ({res.get('duration_api_ms', 0)/1000:.2f} s in the API)  {line[:60]}")
    report(rows, cost)

def live():
    p = subprocess.Popen(BASE + ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    results = []
    def reader():
        for raw in p.stdout:
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "result":
                results.append((time.time(), ev))
    threading.Thread(target=reader, daemon=True).start()
    def turn(text):
        n = len(results); t0 = time.time()
        p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}) + "\n")
        p.stdin.flush()
        while len(results) == n and p.poll() is None and time.time() - t0 < 90:
            time.sleep(0.02)
        if len(results) == n:
            sys.exit(f"no answer from claude: {p.stderr.read()[-800:]}")
        t_done, ev = results[-1]
        if ev.get("is_error"):
            sys.exit(f"claude failed: {ev.get('result')}\nIf it says the login expired, run `claude` once and sign in.")
        return t0, t_done, ev
    t0, t_done, _ = turn("(sound check before the show) one two, one two")
    print(f"first turn, including the session starting up: {t_done - t0:.2f} s")
    rows, cost = [], 0.0
    for line, expected in CUES:
        t0, t_done, ev = turn(line)
        cost = ev.get("total_cost_usd") or cost
        calls = [c for c in calls_after(t0) if c[1] != "get_show_state"]
        rows.append((line, expected, calls[0][0] if calls else None, verdict(expected, calls)))
        print(f"turn done in {t_done - t0:5.2f} s, now on air: {on_air()!s:16}  {line[:60]}")
        time.sleep(1.5)
    p.stdin.close(); p.wait(timeout=30)
    report(rows, cost)

subprocess.run([FCCTL, "layout-named:Camera"]); time.sleep(0.8)
print(f"model {MODEL}, effort {EFFORT}, mode {MODE}; starting on air: {on_air()}")
(oneshot if MODE == "oneshot" else live)()
