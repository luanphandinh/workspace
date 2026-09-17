#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


def fail(message: str) -> int:
    print(f"nvim-open-reference-url: {message}", file=sys.stderr)
    return 1


def find_nvim():
    if nvim := shutil.which("nvim"):
        return nvim

    home = Path.home()
    for candidate in (
        home / ".nix-profile/bin/nvim",
        home / "bin/nvim",
        Path("/opt/homebrew/bin/nvim"),
        Path("/usr/local/bin/nvim"),
        Path("/usr/bin/nvim"),
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def main() -> int:
    if len(sys.argv) != 2:
        return fail("expected one nvim-ref URL")

    parsed = urlsplit(sys.argv[1])
    if parsed.scheme != "nvim-ref" or parsed.netloc != "open":
        return fail("unsupported URL")

    query = parse_qs(parsed.query, strict_parsing=True)
    try:
        server = query["server"][0]
        path = os.path.abspath(os.path.expanduser(query["path"][0]))
        line = int(query["line"][0])
        column = int(query.get("column", ["1"])[0])
    except (KeyError, ValueError, OSError) as exc:
        return fail(f"invalid URL: {exc}")

    if not Path(server).exists():
        return fail("Neovim server is no longer running")
    if not Path(path).is_file():
        return fail("reference file does not exist")

    nvim = find_nvim()
    if not nvim:
        return fail("nvim is not available")

    arguments = {"path": path, "line": line, "column": column}
    expression = (
        'luaeval("require(\'luanphan.terminal_references\')'
        '.open(_A.path, _A.line, _A.column)", '
        + json.dumps(arguments)
        + ")"
    )
    result = subprocess.run(
        [nvim, "--server", server, "--remote-expr", expression],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return fail(result.stderr.strip() or "Neovim rejected the reference")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
