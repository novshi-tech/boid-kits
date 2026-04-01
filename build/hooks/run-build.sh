#!/bin/bash
set -e

echo "=== Building ==="
go build ./...

echo "=== Testing ==="
go test ./...

echo "=== Vet ==="
go vet ./...

echo "=== Done ==="
