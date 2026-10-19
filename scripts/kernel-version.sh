#!/bin/sh
# 打印内核包对应的内核版本号；无法判断时静默退出（Make 会得到空串）。
set -eu
pkg=${1:-}
[ -n "$pkg" ] || exit 0
[ -f "$pkg" ] || exit 0
case "$pkg" in
*.pkg.tar.zst)
	bsdtar -tf "$pkg" 2>/dev/null | sed -n 's|^usr/lib/modules/\([^/]*\)/vmlinuz$|\1|p' | head -1
	;;
*)
	tar -tf "$pkg" 2>/dev/null | sed -n 's|^vmlinuz-\(.*\)$|\1|p' | head -1
	;;
esac
