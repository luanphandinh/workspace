#!/usr/bin/env python3
"""Compare a local tech doc with remote markdown content.

This helper is intentionally read-only. It builds a heading-aware section index
for local and remote markdown, then reports the deepest changed sections so an
agent can prepare targeted str_replace updates instead of whole-document writes.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import html
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
TABLE_SEPARATOR_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$")
MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
HTML_TAG_RE = re.compile(r"</?[^>\s]+(?:\s[^>]*)?>")
DIAGRAM_BLOCK_TOKEN = "DIAGRAM_BLOCK"


@dataclass(frozen=True)
class Section:
    key: str
    title: str
    level: int
    start_line: int
    end_line: int
    text: str
    body: str
    content_hash: str


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


CONTENT_PATHS = (
    ("data", "document", "content"),
    ("data", "content"),
    ("document", "content"),
    ("content",),
    ("markdown",),
    ("data", "markdown"),
    ("text",),
    ("data", "text"),
)

METADATA_KEYS = {
    "code",
    "document_id",
    "identity",
    "msg",
    "ok",
    "revision_id",
    "title",
    "token",
    "url",
}


def get_path(value: Any, path: tuple[str, ...]) -> Any:
    current = value
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def looks_like_document_text(value: str) -> bool:
    if any(HEADING_RE.match(line) for line in value.splitlines()):
        return True
    if re.search(r"<h[1-6](\s[^>]*)?>", value):
        return True
    return "\n" in value or len(value) > 80


def extract_markdown_from_json(value: Any) -> str | None:
    for path in CONTENT_PATHS:
        found = get_path(value, path)
        if isinstance(found, str):
            return found
        if found is not None:
            nested = extract_markdown_from_json(found)
            if nested:
                return nested

    return find_document_text(value)


def find_document_text(value: Any) -> str | None:
    if isinstance(value, str):
        return value if looks_like_document_text(value) else None
    if isinstance(value, list):
        for item in value:
            found = find_document_text(item)
            if found:
                return found
        return None
    if not isinstance(value, dict):
        return None

    for key, item in value.items():
        if key in METADATA_KEYS:
            continue
        found = find_document_text(item)
        if found:
            return found
    return None


def fetch_remote_markdown(remote: str, lark_cli: str) -> str:
    cmd = [
        lark_cli,
        "docs",
        "+fetch",
        "--api-version",
        "v2",
        "--doc",
        remote,
        "--doc-format",
        "markdown",
        "--format",
        "json",
    ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())

    output = result.stdout.strip()
    if not output:
        return ""
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        return output

    markdown = extract_markdown_from_json(parsed)
    if markdown is None:
        raise RuntimeError("unable to find markdown content in fetch result")
    return markdown


def normalize_heading(title: str) -> str:
    title = title.strip()
    title = re.sub(r"\s+", " ", title)
    return title


def normalize_markdown_link(match: re.Match[str]) -> str:
    label = match.group(1).strip()
    target = match.group(2).strip()
    if label == target:
        return target
    return f"{label} {target}"


def normalize_table_row(line: str) -> str:
    stripped = line.strip()
    if not stripped.startswith("|") or "|" not in stripped[1:]:
        return line
    cells = [cell.strip() for cell in stripped.strip("|").split("|")]
    return " | ".join(cells)


def normalize_line_for_hash(line: str) -> str:
    line = line.strip()
    line = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|])", r"\1", line)
    line = re.sub(r"^#{1,6}\s+", "", line)
    line = re.sub(r"^[-*+]\s+", "- ", line)
    line = re.sub(r"^•\s+", "- ", line)
    line = re.sub(r"^(\d+)[.)]\s+", r"\1. ", line)
    line = re.sub(r"`([^`]+)`", r"\1", line)
    line = line.replace("**", "").replace("__", "")
    line = line.replace("<strong>", "").replace("</strong>", "")
    line = line.replace("<b>", "").replace("</b>", "")
    line = normalize_table_row(line)
    line = re.sub(r"\s+", " ", line)
    return line.strip()


def normalize_for_hash(text: str) -> str:
    text = html.unescape(text)
    text = re.sub(
        r"(?ims)^(```+|~~~+)\s*mermaid[^\n]*\n.*?^\1\s*$",
        f"\n{DIAGRAM_BLOCK_TOKEN}\n",
        text,
    )
    text = re.sub(
        r"<readonly-block\b[^>]*>\s*</readonly-block>",
        f"\n{DIAGRAM_BLOCK_TOKEN}\n",
        text,
    )
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</li\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<li\b[^>]*>", "\n- ", text, flags=re.IGNORECASE)
    text = re.sub(r"</?(ul|ol)\b[^>]*>", "\n", text, flags=re.IGNORECASE)
    text = MARKDOWN_LINK_RE.sub(normalize_markdown_link, text)
    text = HTML_TAG_RE.sub("", text)

    normalized: list[str] = []
    for raw_line in text.splitlines():
        if FENCE_RE.match(raw_line):
            continue
        if TABLE_SEPARATOR_RE.match(raw_line):
            continue
        line = normalize_line_for_hash(raw_line)
        if not line:
            continue
        normalized.append(line)
    return "\n".join(normalized) + "\n"


def parse_sections(markdown: str) -> dict[str, Section]:
    lines = markdown.splitlines()
    headings: list[tuple[int, int, str, str]] = []
    stack: list[tuple[int, str]] = []
    in_fence = False

    for idx, line in enumerate(lines):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = HEADING_RE.match(line)
        if not match:
            continue

        level = len(match.group(1))
        title = normalize_heading(match.group(2))
        while stack and stack[-1][0] >= level:
            stack.pop()
        stack.append((level, title))
        key = " > ".join(item[1] for item in stack)
        headings.append((idx, level, title, key))

    if not headings:
        body = "\n".join(lines)
        return {
            "<document>": Section(
                key="<document>",
                title="<document>",
                level=0,
                start_line=1,
                end_line=len(lines),
                text=body,
                body=body,
                content_hash=hashlib.sha256(
                    normalize_for_hash(body).encode("utf-8")
                ).hexdigest(),
            )
        }

    sections: dict[str, Section] = {}
    for pos, (start, level, title, key) in enumerate(headings):
        end = len(lines)
        for next_start, next_level, _next_title, _next_key in headings[pos + 1 :]:
            if next_level <= level:
                end = next_start
                break

        section_lines = lines[start:end]
        body_lines = section_lines[1:]
        text = "\n".join(section_lines)
        body = "\n".join(body_lines)
        sections[key] = Section(
            key=key,
            title=title,
            level=level,
            start_line=start + 1,
            end_line=end,
            text=text,
            body=body,
            content_hash=hashlib.sha256(
                normalize_for_hash(text).encode("utf-8")
            ).hexdigest(),
        )

    return sections


def is_descendant(child: str, parent: str) -> bool:
    return child.startswith(parent + " > ")


def deepest(keys: Iterable[str]) -> list[str]:
    ordered = sorted(set(keys))
    result: list[str] = []
    for key in ordered:
        if any(is_descendant(other, key) for other in ordered):
            continue
        result.append(key)
    return result


def build_plan(local_text: str, remote_text: str) -> dict[str, Any]:
    local = parse_sections(local_text)
    remote = parse_sections(remote_text)

    local_unstructured = set(local) == {"<document>"}
    remote_unstructured = set(remote) == {"<document>"}
    remote_has_content = bool(remote["<document>"].text.strip()) if remote_unstructured else True
    unsafe = remote_unstructured and not local_unstructured and remote_has_content

    local_keys = set(local)
    remote_keys = set(remote)
    common = local_keys & remote_keys

    if unsafe:
        return {
            "summary": {
                "local_sections": len(local),
                "remote_sections": len(remote),
                "changed_sections": 0,
                "new_sections": 0,
                "remote_only_sections": len(remote),
                "unsafe": True,
                "reason": (
                    "remote content has no parseable headings; "
                    "section-level compare is disabled"
                ),
            },
            "changed_sections": [],
            "new_sections": [],
            "remote_only_sections": [
                section_record(key, None, remote[key]) for key in sorted(remote_keys)
            ],
        }

    changed = [
        key
        for key in common
        if local[key].content_hash != remote[key].content_hash
    ]
    new_sections = sorted(local_keys - remote_keys)
    remote_only = sorted(remote_keys - local_keys)
    changed_deepest = deepest(changed)

    return {
        "summary": {
            "local_sections": len(local),
            "remote_sections": len(remote),
            "changed_sections": len(changed_deepest),
            "new_sections": len(new_sections),
            "remote_only_sections": len(remote_only),
            "unsafe": False,
        },
        "changed_sections": [
            section_record(key, local[key], remote[key]) for key in changed_deepest
        ],
        "new_sections": [section_record(key, local[key], None) for key in new_sections],
        "remote_only_sections": [
            section_record(key, None, remote[key]) for key in remote_only
        ],
    }


def section_record(
    key: str, local: Section | None, remote: Section | None
) -> dict[str, Any]:
    record: dict[str, Any] = {"key": key}
    if local:
        record["local"] = {
            "title": local.title,
            "level": local.level,
            "start_line": local.start_line,
            "end_line": local.end_line,
            "hash": local.content_hash,
        }
    if remote:
        record["remote"] = {
            "title": remote.title,
            "level": remote.level,
            "start_line": remote.start_line,
            "end_line": remote.end_line,
            "hash": remote.content_hash,
        }
    if local and remote:
        record["str_replace_candidate"] = True
    return record


def load_inputs(args: argparse.Namespace) -> tuple[str, str]:
    local_text = read_text(args.local)
    if args.remote_file:
        remote_text = read_text(args.remote_file)
    elif args.remote:
        remote_text = fetch_remote_markdown(args.remote, args.lark_cli)
    else:
        raise SystemExit("provide either --remote-file or --remote")
    return local_text, remote_text


def print_index(markdown: str) -> None:
    sections = parse_sections(markdown)
    for key, section in sorted(sections.items()):
        print(
            f"{section.start_line:>5}-{section.end_line:<5} "
            f"H{section.level} {key} {section.content_hash[:12]}"
        )


def print_plan(plan: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(plan, indent=2, ensure_ascii=False))
        return

    summary = plan["summary"]
    print(
        "sections: "
        f"local={summary['local_sections']} "
        f"remote={summary['remote_sections']} "
        f"changed={summary['changed_sections']} "
        f"new={summary['new_sections']} "
        f"remote_only={summary['remote_only_sections']}"
    )
    if summary.get("unsafe"):
        print(f"WARNING: {summary['reason']}")

    for label in ("changed_sections", "new_sections", "remote_only_sections"):
        items = plan[label]
        if not items:
            continue
        print(f"\n{label.replace('_', ' ')}:")
        for item in items:
            print(f"- {item['key']}")


def print_diff(local_text: str, remote_text: str) -> None:
    local = parse_sections(local_text)
    remote = parse_sections(remote_text)
    plan = build_plan(local_text, remote_text)

    keys = [item["key"] for item in plan["changed_sections"]]
    keys.extend(item["key"] for item in plan["new_sections"])
    if not keys:
        return

    for key in keys:
        local_lines = local[key].text.splitlines(keepends=True)
        remote_lines = remote[key].text.splitlines(keepends=True) if key in remote else []
        for line in difflib.unified_diff(
            remote_lines,
            local_lines,
            fromfile=f"remote:{key}",
            tofile=f"local:{key}",
            lineterm="",
        ):
            print(line)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Compare local and remote tech docs by markdown heading section."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--local", required=True, help="local markdown file")
        subparser.add_argument("--remote-file", help="remote markdown export file")
        subparser.add_argument("--remote", help="remote document URL or token")
        subparser.add_argument(
            "--lark-cli",
            default="lark-cli",
            help="lark-cli executable for --remote fetches",
        )

    index_parser = subparsers.add_parser("index", help="print section indexes")
    add_common(index_parser)
    index_parser.add_argument(
        "--side",
        choices=("local", "remote", "both"),
        default="both",
        help="which index to print",
    )

    plan_parser = subparsers.add_parser("plan", help="print changed section plan")
    add_common(plan_parser)
    plan_parser.add_argument("--json", action="store_true", help="emit JSON")

    diff_parser = subparsers.add_parser("diff", help="print changed section diffs")
    add_common(diff_parser)

    args = parser.parse_args(argv)
    local_text, remote_text = load_inputs(args)

    if args.command == "index":
        if args.side in ("local", "both"):
            print("local:")
            print_index(local_text)
        if args.side in ("remote", "both"):
            if args.side == "both":
                print()
            print("remote:")
            print_index(remote_text)
        return 0

    if args.command == "plan":
        print_plan(build_plan(local_text, remote_text), args.json)
        return 0

    if args.command == "diff":
        print_diff(local_text, remote_text)
        return 0

    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
