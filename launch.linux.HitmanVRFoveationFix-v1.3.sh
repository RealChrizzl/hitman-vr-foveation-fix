#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$(readlink -f -- "$0")")"
exec sudo -E python3 ./Linux-HitmanVRFoveationFix-v1.3.py "$@"
