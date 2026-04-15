#!/bin/sh
[ -f Dockerfile ] || [ -f Containerfile ] || [ -f compose.yaml ] || [ -f compose.yml ] || [ -f docker-compose.yaml ] || [ -f docker-compose.yml ] && echo optional
