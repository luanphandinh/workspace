#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/nvim-reference-smoke-test.$$
home="$tmp/home"
fakebin="$tmp/bin"
log="$tmp/nvim.log"
server="$tmp/nvim.sock"
reference="$repo_root/nvim/lua/luanphan/terminal_references.lua"
mkdir -p "$home/.nix-profile/bin" "$fakebin"
trap 'rm -rf "$tmp"' EXIT

real_python=$(command -v python3)
ln -s "$real_python" "$home/.nix-profile/bin/python3"
: > "$server"

cat > "$fakebin/python3" <<'SH'
#!/bin/sh
exit 99
SH
cat > "$fakebin/nvim" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$log"
SH
chmod +x "$fakebin/python3" "$fakebin/nvim"

url=$(
	"$real_python" - "$server" "$reference" <<'PY'
import sys
from urllib.parse import urlencode

print(
    "nvim-ref://open?"
    + urlencode(
        {
            "server": sys.argv[1],
            "path": sys.argv[2],
            "line": 42,
            "column": 3,
        }
    )
)
PY
)

HOME="$home" PATH="$fakebin:/usr/bin:/bin" \
	sh "$repo_root/bin/nvim-open-reference-url" "$url"

grep -Fxq -- '--server' "$log"
grep -Fxq -- "$server" "$log"
grep -Fxq -- '--remote-expr' "$log"
grep -Fq -- "terminal_references').open" "$log"
grep -Fq -- "\"path\": \"$reference\"" "$log"
grep -Fq -- '"line": 42' "$log"
grep -Fq -- '"column": 3' "$log"

printf '%s\n' 'nvim reference smoke test passed'
