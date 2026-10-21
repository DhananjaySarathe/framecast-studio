#!/usr/bin/env python3
"""Times the control link with no AI in the loop: a pretend MCP client talks to framecast_mcp.py over stdio,
switches scenes in a Framecast test copy and checks each switch landed through get_show_state.

usage: python3 -I bench_link.py [rounds]    (env FCCTL as for framecast_mcp.py)
"""
import json, os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
srv = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "framecast_mcp.py")],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=os.environ)
next_id = 0

def rpc(method, params=None):
    global next_id
    next_id += 1
    srv.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
    srv.stdin.flush()
    return json.loads(srv.stdout.readline())

def tool(tool_name, **args):
    out = rpc("tools/call", {"name": tool_name, "arguments": args})
    return json.loads(out["result"]["content"][0]["text"])

t = time.perf_counter(); rpc("initialize", {"protocolVersion": "2025-06-18"}); init = time.perf_counter() - t
tools = [x["name"] for x in rpc("tools/list")["result"]["tools"]]
start = tool("get_show_state")
print(f"initialize {init*1000:.0f} ms; tools: {', '.join(tools)}")
print(f"on air at start: {start.get('on_air')}")

send, landed = [], []
targets = ["Screen + camera", "Split", start.get("on_air") or "Camera"]
for r in range(rounds):
    for scene in targets:
        t0 = time.perf_counter(); tool("switch_scene", name=scene); send.append(time.perf_counter() - t0)
        while True:                      # ask until the app reports the scene on air
            s = tool("get_show_state")
            if s.get("on_air") == scene or time.perf_counter() - t0 > 5:
                break
        landed.append(time.perf_counter() - t0)
        ok = s.get("on_air") == scene
        print(f"round {r+1} -> {scene!r}: sent in {send[-1]*1000:.0f} ms, confirmed on air after "
              f"{landed[-1]*1000:.0f} ms{'' if ok else '  (NOT confirmed)'}")
        time.sleep(0.6)                  # let the transition finish before the next cut

srv.stdin.close(); srv.wait(timeout=5)
for label, xs in (("tool call returns", send), ("switch confirmed (incl. a state read)", landed)):
    ms = sorted(x * 1000 for x in xs)
    print(f"{label}: median {statistics.median(ms):.0f} ms, min {ms[0]:.0f}, max {ms[-1]:.0f} ({len(ms)} switches)")
