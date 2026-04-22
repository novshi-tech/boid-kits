#!/bin/sh
for f in pyproject.toml uv.lock .python-version; do
    [ -f "$f" ] && { echo required; exit 0; }
done
