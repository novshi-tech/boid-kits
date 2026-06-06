#!/bin/sh
# fly.io CLI が入っていれば候補として提示する。デプロイは task ごとの
# 関心事であり全 task で必要なものではないため required にはしない。
{ command -v fly >/dev/null 2>&1 || command -v flyctl >/dev/null 2>&1; } && echo optional
