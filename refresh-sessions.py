#!/usr/bin/env python3
"""Reads active Claude Code sessions and writes claude-sessions.js for the dashboard."""

import json
import os
import sys

SESSIONS_DIR = os.path.expanduser("~/.claude/sessions")
HISTORY_FILE = os.path.expanduser("~/.claude/history.jsonl")
OUTPUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-sessions.js")


def main():
    # Build lookup: sessionId -> last user prompt (from history)
    history_by_session = {}
    if os.path.exists(HISTORY_FILE):
        with open(HISTORY_FILE) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    sid = entry.get("sessionId", "")
                    display = entry.get("display", "")
                    if sid and display:
                        history_by_session[sid] = display
                except (json.JSONDecodeError, KeyError):
                    pass

    sessions = []
    if os.path.isdir(SESSIONS_DIR):
        for fname in os.listdir(SESSIONS_DIR):
            if not fname.endswith(".json"):
                continue
            filepath = os.path.join(SESSIONS_DIR, fname)
            try:
                with open(filepath) as f:
                    data = json.load(f)

                pid = data.get("pid")
                if pid is None:
                    continue

                # Check if process is still alive
                try:
                    os.kill(pid, 0)
                except (OSError, ProcessLookupError):
                    continue

                session_id = data.get("sessionId", "")
                last_prompt = history_by_session.get(session_id, "")
                # Truncate long prompts
                if len(last_prompt) > 200:
                    last_prompt = last_prompt[:200] + "..."

                sessions.append({
                    "pid": pid,
                    "sessionId": session_id,
                    "cwd": data.get("cwd", ""),
                    "startedAt": data.get("startedAt", 0),
                    "entrypoint": data.get("entrypoint", "cli"),
                    "name": data.get("name", ""),
                    "lastPrompt": last_prompt,
                })
            except (json.JSONDecodeError, IOError):
                pass

    # Sort by startedAt descending (newest first)
    sessions.sort(key=lambda s: s["startedAt"], reverse=True)

    with open(OUTPUT_FILE, "w") as f:
        f.write("window.__claudeSessions = ")
        json.dump(sessions, f, indent=2)
        f.write(";\n")

    print(f"Found {len(sessions)} active Claude Code session(s) -> {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
