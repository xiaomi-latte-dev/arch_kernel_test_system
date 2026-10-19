#!/bin/sh
# 把内核包（Arch pacman 包或旧 tar.gz）解包成测试系统需要的扁平布局：
#   <dest>/vmlinuz-<ver>
#   <dest>/lib/modules/<ver>/...
# pacman 包额外需要：解压 zstd 模块、补跑 depmod（PKGBUILD 以 DEPMOD=true 跳过了索引）。
set -eu

pkg=$1
dest=$2
decompress=${3:-y}

[ -n "$pkg" ] || { echo "未找到内核包（*.pkg.tar.zst 或 kernel-*.tar.gz）" >&2; exit 1; }
[ -f "$pkg" ] || { echo "内核包不存在: $pkg" >&2; exit 1; }

here=$(dirname "$0")
ver=$($here/kernel-version.sh "$pkg")
[ -n "$ver" ] || { echo "无法从内核包推断版本: $pkg" >&2; exit 1; }
echo "内核版本: $ver"

mkdir -p "$dest"
case "$pkg" in
*.pkg.tar.zst) bsdtar -xf "$pkg" -C "$dest" ;;
*) tar -xf "$pkg" -C "$dest" ;;
esac

# pacman 包：usr/lib/modules/<ver>/vmlinuz -> vmlinuz-<ver>，模块 -> lib/modules/<ver>
if [ -e "$dest/usr/lib/modules/$ver/vmlinuz" ]; then
	mv "$dest/usr/lib/modules/$ver/vmlinuz" "$dest/vmlinuz-$ver"
	mkdir -p "$dest/lib"
	mv "$dest/usr/lib/modules" "$dest/lib/modules"
fi
rm -rf "$dest/usr" "$dest/.PKGINFO" "$dest/.BUILDINFO" "$dest/.MTREE"

moddir=$dest/lib/modules/$ver
[ -d "$moddir" ] || { echo "模块目录缺失: $moddir" >&2; exit 1; }

if [ "$decompress" = y ]; then
	# busybox modprobe 不认 .ko.zst，统一解压成 .ko
	find "$moddir" -name '*.ko.zst' -print0 |
		while IFS= read -r -d '' k; do zstd -q -d --rm "$k" -o "${k%.zst}"; done
fi

# initrd 里的 modprobe 依赖 modules.dep
depmod -b "$dest" "$ver"

echo "已解包: $dest/vmlinuz-$ver"
