#!/usr/bin/env python3
"""Validate Agent Skill metadata, progressive disclosure, local links, and eval fixtures."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "SKILL.md"
EVALS = ROOT / "evals" / "cases.jsonl"
FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def parse_frontmatter(text: str) -> dict[str, str]:
    match = FRONTMATTER_RE.search(text)
    if not match:
        return {}
    lines = match.group(1).splitlines()
    values: dict[str, str] = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("name:"):
            values["name"] = line.split(":", 1)[1].strip()
        elif line.startswith("description:"):
            value = line.split(":", 1)[1].strip()
            if value == ">":
                parts: list[str] = []
                i += 1
                while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
                    if lines[i].strip():
                        parts.append(lines[i].strip())
                    i += 1
                values["description"] = " ".join(parts)
                continue
            values["description"] = value
        i += 1
    return values


def main() -> int:
    errors: list[str] = []
    text = SKILL.read_text(encoding="utf-8")
    fm = parse_frontmatter(text)
    name = fm.get("name", "")
    description = fm.get("description", "")

    if not re.fullmatch(r"[a-z0-9-]{1,64}", name):
        errors.append("SKILL.md: name must be 1-64 lowercase letters/numbers/hyphens")
    if not description or len(description) > 1024:
        errors.append("SKILL.md: description must be 1-1024 characters")
    if len(text.splitlines()) > 500:
        errors.append("SKILL.md: exceeds 500-line progressive-disclosure budget")

    for target in LINK_RE.findall(text):
        if target.startswith(("http://", "https://", "#")):
            continue
        clean = target.split("#", 1)[0]
        resolved = (ROOT / clean).resolve()
        if ROOT not in resolved.parents and resolved != ROOT:
            errors.append(f"SKILL.md: reference escapes repository: {target}")
        elif not resolved.exists():
            errors.append(f"SKILL.md: missing referenced file: {target}")

    rows = []
    if not EVALS.exists():
        errors.append("evals/cases.jsonl: missing")
    else:
        for lineno, raw in enumerate(EVALS.read_text(encoding="utf-8").splitlines(), 1):
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"evals/cases.jsonl:{lineno}: invalid JSON: {exc}")
                continue
            for key in ("id", "input", "expected_behavior", "forbidden"):
                if key not in row:
                    errors.append(f"evals/cases.jsonl:{lineno}: missing {key}")
            rows.append(row)
    if len(rows) < 3:
        errors.append("evals/cases.jsonl: at least three evals are required")
    ids = [row.get("id") for row in rows]
    if len(ids) != len(set(ids)):
        errors.append("evals/cases.jsonl: duplicate ids")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Agent Skill structure OK; evals={len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
