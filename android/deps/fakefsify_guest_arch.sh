#!/bin/bash
set -euo pipefail

# nanoMuse: fakefsify不执行guest代码，仅选择宿主支持的Meson源码组合。
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <host-architecture>" >&2
    exit 2
fi

case "$1" in
    x86_64) printf '%s\n' x86 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *)
        echo "Unsupported fakefsify host architecture: $1" >&2
        exit 1
        ;;
esac
