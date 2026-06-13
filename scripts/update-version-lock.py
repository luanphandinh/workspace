#!/usr/bin/env python3

import json
import subprocess
import sys
from pathlib import Path

from version_lock import fail, validate_lock


def run(args):
    return subprocess.check_output(args, text=True).strip()


def main():
    lock_path = Path(sys.argv[1] if len(sys.argv) > 1 else "version-lock.json")
    lock = json.loads(lock_path.read_text())

    validate_lock(lock)

    lock["tree_sitter_cli"]["version"] = run(["npm", "view", "tree-sitter-cli", "version"])

    for parser in lock["treesitter"]["parsers"]:
        output = run(["git", "ls-remote", parser["repo"], "HEAD"])
        lock_version = output.split()[0] if output else ""
        if not lock_version:
            fail(f"unable to resolve parser HEAD: {parser['language']}")
        parser["lock_version"] = lock_version
        parser.pop("ref", None)

    validate_lock(lock)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    print(f"updated {lock_path}")


if __name__ == "__main__":
    main()
