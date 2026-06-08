#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export TMUX_SMOKE_SESSIONS="$TMP/sessions"
export TMUX_SMOKE_SWITCH_FILE="$TMP/switch"
export TMUX_SMOKE_MESSAGES="$TMP/messages"
export TMUX_SMOKE_OPEN_FILE="$TMP/sidebar-open"
export TMUX_SMOKE_WINDOW_PANES="$TMP/window-panes"
export TMUX_SMOKE_WINDOWS="$TMP/windows"
export TMUX_SMOKE_LIST_WINDOWS_LOG="$TMP/list-windows-log"
export TMUX_SMOKE_MARKED_PANES="$TMP/marked-panes"
export TMUX_SMOKE_KILLED_PANES="$TMP/killed-panes"
export TMUX_SMOKE_SPLIT_PANES="$TMP/split-panes"
export TMUX_SMOKE_CURRENT_ID='$1'
export TMUX_SMOKE_CURRENT_NAME="alpha"
export TMUX_SMOKE_LAST_NAME=""

PIN_FILE="$HOME/.config/tmux/pinned-sessions"

mkdir -p "$TMP/bin" "$HOME/.config/tmux" "$HOME/bin"
ln -s "$ROOT/bin/tmux-session-sidebar" "$HOME/bin/tmux-session-sidebar"

cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/sh
tab=$(printf '\t')

sessions() {
	while IFS='|' read -r name id activity; do
		[ -n "$name" ] || continue
		case "$1" in
			name-tab-id) printf '%s\t%s\n' "$name" "$id" ;;
			id-tab-name) printf '%s\t%s\n' "$id" "$name" ;;
			name-pipe-id) printf '%s|%s\n' "$name" "$id" ;;
			id-pipe-name) printf '%s|%s\n' "$id" "$name" ;;
			id-only) printf '%s\n' "$id" ;;
		esac
	done < "$TMUX_SMOKE_SESSIONS"
}

session_activity() {
	target="$1"
	while IFS='|' read -r name id activity; do
		[ "$id" = "$target" ] && {
			printf '%s\n' "$activity"
			return 0
		}
	done < "$TMUX_SMOKE_SESSIONS"
}

windows() {
	if [ -s "$TMUX_SMOKE_WINDOWS" ]; then
		while IFS='|' read -r id active name; do
			[ -n "$id" ] || continue
			printf '%s\t%s\t%s\n' "$id" "$active" "$name"
		done < "$TMUX_SMOKE_WINDOWS"
		return
	fi
	while IFS='|' read -r name id activity; do
		[ -n "$id" ] || continue
		printf '%s\t1\tmain\n' "$id"
	done < "$TMUX_SMOKE_SESSIONS"
}

format_arg() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-F|-aF) printf '%s\n' "$2"; return 0 ;;
		esac
		shift
	done
}

case "${1:-}" in
	list-sessions)
		format=""
		[ "${2:-}" = "-F" ] && format="${3:-}"
		if [ "$format" = "#{session_name}${tab}#{session_id}" ]; then
			sessions name-tab-id
		elif [ "$format" = "#{session_id}${tab}#{session_name}" ]; then
			sessions id-tab-name
		elif [ "$format" = '#{session_name}|#{session_id}' ]; then
			sessions name-pipe-id
		elif [ "$format" = '#{session_id}|#{session_name}' ]; then
			sessions id-pipe-name
		elif [ "$format" = '#{session_id}' ]; then
			sessions id-only
		else
			sessions name-tab-id
		fi
		;;
	list-windows)
		printf '%s\n' "$*" >> "$TMUX_SMOKE_LIST_WINDOWS_LOG"
		format="$(format_arg "$@")"
		if [ "$format" = '#{window_id} #{@pin_sidebar_pane}' ]; then
			cat "$TMUX_SMOKE_WINDOW_PANES" 2>/dev/null || :
		elif [ "$format" = "#{session_id}${tab}#{window_active}${tab}#{window_name}" ]; then
			windows
		elif [ "$format" = '#{window_id}' ]; then
			if [ -s "$TMUX_SMOKE_WINDOW_PANES" ]; then
				awk '{ print $1 }' "$TMUX_SMOKE_WINDOW_PANES"
			else
				printf '@1\n'
			fi
		else
			printf '1|main\n'
		fi
		;;
	list-panes)
		if [ "${2:-}" = "-aF" ]; then
			cat "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null || :
		fi
		;;
	display-message)
		shift
		print=0
		target=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-p) print=1; shift ;;
				-t) target="$2"; shift 2 ;;
				*) break ;;
			esac
		done
		if [ "$print" = "0" ]; then
			printf '%s\n' "$*" >> "$TMUX_SMOKE_MESSAGES"
			exit 0
		fi
		case "${1:-}" in
			'#{session_id}') printf '%s\n' "$TMUX_SMOKE_CURRENT_ID" ;;
			'#S') printf '%s\n' "$TMUX_SMOKE_CURRENT_NAME" ;;
			'#{client_last_session}') printf '%s\n' "$TMUX_SMOKE_LAST_NAME" ;;
			'#{session_activity}') session_activity "$target" ;;
		esac
		;;
	switch-client)
		shift
		target=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-t) target="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		printf '%s\n' "$target" > "$TMUX_SMOKE_SWITCH_FILE"
		;;
	show-options)
		case "$*" in
			*"@pin_sidebar_open"*) cat "$TMUX_SMOKE_OPEN_FILE" 2>/dev/null || : ;;
			*) printf '20\n' ;;
		esac
		;;
	set-option)
		if [ "${2:-}" = "-g" ] && [ "${3:-}" = "@pin_sidebar_open" ]; then
			printf '%s\n' "${4:-}" > "$TMUX_SMOKE_OPEN_FILE"
		fi
		;;
	kill-pane)
		shift
		target=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-t) target="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		printf '%s\n' "$target" >> "$TMUX_SMOKE_KILLED_PANES"
		;;
	split-window)
		count="$(wc -l < "$TMUX_SMOKE_SPLIT_PANES" 2>/dev/null || printf 0)"
		pane="%new$((count + 1))"
		printf '%s\n' "$pane" >> "$TMUX_SMOKE_SPLIT_PANES"
		printf '%s\n' "$pane"
		;;
	wait-for|send-keys|refresh-client|resize-pane)
		;;
	*)
		;;
esac
EOF
chmod +x "$TMP/bin/tmux"

pass() {
	printf 'ok %s\n' "$1"
}

set_sessions() {
	: > "$TMUX_SMOKE_SESSIONS"
	for line in "$@"; do
		printf '%s\n' "$line" >> "$TMUX_SMOKE_SESSIONS"
	done
}

write_pins() {
	: > "$PIN_FILE"
	for line in "$@"; do
		printf '%s\n' "$line" >> "$PIN_FILE"
	done
}

assert_pins() {
	expected="$1"
	actual="$(cat "$PIN_FILE" 2>/dev/null || :)"
	if [ "$actual" != "$expected" ]; then
		printf 'unexpected pins\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
		exit 1
	fi
}

assert_file_contains() {
	grep -F "$2" "$1" >/dev/null || {
		printf 'expected %s to contain: %s\n' "$1" "$2" >&2
		exit 1
	}
}

assert_line_count() {
	actual="$(wc -l < "$1" 2>/dev/null | awk '{ print $1 }')"
	if [ "$actual" != "$2" ]; then
		printf 'expected %s line(s) in %s, got %s\n' "$2" "$1" "$actual" >&2
		cat "$1" 2>/dev/null >&2 || :
		exit 1
	fi
}

run_script() {
	sh "$ROOT/bin/tmux-session-sidebar/$1" "${2:-}"
}

test_sync_migrates_and_dedupes() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'beta' '$1' 'missing' 'alpha	$9' 'beta	$2'

	run_script sync-pins

	assert_pins "$(printf 'beta\t$2\nalpha\t$1')"
	pass "sync migrates legacy pins and dedupes"
}

test_sync_repairs_rename_by_id() {
	set_sessions 'new-name|$1|10'
	write_pins 'old-name	$1'

	run_script sync-pins

	assert_pins "$(printf 'new-name\t$1')"
	pass "sync repairs rename by id"
}

test_sync_repairs_resurrect_id_by_name() {
	set_sessions 'alpha|$7|10'
	write_pins 'alpha	$1'

	run_script sync-pins

	assert_pins "$(printf 'alpha\t$7')"
	pass "sync repairs resurrect id by name"
}

test_toggle_pins_and_unpins() {
	set_sessions 'alpha|$1|10'
	: > "$PIN_FILE"
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"

	run_script toggle
	assert_pins "$(printf 'alpha\t$1')"

	run_script toggle
	assert_pins ""
	pass "toggle pins and unpins canonical entry"
}

test_cycle_uses_canonical_ids() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'alpha	$1' 'beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$1'
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script cycle next

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$2'
	pass "cycle switches by canonical id"
}

test_replace_last_active_updates_slot() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'alpha	$1' 'beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$3'
	export TMUX_SMOKE_CURRENT_NAME="gamma"
	export TMUX_SMOKE_LAST_NAME="beta"

	run_script replace-last-active

	assert_pins "$(printf 'alpha\t$1\ngamma\t$3')"
	pass "replace-last-active writes name and id"
}

test_prune_delegates_to_sync() {
	set_sessions 'alpha|$1|10'
	write_pins 'alpha	$1' 'dead	$9'

	run_script prune

	assert_pins "$(printf 'alpha\t$1')"
	pass "prune drops dead canonical pins"
}

test_sidebar_renders_canonical_pin() {
	set_sessions 'alpha|$1|10'
	write_pins 'alpha	$1'
	export TMUX_SMOKE_CURRENT_ID='$1'

	sh "$ROOT/bin/tmux-session-sidebar/sidebar" </dev/null > "$TMP/sidebar.out"

	assert_file_contains "$TMP/sidebar.out" "alpha"
	pass "sidebar renders canonical pin"
}

test_sidebar_batches_window_listing() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'alpha	$1' 'beta	$2' 'gamma	$3'
	printf '$1|1|main\n$1|0|edit\n$2|1|work\n$3|1|ops\n' > "$TMUX_SMOKE_WINDOWS"
	: > "$TMUX_SMOKE_LIST_WINDOWS_LOG"
	export TMUX_SMOKE_CURRENT_ID='$2'

	sh "$ROOT/bin/tmux-session-sidebar/sidebar" </dev/null > "$TMP/sidebar-batch.out"

	assert_file_contains "$TMP/sidebar-batch.out" "alpha"
	assert_file_contains "$TMP/sidebar-batch.out" "beta"
	assert_file_contains "$TMP/sidebar-batch.out" "gamma"
	assert_file_contains "$TMP/sidebar-batch.out" "work"
	assert_line_count "$TMUX_SMOKE_LIST_WINDOWS_LOG" 1
	pass "sidebar batches window listing"
}

test_reload_restarts_open_sidebars() {
	set_sessions 'alpha|$1|10'
	write_pins 'alpha	$1'
	printf '1\n' > "$TMUX_SMOKE_OPEN_FILE"
	printf '@1 %%old1\n@2 %%old2\n' > "$TMUX_SMOKE_WINDOW_PANES"
	printf '%%old2 1\n%%old3 1\n' > "$TMUX_SMOKE_MARKED_PANES"
	: > "$TMUX_SMOKE_KILLED_PANES"
	: > "$TMUX_SMOKE_SPLIT_PANES"

	run_script reload

	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old1"
	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old2"
	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old3"
	assert_line_count "$TMUX_SMOKE_SPLIT_PANES" 2
	pass "reload restarts open sidebar panes"
}

test_sync_migrates_and_dedupes
test_sync_repairs_rename_by_id
test_sync_repairs_resurrect_id_by_name
test_toggle_pins_and_unpins
test_cycle_uses_canonical_ids
test_replace_last_active_updates_slot
test_prune_delegates_to_sync
test_sidebar_renders_canonical_pin
test_sidebar_batches_window_listing
test_reload_restarts_open_sidebars

printf 'PASS tmux sidebar smoke tests\n'
