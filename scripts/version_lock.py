#!/usr/bin/env python3

import json
import sys
from pathlib import Path


def fail(message):
    raise RuntimeError(message)


def require_string(value, path):
    if not isinstance(value, str) or not value.strip():
        fail(f"{path} must be a non-empty string")


def validate_lock(lock):
    if not isinstance(lock, dict):
        fail("version lock must be an object")

    require_string(lock.get("go", {}).get("version"), "go.version")
    require_string(lock.get("tree_sitter_cli", {}).get("version"), "tree_sitter_cli.version")

    parsers = lock.get("treesitter", {}).get("parsers")
    if not isinstance(parsers, list) or not parsers:
        fail("treesitter.parsers must be a non-empty array")

    seen = set()
    for index, parser in enumerate(parsers):
        base = f"treesitter.parsers[{index}]"
        if not isinstance(parser, dict):
            fail(f"{base} must be an object")

        language = parser.get("language")
        require_string(language, f"{base}.language")
        require_string(parser.get("repo"), f"{base}.repo")
        has_lock_version = "lock_version" in parser
        has_ref = "ref" in parser
        if has_lock_version and has_ref:
            fail(f"{base} must use lock_version, not both lock_version and ref")
        if has_lock_version:
            require_string(parser.get("lock_version"), f"{base}.lock_version")
        if has_ref:
            require_string(parser.get("ref"), f"{base}.ref")

        if language in seen:
            fail(f"{base}.language is duplicated: {language}")
        seen.add(language)


def read_lock(path):
    return json.loads(Path(path).read_text())


def get_path(lock, path):
    value = lock
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            fail(f"{path} does not exist")
        value = value[part]
    if not isinstance(value, str):
        fail(f"{path} must resolve to a string")
    return value


def print_parsers(lock):
    for parser in lock["treesitter"]["parsers"]:
        lock_version = parser.get("lock_version", parser.get("ref", ""))
        print("\t".join([parser["language"], parser["repo"], lock_version]))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "validate"
    lock_file = sys.argv[2] if len(sys.argv) > 2 else "version-lock.json"
    lock = read_lock(lock_file)
    validate_lock(lock)

    if command == "validate":
        return
    if command == "get":
        if len(sys.argv) < 4:
            fail("usage: version_lock.py get <lock-file> <path>")
        print(get_path(lock, sys.argv[3]))
        return
    if command == "parsers":
        print_parsers(lock)
        return

    fail(f"unknown command: {command}")


if __name__ == "__main__":
    main()
