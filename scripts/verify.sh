#!/usr/bin/env bash
# Compatibility alias; one implementation of verification.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-server.sh" "$@"
