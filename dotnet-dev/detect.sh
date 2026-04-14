#!/bin/sh
for f in *.csproj *.fsproj *.vbproj *.sln global.json; do
    [ -f "$f" ] && { echo required; exit 0; }
done
