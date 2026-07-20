#!/usr/bin/env bash
set -euo pipefail

busybox_binary=${1:?usage: make-initramfs.sh BUSYBOX OUTPUT}
output=${2:?usage: make-initramfs.sh BUSYBOX OUTPUT}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
staging=$(mktemp -d)

mkdir -p "$staging/bin" "$staging/dev" "$staging/proc" "$staging/sys"
install -m 0755 "$busybox_binary" "$staging/bin/busybox"
install -m 0755 "$script_dir/initramfs-init" "$staging/init"

(
	cd "$staging"
	find . -print0 | cpio --null -o --format=newc
) > "$output"

printf 'Created %s\n' "$output"
