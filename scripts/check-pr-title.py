#!/usr/bin/env python3
"""Validate the structural title rules; never evaluate title text as shell code."""
import os
import re
import sys
import unicodedata

TITLE = re.compile(r"^(feat|fix|perf|refactor|test|docs|build|ci|chore|revert)(?:\([a-z0-9][a-z0-9/-]*\))?!?: ([^\r\n]+)$")
VAGUE = {"wip", "misc", "updates", "update", "fix bugs", "fixes", "various fixes", "various updates"}


def errors(title):
    problems = []
    match = TITLE.fullmatch(title)
    if not match:
        return ["Use type(scope): imperative description; scope is optional."]
    description = match.group(2)
    if description != description.strip() or description.endswith("."):
        problems.append("Remove extra surrounding spaces and the trailing period.")
    if description.casefold() in VAGUE or description.casefold().startswith("wip "):
        problems.append("Describe the concrete behavior; use Draft for unfinished work.")
    if any(unicodedata.category(char).startswith("C") or unicodedata.category(char) == "So" for char in title):
        problems.append("Remove control characters and decorative symbols.")
    return problems


def main():
    title = os.environ.get("PR_TITLE", "")
    problems = errors(title)
    for problem in problems:
        print(problem, file=sys.stderr)
    if len(title) > 72:
        print("Title exceeds the recommended 72 characters; shorten it if clarity permits.")
    if not problems:
        print("PR title format passed. Reviewers still check meaning and scope.")
    return bool(problems)


if __name__ == "__main__":
    sys.exit(main())
