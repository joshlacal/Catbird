#!/usr/bin/env python3
"""Witness the same open simulator conversation before and after a signed erasure."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from uuid import UUID


def wait_until(predicate, seconds, failure):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.25)
    raise RuntimeError(failure)


def descendants(node):
    if isinstance(node, dict):
        yield node
        for child in node.values():
            yield from descendants(child)
    elif isinstance(node, list):
        for child in node:
            yield from descendants(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("evidence", type=Path, help="Directory containing this phase's command.json")
    parser.add_argument("--retained-text", required=True)
    args = parser.parse_args()
    command = json.loads((args.evidence / "command.json").read_text())
    if command["phase"] != "observe-erasure":
        raise ValueError("Requires the mounted erasure phase")
    nonce = str(UUID(command["nonce"]))
    control = "chat.message." + str(UUID(command["message"]))
    retained = "chat.message." + str(UUID(command["retainedMessage"]))
    if control == retained or not command["text"] or not args.retained_text:
        raise ValueError("Requires two distinguishable message rows")
    os.umask(0o077)

    def directory():
        app = subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", args.device, "blue.catbird", "data"], text=True
        ).strip()
        return Path(app) / "Documents" / "MLSTwoHome"

    def signal(name):
        # The simulator container may move when XCTest installs the selected build.
        return directory() / (name + "-" + nonce)

    def witness(stage):
        raw = subprocess.check_output(["axe", "describe-ui", "--udid", args.device], timeout=15)
        nodes = {node["AXUniqueId"]: node for node in descendants(json.loads(raw)) if node.get("AXUniqueId")}
        if retained not in nodes or args.retained_text not in (nodes[retained].get("AXLabel") or ""):
            return False
        if stage == "before":
            if control not in nodes or command["text"] not in (nodes[control].get("AXLabel") or ""):
                return False
        elif control in nodes or any(command["text"] in (node.get("AXLabel") or "") for node in nodes.values()):
            return False
        (args.evidence / ("system-accessibility-" + stage + ".json")).write_bytes(raw)
        subprocess.run(["xcrun", "simctl", "io", args.device, "screenshot",
                        str(args.evidence / ("system-" + stage + ".png"))], check=True)
        # Signal only after the retained tree and screenshot were captured, without touching the view.
        signal("observer-" + stage).touch()
        return True

    wait_until(lambda: signal("observer-mounted").exists(), 600, "The intended conversation never mounted")
    wait_until(lambda: witness("before"), 55, "Both exact baseline rows must be accessible")
    wait_until(lambda: signal("observer-store-applied").exists(), 1200, "Signed storage cutoff did not apply")
    wait_until(lambda: witness("after"), 55, "The retained row must remain visible after the control disappears")


if __name__ == "__main__":
    main()
