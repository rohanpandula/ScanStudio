#!/usr/bin/env python3
"""Exercise real project persistence through a packaged engine, without hardware."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main(engine):
    with tempfile.TemporaryDirectory(prefix="ScanStudio # project ") as root:
        directory = str(Path(root) / "Saved roll # 1")
        create = {"name": "Package check", "carrier": "strip6", "frameCount": 2,
                  "filmProcess": "c41ColorNegative", "directory": directory}
        commands = [
            ("engine.hello", {"clientName": "persistence-smoke", "protocolVersion": 1}),
            ("project.create", create),
            ("project.setFrameExcluded", {"frameIndex": 1, "excluded": True}),
            ("project.open", {"directory": directory}),
            ("project.create", create),
            ("project.open", {"directory": directory}),
            ("engine.shutdown", {}),
        ]
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("SCANSTUDIO_")}
        result = subprocess.run(
            [engine], input="".join(json.dumps({"id": index, "method": method,
                                               "params": params}) + "\n"
                                    for index, (method, params) in enumerate(commands, 1)),
            text=True, capture_output=True, timeout=30, env=environment, check=True,
        )
        responses = {}
        for line in result.stdout.splitlines():
            message = json.loads(line)
            if "id" in message:
                assert message["id"] not in responses, message
                responses[message["id"]] = message
        assert set(responses) == set(range(1, 8)), result.stdout
        for index, response in responses.items():
            if index == 5:
                assert response.get("error", {}).get("code") == "PROJECT_ALREADY_EXISTS", response
            else:
                assert "result" in response and not response.get("error"), response
        original_id = responses[2]["result"]["project"]["id"]
        for index in (4, 6):
            project = responses[index]["result"]["project"]
            assert project["id"] == original_id, project
            assert project["frames"][0]["excluded"] is True, project
        manifest = json.loads((Path(directory) / "manifest.json").read_text())
        assert manifest == responses[6]["result"]["project"], manifest
        assert not list(Path(directory).glob(".manifest.json.*")), directory
    print("Project create, mutate, reopen, and overwrite refusal passed (spaces and # in path)")


if __name__ == "__main__":
    main(sys.argv[1])
