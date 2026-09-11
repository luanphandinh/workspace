"""Atomic, generic per-workspace durable-agent registry."""

import fcntl
import json
import os
import re
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

CONFIG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
REGISTRY_VERSION = 2


def registry_path(cwd, config):
    if not CONFIG_PATTERN.fullmatch(config):
        raise ValueError("config must contain only letters, numbers, dot, dash, or underscore")
    return Path(cwd) / "luanphan_agents" / f"{config}.json"


@contextmanager
def registry_lock(path):
    lock_path = path.with_suffix(path.suffix + ".lock")
    lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(lock_path, "a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def migrate(value, path):
    version = value.get("version")
    if version == REGISTRY_VERSION and isinstance(value.get("main_agents"), list):
        return value
    if version == 1 and isinstance(value.get("sessions"), list):
        sessions = value.pop("sessions")
        value["version"] = REGISTRY_VERSION
        value["main_agents"] = []
        if sessions:
            value["main_agents"].append({
                "agent": "unknown",
                "session_id": None,
                "name": "Unassigned",
                "sub_agents": sessions,
            })
        return value
    raise ValueError(f"unsupported agent registry: {path}")


def main_agent_identity(args):
    session_id = args.main_agent_id
    agent = args.main_agent_type or ("codex" if session_id else "unknown")
    return agent, session_id


def find_main_agent(value, agent, session_id):
    return next(
        (
            item
            for item in value["main_agents"]
            if item.get("agent") == agent and item.get("session_id") == session_id
        ),
        None,
    )


def upsert(cwd, config, result, args):
    path = registry_path(cwd, config)
    with registry_lock(path):
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            value = {
                "version": REGISTRY_VERSION,
                "workspace": str(Path(cwd).resolve()),
                "main_agents": [],
            }
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid agent registry: {path}: {error.msg}") from error
        value = migrate(value, path)
        main_agent_type, main_agent_id = main_agent_identity(args)
        requested_parent = find_main_agent(value, main_agent_type, main_agent_id)
        existing_parent = None
        existing = None
        for parent in value["main_agents"]:
            if not isinstance(parent.get("sub_agents"), list):
                raise ValueError(f"unsupported agent registry: {path}")
            match = next(
                (
                    item
                    for item in parent["sub_agents"]
                    if item.get("agent") == result.get("agent")
                    and item.get("session_id") == result.get("session_id")
                ),
                None,
            )
            if match is not None:
                existing_parent = parent
                existing = match
                break

        now = result.get("updated_at") or datetime.now(timezone.utc).isoformat()
        if requested_parent is None:
            requested_parent = {
                "agent": main_agent_type,
                "session_id": main_agent_id,
                "name": args.main_agent_name or main_agent_id or "Unassigned",
                "created_at": now,
                "updated_at": now,
                "sub_agents": [],
            }
            value["main_agents"].append(requested_parent)
        elif args.main_agent_name:
            requested_parent["name"] = args.main_agent_name

        parent = existing_parent or requested_parent
        if existing_parent is not None and existing_parent.get("session_id") is None and main_agent_id:
            existing_parent["sub_agents"].remove(existing)
            parent = requested_parent
        existing = existing or {}
        entry = {
            key: existing[key]
            for key in ("role", "owned_paths", "changed_paths", "checks")
            if key in existing
        }
        entry.update({
            "agent": result.get("agent"),
            "session_id": result.get("session_id"),
            "name": result.get("name"),
            "status": result.get("status"),
            "model": args.model,
            "mode": args.mode,
            "cwd": str(Path(cwd).resolve()),
            "created_at": existing.get("created_at") or result.get("created_at") or datetime.now(timezone.utc).isoformat(),
            "updated_at": now,
            "result": {"status": result.get("status"), "stop_reason": result.get("stop_reason")},
        })
        if existing and existing in parent["sub_agents"]:
            parent["sub_agents"][parent["sub_agents"].index(existing)] = entry
        else:
            parent["sub_agents"].append(entry)
        parent["updated_at"] = now
        path.parent.mkdir(mode=0o700, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(value, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.replace(temporary, path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
