#!/usr/bin/env python3
"""Import simulator screenshots into Sketch as named frames.

Usage:
    scripts/sketch_import_shots.py LoginView/login=/tmp/a.png HomeView=/tmp/b.png
    scripts/sketch_import_shots.py --selftest

Requires Sketch running with the MCP server started (Settings > General > MCP Server).
Frames land on an "Auto/Previews" page, laid out left to right.
"""
import json
import sys
import urllib.request

MCP_URL = "http://localhost:31126/mcp"
PAGE = "Auto/Previews"
W, H, GAP = 402, 874, 78  # iPhone 17 Pro logical points


def call(name, arguments):
    payload = {
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    req = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"},
    )
    body = json.load(urllib.request.urlopen(req, timeout=120))
    if "error" in body:
        raise RuntimeError(body["error"])
    return body["result"]["content"][0].get("text", "")


def layout(index, existing):
    """X offset for the index'th new frame, appended after existing ones."""
    return (existing + index) * (W + GAP)


SCRIPT = """
const sketch = require('sketch');
const doc = sketch.getSelectedDocument();
let page = doc.pages.find(p => p.name === %(page)s);
if (!page) { page = new sketch.Page({ name: %(page)s, parent: doc }); }
const made = %(shots)s.map(function (s) {
  const frame = new sketch.Artboard({
    name: s.name, parent: page,
    frame: new sketch.Rectangle(s.x, 0, %(w)d, %(h)d)
  });
  new sketch.Image({
    name: 'screenshot', parent: frame, image: s.path,
    frame: new sketch.Rectangle(0, 0, %(w)d, %(h)d)
  });
  return { name: frame.name, id: frame.id };
});
console.log(JSON.stringify({ ok: true, frames: made }));
"""


def import_shots(pairs):
    info = json.loads(call("get_document_info", {}))
    page = next((p for p in info["pages"] if p["name"] == PAGE), None)
    existing = len(page.get("frames", [])) if page else 0

    shots = [{"name": n, "path": p, "x": layout(i, existing)}
             for i, (n, p) in enumerate(pairs)]
    script = SCRIPT % {"page": json.dumps(PAGE), "shots": json.dumps(shots),
                       "w": W, "h": H}
    return call("run_code", {"script": script})


def selftest():
    assert layout(0, 0) == 0
    assert layout(1, 0) == W + GAP
    assert layout(0, 2) == 2 * (W + GAP), "new frames must not overlap existing"
    assert layout(1, 2) == 3 * (W + GAP)
    print("selftest ok")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] == "--selftest":
        selftest()
        sys.exit(0)
    pairs = []
    for arg in args:
        if "=" not in arg:
            sys.exit(f"expected NAME=PATH, got {arg!r}")
        name, path = arg.split("=", 1)
        pairs.append((name, path))
    print(import_shots(pairs))
