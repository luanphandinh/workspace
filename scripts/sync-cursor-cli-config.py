#!/usr/bin/env python3
"""Enable Cursor's terminal title status while preserving its other settings."""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile


root = os.environ.get("CURSOR_CONFIG_DIR", "").strip()
xdg = os.environ.get("XDG_CONFIG_HOME", "").strip()
directory = Path(root) if root else Path(xdg) / "cursor" if xdg else Path.home() / ".cursor"
path = directory / "cli-config.json"
config = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"version": 1}
display = config.setdefault("display", {})
if display.get("showStatusIndicators") is not True:
    display["showStatusIndicators"] = True
    directory.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory, delete=False) as output:
        temporary = Path(output.name)
        try:
            json.dump(config, output, indent=2)
            output.write("\n")
            output.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
