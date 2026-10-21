#!/usr/bin/env python3
"""Experimental MCP server (stdio) that lets Claude Code or Claude Desktop operate a Framecast test copy.

It speaks just enough of the Model Context Protocol (JSON-RPC 2.0, one message per line on stdin/stdout) to list
tools and run them, and forwards each tool to Framecast's test-control hooks through `fcctl` (distributed
notifications; only test launches with FRAMECAST_UI=test-control listen). State comes back through dump-state.
Every call is logged with a timestamp to $FRAMECAST_MCP_LOG so latency can be measured.

A real version would live inside Framecast as a local server on 127.0.0.1 with the same tools.
"""
import json, os, subprocess, sys, time

FCCTL = os.environ.get("FCCTL", "fcctl")
STATE = os.environ.get("FRAMECAST_STATE", "/tmp/framecast-mcp-state.json")
LOG = os.environ.get("FRAMECAST_MCP_LOG")

def log(msg):
    if LOG:
        with open(LOG, "a") as f:
            f.write(f"{time.time():.3f} {msg}\n")

def fc(cmd):
    subprocess.run([FCCTL, cmd], check=False)

def state():
    try:
        os.remove(STATE)
    except FileNotFoundError:
        pass
    fc(f"dump-state:{STATE}")
    for _ in range(40):
        if os.path.exists(STATE):
            time.sleep(0.03)
            with open(STATE) as f:
                d = json.load(f)
            return {
                "on_air": d.get("program"), "preview_mode": d.get("previewMode"), "preview_scene": d.get("previewScene"),
                "scenes": d.get("scenes"), "recording": d.get("recording"), "stream": d.get("streamPhase"),
                "sound": [a["name"] for a in d.get("audio", []) if a.get("inStream") and not a.get("muted")],
            }
        time.sleep(0.05)
    return {"error": "Framecast didn't answer"}

TOOLS = [
    {"name": "get_show_state", "description": "What is on air now, the list of scenes, preview mode, recording and stream state.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "switch_scene", "description": "Put a scene on air now with the current transition. Use the exact scene name from get_show_state.",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"], "additionalProperties": False}},
    {"name": "preview_scene", "description": "Load a scene into the private preview without putting it on air (needs preview mode).",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"], "additionalProperties": False}},
    {"name": "take_preview", "description": "Put the preview scene on air with the transition.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "toggle_overlay", "description": "Show or hide overlay number 1-9 (name tags, headlines, QR codes).",
     "inputSchema": {"type": "object", "properties": {"number": {"type": "integer", "minimum": 1, "maximum": 9}}, "required": ["number"], "additionalProperties": False}},
    {"name": "play_sound", "description": "Play sound pad button 1-9 (1 chime, 2 ding, 3 applause, 4 drumroll, 5 whoosh, 6 pop).",
     "inputSchema": {"type": "object", "properties": {"button": {"type": "integer", "minimum": 1, "maximum": 9}}, "required": ["button"], "additionalProperties": False}},
    {"name": "add_marker", "description": "Mark this moment (becomes a chapter in the recording).",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "hold", "description": "Decide to change nothing right now (log the reason).",
     "inputSchema": {"type": "object", "properties": {"reason": {"type": "string"}}, "required": ["reason"], "additionalProperties": False}},
]

def call(name, args):
    log(f"call {name} {json.dumps(args)}")
    if name == "get_show_state":
        return state()
    if name == "switch_scene":
        fc(f"layout-named:{args['name']}"); return {"ok": True, "on_air": args["name"]}
    if name == "preview_scene":
        fc(f"preview-scene:{args['name']}"); return {"ok": True}
    if name == "take_preview":
        fc("take"); return {"ok": True}
    if name == "toggle_overlay":
        fc(f"element:{int(args['number'])}"); return {"ok": True}
    if name == "play_sound":
        fc(f"pad:{int(args['button'])}"); return {"ok": True}
    if name == "add_marker":
        fc("marker"); return {"ok": True}
    if name == "hold":
        return {"ok": True}
    raise ValueError(f"unknown tool {name}")

def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except json.JSONDecodeError:
        continue
    method, id_ = req.get("method"), req.get("id")
    if id_ is None:          # notifications (initialized, cancelled): no reply
        continue
    if method == "initialize":
        reply(id_, {"protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "framecast", "version": "0.1"}})
    elif method == "tools/list":
        reply(id_, {"tools": TOOLS})
    elif method == "tools/call":
        p = req.get("params", {})
        try:
            out = call(p.get("name"), p.get("arguments") or {})
            reply(id_, {"content": [{"type": "text", "text": json.dumps(out)}]})
        except Exception as e:  # noqa: BLE001
            reply(id_, {"content": [{"type": "text", "text": str(e)}], "isError": True})
    elif method == "ping":
        reply(id_, {})
    else:
        reply(id_, error={"code": -32601, "message": f"method not found: {method}"})
