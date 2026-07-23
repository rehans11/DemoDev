#!/usr/bin/env python3
"""
PreToolUse hook: injects the relevant Salesforce best-practice rule files as
additionalContext whenever Claude writes/edits a metadata or code file under
force-app. Detection is by file path. Fails open (never blocks an edit).

Wired in .claude/settings.json for Write | Edit | MultiEdit.
"""
import json
import os
import sys


def load_input():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def rule_files_for(path: str):
    """Return an ordered, de-duplicated list of rule filenames for a given path."""
    p = path.replace("\\", "/").lower()
    name = os.path.basename(p)
    rules = []

    def add(*names):
        for n in names:
            if n not in rules:
                rules.append(n)

    # Only care about source metadata/code.
    if "force-app" not in p:
        return []

    is_test = name.endswith("test.cls") or "test" in name and name.endswith(".cls")

    if p.endswith(".trigger") or "/triggers/" in p:
        add("triggers.md", "apex.md", "security.md", "testing.md", "naming-conventions.md")
    elif p.endswith(".cls") or "/classes/" in p:
        add("apex.md", "security.md", "naming-conventions.md")
        if is_test:
            add("testing.md")
    elif "/lwc/" in p or "/aura/" in p:
        add("lwc.md", "security.md", "naming-conventions.md")
    elif "/objects/" in p or "/fields/" in p or p.endswith(".object-meta.xml") or p.endswith(".field-meta.xml"):
        add("data-model.md", "security.md", "naming-conventions.md")
    elif "/permissionsets/" in p or "/profiles/" in p or "/permissionsetgroups/" in p:
        add("security.md", "naming-conventions.md")
    elif "/flows/" in p or "/workflows/" in p or "/validationrules/" in p:
        add("data-model.md", "security.md")

    return rules


def main():
    data = load_input()
    tool_input = data.get("tool_input", {}) or {}
    path = tool_input.get("file_path") or tool_input.get("filePath") or ""
    if not path:
        sys.exit(0)

    rules = rule_files_for(path)
    if not rules:
        sys.exit(0)

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    rules_dir = os.path.join(project_dir, ".claude", "rules")

    chunks = []
    for r in rules:
        fp = os.path.join(rules_dir, r)
        try:
            with open(fp, "r", encoding="utf-8") as fh:
                chunks.append(fh.read().strip())
        except Exception:
            # Fall back to just naming the file if it can't be read.
            chunks.append(f"(Follow .claude/rules/{r} — could not read file contents.)")

    header = (
        "MANDATORY SALESFORCE RULES for `%s`.\n"
        "You are creating/modifying this file. Strictly follow ALL rules below. "
        "If any rule conflicts with the Technical Spec or a user requirement, STOP and "
        "ask — do not silently choose.\n" % os.path.basename(path)
    )
    context = header + "\n\n---\n\n" + "\n\n---\n\n".join(chunks)

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": context,
        }
    }))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never block an edit because the hook errored.
        sys.exit(0)
