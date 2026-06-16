#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

linux_plan=$(make -n --no-print-directory UNAME=Linux ARCH=x86_64 is_wsl=0 csvlens-install)
printf '%s\n' "$linux_plan" | grep -qx 'sh ./scripts/install-csvlens.sh'

darwin_plan=$(make -n --no-print-directory UNAME=Darwin ARCH=arm64 csvlens-install)
printf '%s\n' "$darwin_plan" | grep -qx 'true'

linux_setup_plan=$(make -n --no-print-directory UNAME=Linux ARCH=x86_64 is_wsl=0 setup)
printf '%s\n' "$linux_setup_plan" | grep -Eq 'apt install .*xz-utils'
printf '%s\n' "$linux_setup_plan" | grep -q 'sh ./scripts/install-csvlens.sh'

darwin_setup_plan=$(make -n --no-print-directory UNAME=Darwin ARCH=arm64 setup)
printf '%s\n' "$darwin_setup_plan" | grep -Eq 'brew install .*csvlens'

grep -q 'target_arch=x86_64' scripts/install-csvlens.sh
grep -q 'target_arch=aarch64' scripts/install-csvlens.sh
grep -q 'csvlens-${target_arch}-unknown-linux-gnu.tar.xz' scripts/install-csvlens.sh
grep -q 'CSVLENS_VERSION:-0.15.1' scripts/install-csvlens.sh

if command -v csvlens >/dev/null 2>&1; then
	csvlens --version | grep -qi '^csvlens'
else
	echo "skip csvlens binary validation"
fi

echo "PASS csvlens smoke test"
