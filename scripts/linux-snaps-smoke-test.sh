#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/linux-snaps-smoke-test.$$
fakebin="$tmp/bin"
log="$tmp/sudo.log"
mkdir -p "$fakebin"
trap 'rm -rf "$tmp"' EXIT

cat > "$fakebin/uname" <<'SH'
#!/bin/sh
echo Linux
SH

cat > "$fakebin/snap" <<'SH'
#!/bin/sh
exit 0
SH

cat > "$fakebin/sudo" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
exit 0
SH

chmod +x "$fakebin/uname" "$fakebin/snap" "$fakebin/sudo"

PATH="$fakebin:/usr/bin:/bin" sh "$repo_root/scripts/install-linux-snaps.sh"

grep -qx 'snap wait system seed.loaded' "$log"
grep -qx 'snap install yazi --classic' "$log"
grep -qx 'snap install newsboat' "$log"

linux_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Linux is_wsl=0 setup)
printf '%s\n' "$linux_setup_plan" | grep -q 'sh ./scripts/install-linux-snaps.sh'
printf '%s\n' "$linux_setup_plan" | grep -Eq 'apt install .*snapd'
! printf '%s\n' "$linux_setup_plan" | grep -Eq 'apt install .*yazi'

debian_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Linux LINUX_ID=debian is_wsl=0 setup)
case "$debian_setup_plan" in
	*"add-apt-repository universe"* | *"ppa:aslatter/ppa"*)
		printf 'Debian setup must not add Ubuntu repositories\n' >&2
		exit 1
		;;
esac

ubuntu_setup_plan=$(make -n -C "$repo_root" --no-print-directory UNAME=Linux LINUX_ID=ubuntu is_wsl=0 setup)
case "$ubuntu_setup_plan" in
	*"add-apt-repository universe"*"ppa:aslatter/ppa"*) ;;
	*)
		printf 'Ubuntu setup should add Ubuntu repositories\n' >&2
		exit 1
		;;
esac

echo "PASS linux snaps smoke test"
