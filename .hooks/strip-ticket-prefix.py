#!/usr/bin/env python3
"""Strip a `[OND123-4567] ` prefix that giticket applied on an earlier run.

Runs at commit-msg, BEFORE conventional-pre-commit and giticket, and exists because
those two cannot both be satisfied on a re-used message:

  * conventional-pre-commit anchors its regex at ^, so it rejects the decorated
    subject `[OND211-2418] feat: x` that giticket produced the first time round -
    which is every `git commit --amend`, `--no-edit`, rebase reword or `-C HEAD`.
  * giticket's own idempotency guard never fires for this repo's regex (it ends in
    `[_-][\w-]+`, which cannot match across the `]` of an existing prefix), so it
    would happily produce `[OND211-2418] [OND211-2418] feat: x`.

Stripping first makes the pipeline idempotent: the developer's own subject is what
gets validated, and the ticket is applied exactly once however often the message is
re-used. A message that was never decorated is passed through untouched.
"""
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

stripped = re.sub(r"^\[OND[0-9]{3}-[0-9]{1,5}\]\s+", "", text, count=1)
if stripped != text:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(stripped)
