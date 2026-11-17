#!/bin/bash
set -euo pipefail

# nanoMuse: 缓存和所有回退源均核对固定摘要，只有完整且校验成功的包才原子替换缓存。
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <cache-file> <sha256> <https-url>..." >&2
    exit 2
fi
archive="$1"
expected_sha256="$2"
shift 2

if [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid SHA-256." >&2
    exit 2
fi

# macOS自带shasum；失败和摘要不匹配都不能被视为有效缓存。
has_expected_hash() {
    local actual
    [ -f "$1" ] || return 1
    actual="$(shasum -a 256 "$1")" || return 1
    [ "${actual%% *}" = "$expected_sha256" ]
}

mkdir -p "$(dirname "$archive")"
if has_expected_hash "$archive"; then
    echo "Using verified source cache: $archive"
    exit 0
fi
rm -f "$archive"
partial="$(mktemp "${archive}.part.XXXXXX")"
trap 'rm -f "$partial"' EXIT

for url in "$@"; do
    if [[ "$url" != https://* ]]; then
        echo "Refusing non-HTTPS source: $url" >&2
        continue
    fi
    # DNS、HTTP和传输错误均有限重试；重定向仍须HTTPS，失败的片段不进入缓存。
    echo "Downloading verified source candidate: $url"
    if curl --fail --location --show-error --silent \
        --proto '=https' --proto-redir '=https' \
        --retry 3 --retry-all-errors --retry-delay 3 \
        --connect-timeout 20 --max-time 180 --retry-max-time 240 \
        --output "$partial" "$url"; then
        if has_expected_hash "$partial"; then
            mv -f "$partial" "$archive"
            exit 0
        fi
        echo "SHA-256 mismatch, rejecting source: $url" >&2
    fi
done

echo "All source candidates failed download or SHA-256 verification." >&2
exit 1
