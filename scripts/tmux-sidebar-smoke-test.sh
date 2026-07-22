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
export TMUX_SMOKE_LAYOUT_FILE="$TMP/window-layout"
export TMUX_SMOKE_RESTORE_LAYOUT_FILE="$TMP/restore-layout"
export TMUX_SMOKE_SELECTED_LAYOUTS="$TMP/selected-layouts"
export TMUX_SMOKE_FOCUS_FILE="$TMP/focus"
export TMUX_SMOKE_COMMAND_LOG="$TMP/commands"
export TMUX_SMOKE_CURRENT_ID='$1'
export TMUX_SMOKE_CURRENT_WINDOW='@1'
export TMUX_SMOKE_PANE_WINDOW='@1'
export TMUX_SMOKE_CURRENT_NAME="alpha"
export TMUX_SMOKE_LAST_NAME=""

PIN_FILE="$HOME/.config/tmux/pinned-sessions"

mkdir -p "$TMP/bin" "$HOME/.config/tmux" "$HOME/bin"
ln -s "$ROOT/bin/tmux-session-sidebar" "$HOME/bin/tmux-session-sidebar"

cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/sh
tab=$(printf '\t')
printf '%s\n' "$*" >> "$TMUX_SMOKE_COMMAND_LOG"

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
	mode="$1"
	n=0
	if [ -s "$TMUX_SMOKE_WINDOWS" ]; then
		while IFS='|' read -r session window active name; do
			[ -n "$session" ] || continue
			n=$((n + 1))
			if [ -z "$name" ]; then
				name="$active"
				active="$window"
				window="@${n}"
			fi
			case "$mode" in
				session-active-name) printf '%s\t%s\t%s\n' "$session" "$active" "$name" ;;
				session-window-name) printf '%s\t%s\t%s\n' "$session" "$window" "$name" ;;
				window-session) printf '%s\t%s\n' "$window" "$session" ;;
				window-id) printf '%s\n' "$window" ;;
			esac
		done < "$TMUX_SMOKE_WINDOWS"
		return
	fi
	while IFS='|' read -r name id activity; do
		[ -n "$id" ] || continue
		case "$mode" in
			session-active-name) printf '%s\t1\tmain\n' "$id" ;;
			session-window-name) printf '%s\t@1\tmain\n' "$id" ;;
			window-session) printf '@1\t%s\n' "$id" ;;
			window-id) printf '@1\n' ;;
		esac
	done < "$TMUX_SMOKE_SESSIONS"
}

window_session() {
	target="$1"
	windows window-session | awk -v target="$target" '$1 == target { print $2; exit }'
}

focus_value() {
	win="$1"
	field="$2"
	[ -n "$win" ] || win="$TMUX_SMOKE_CURRENT_WINDOW"
	case "$win" in
		%*) win="$TMUX_SMOKE_PANE_WINDOW" ;;
	esac
	value="$(awk -v win="$win" -v field="$field" '
		$1 == win {
			if (field == "session") print $2
			else print $3
			exit
		}
	' "$TMUX_SMOKE_FOCUS_FILE" 2>/dev/null || :)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	elif [ "$field" = "session" ]; then
		printf '%s\n' "$TMUX_SMOKE_CURRENT_ID"
	else
		printf '%s\n' "$TMUX_SMOKE_CURRENT_WINDOW"
	fi
}

set_focus_value() {
	win="$1"
	field="$2"
	value="$3"
	session="$(focus_value "$win" session)"
	window="$(focus_value "$win" window)"
	if [ "$field" = "session" ]; then
		session="$value"
	else
		window="$value"
	fi
	awk -v win="$win" '$1 != win { print }' "$TMUX_SMOKE_FOCUS_FILE" 2>/dev/null > "$TMUX_SMOKE_FOCUS_FILE.tmp" || :
	printf '%s %s %s\n' "$win" "$session" "$window" >> "$TMUX_SMOKE_FOCUS_FILE.tmp"
	mv "$TMUX_SMOKE_FOCUS_FILE.tmp" "$TMUX_SMOKE_FOCUS_FILE"
}

format_arg() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-F|-aF) printf '%s\n' "$2"; return 0 ;;
		esac
		shift
	done
}

target_arg() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-t) printf '%s\n' "$2"; return 0 ;;
		esac
		shift
	done
}

window_pane() {
	win="$1"
	awk -v win="$win" '$1 == win { print $2; exit }' "$TMUX_SMOKE_WINDOW_PANES" 2>/dev/null || :
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
			windows session-active-name
		elif [ "$format" = "#{session_id}${tab}#{window_id}${tab}#{window_name}" ]; then
			windows session-window-name
		elif [ "$format" = "#{window_id}${tab}#{session_id}" ]; then
			windows window-session
		elif [ "$format" = '#{window_id}' ]; then
			if [ -s "$TMUX_SMOKE_WINDOW_PANES" ]; then
				awk '{ print $1 }' "$TMUX_SMOKE_WINDOW_PANES"
			elif [ -s "$TMUX_SMOKE_WINDOWS" ]; then
				windows window-id
			else
				printf '@1\n'
			fi
		else
			printf '1|main\n'
		fi
		;;
	list-panes)
		format="$(format_arg "$@")"
		target="$(target_arg "$@")"
		if [ "$format" = '#{pane_id}' ]; then
			window_pane "$target"
			awk -v win="$target" 'NF == 3 && $1 == win && $3 == "1" { print $2 }' "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null || :
		elif [ "$format" = '#{pane_id} #{@pin_sidebar}' ] && [ -n "$target" ]; then
			pane="$(window_pane "$target")"
			[ -n "$pane" ] && printf '%s 1\n' "$pane"
			awk -v win="$target" 'NF == 3 && $1 == win && $3 == "1" { print $2, $3 }' "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null || :
		elif [ "${2:-}" = "-aF" ] && [ "$format" = '#{window_id} #{pane_id} #{@pin_sidebar}' ]; then
			awk 'NF == 2 { print "@1", $1, $2; next } NF { print }' "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null || :
		elif [ "${2:-}" = "-aF" ]; then
			awk 'NF == 3 { print $2, $3; next } NF { print }' "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null || :
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
			'#{client_width}') printf '120\n' ;;
			'#{client_height}') printf '40\n' ;;
			'#{session_id}') printf '%s\n' "$TMUX_SMOKE_CURRENT_ID" ;;
			'#{window_id}') printf '%s\n' "$TMUX_SMOKE_CURRENT_WINDOW" ;;
			'#S') printf '%s\n' "$TMUX_SMOKE_CURRENT_NAME" ;;
			'#{client_last_session}') printf '%s\n' "$TMUX_SMOKE_LAST_NAME" ;;
			'#{session_activity}') session_activity "$target" ;;
			'#{window_layout}') cat "$TMUX_SMOKE_LAYOUT_FILE" 2>/dev/null || : ;;
			'#{pane_width}') printf '20\n' ;;
			*)
				if [ "${1:-}" = "#{window_id}${tab}#{session_id}" ]; then
					printf '%s\t%s\n' "$target" "$(window_session "$target")"
				fi
				;;
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
			*"@pin_sidebar_width"*) printf '20\n' ;;
			*"@pin_sidebar_focus_session"*) focus_value "$(target_arg "$@")" session ;;
			*"@pin_sidebar_focus_window"*) focus_value "$(target_arg "$@")" window ;;
			*"@pin_sidebar_pane"*) window_pane "$(target_arg "$@")" ;;
			*"@pin_sidebar_restore_layout"*) cat "$TMUX_SMOKE_RESTORE_LAYOUT_FILE" 2>/dev/null || : ;;
			*"window-size"*) printf 'latest\n' ;;
			*"status"*) printf 'off\n' ;;
			*) printf '20\n' ;;
		esac
		;;
	set-option)
		if [ "${2:-}" = "-g" ] && [ "${3:-}" = "@pin_sidebar_open" ]; then
			printf '%s\n' "${4:-}" > "$TMUX_SMOKE_OPEN_FILE"
		elif [ "${2:-}" = "-gu" ] && [ "${3:-}" = "@pin_sidebar_open" ]; then
			: > "$TMUX_SMOKE_OPEN_FILE"
		elif [ "${2:-}" = "-wt" ] && [ "${4:-}" = "@pin_sidebar_pane" ]; then
			awk -v win="${3:-}" '$1 != win { print }' "$TMUX_SMOKE_WINDOW_PANES" 2>/dev/null > "$TMUX_SMOKE_WINDOW_PANES.tmp" || :
			printf '%s %s\n' "${3:-}" "${5:-}" >> "$TMUX_SMOKE_WINDOW_PANES.tmp"
			mv "$TMUX_SMOKE_WINDOW_PANES.tmp" "$TMUX_SMOKE_WINDOW_PANES"
		elif [ "${2:-}" = "-wu" ] && [ "${3:-}" = "-t" ] && [ "${5:-}" = "@pin_sidebar_pane" ]; then
			awk -v win="${4:-}" '$1 != win { print }' "$TMUX_SMOKE_WINDOW_PANES" 2>/dev/null > "$TMUX_SMOKE_WINDOW_PANES.tmp" || :
			mv "$TMUX_SMOKE_WINDOW_PANES.tmp" "$TMUX_SMOKE_WINDOW_PANES"
		elif [ "${2:-}" = "-wt" ] && [ "${4:-}" = "@pin_sidebar_restore_layout" ]; then
			printf '%s\n' "${5:-}" > "$TMUX_SMOKE_RESTORE_LAYOUT_FILE"
		elif [ "${2:-}" = "-wu" ] && [ "${3:-}" = "-t" ] && [ "${5:-}" = "@pin_sidebar_restore_layout" ]; then
			: > "$TMUX_SMOKE_RESTORE_LAYOUT_FILE"
		elif [ "${2:-}" = "-wt" ] && [ "${4:-}" = "@pin_sidebar_focus_session" ]; then
			set_focus_value "${3:-}" session "${5:-}"
		elif [ "${2:-}" = "-wt" ] && [ "${4:-}" = "@pin_sidebar_focus_window" ]; then
			set_focus_value "${3:-}" window "${5:-}"
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
		awk -v pane="$target" '!(NF == 2 && $1 == pane) && !(NF == 3 && $2 == pane) { print }' "$TMUX_SMOKE_MARKED_PANES" 2>/dev/null > "$TMUX_SMOKE_MARKED_PANES.tmp" || :
		mv "$TMUX_SMOKE_MARKED_PANES.tmp" "$TMUX_SMOKE_MARKED_PANES"
		;;
	split-window)
		count="$(wc -l < "$TMUX_SMOKE_SPLIT_PANES" 2>/dev/null || printf 0)"
		pane="%new$((count + 1))"
		printf '%s\n' "$pane" >> "$TMUX_SMOKE_SPLIT_PANES"
		printf '%s\n' "$pane"
		;;
	select-layout)
		shift
		target=""
		if [ "${1:-}" = "-t" ]; then
			target="$2"
			shift 2
		fi
		printf '%s %s\n' "$target" "${1:-}" >> "$TMUX_SMOKE_SELECTED_LAYOUTS"
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

assert_file_not_contains() {
	if grep -F "$2" "$1" >/dev/null; then
		printf 'expected %s not to contain: %s\n' "$1" "$2" >&2
		exit 1
	fi
}

assert_file_not_contains_line() {
	if grep -Fx "$2" "$1" >/dev/null; then
		printf 'expected %s not to contain line: %s\n' "$1" "$2" >&2
		exit 1
	fi
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

test_jump_uses_pin_slot() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'alpha	$1' 'beta	$2' 'gamma	$3'
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script jump 2

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$2'
	pass "jump switches by pinned slot"
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
	assert_file_contains "$TMP/sidebar.out" "↑/↓ | j/k session"
	assert_file_contains "$TMP/sidebar.out" "←/→ | h/l window"
	assert_file_contains "$TMP/sidebar.out" "Cmd/Alt +"
	assert_file_not_contains_line "$TMP/sidebar.out" "C-S +"
	pass "sidebar renders canonical pin"
}

test_sidebar_batches_window_listing() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'alpha	$1' 'beta	$2' 'gamma	$3'
	printf '$1|@1|1|main\n$1|@2|0|edit\n$2|@3|1|work\n$3|@4|1|ops\n' > "$TMUX_SMOKE_WINDOWS"
	: > "$TMUX_SMOKE_LIST_WINDOWS_LOG"
	export TMUX_SMOKE_CURRENT_ID='$2'
	export TMUX_SMOKE_CURRENT_WINDOW='@3'

	sh "$ROOT/bin/tmux-session-sidebar/sidebar" </dev/null > "$TMP/sidebar-batch.out"

	assert_file_contains "$TMP/sidebar-batch.out" "alpha"
	assert_file_contains "$TMP/sidebar-batch.out" "beta"
	assert_file_contains "$TMP/sidebar-batch.out" "gamma"
	assert_file_contains "$TMP/sidebar-batch.out" "work"
	assert_file_contains "$TMP/sidebar-batch.out" "▸ work"
	assert_file_not_contains "$TMP/sidebar-batch.out" "  ▸ main"
	assert_file_not_contains "$TMP/sidebar-batch.out" "  ▸ ops"
	assert_line_count "$TMUX_SMOKE_LIST_WINDOWS_LOG" 1
	pass "sidebar batches window listing"
}

test_sidebar_wraps_long_labels_at_text_indent() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'alpha	$1'
	printf '$1|@1|1|example_project_name\n' > "$TMUX_SMOKE_WINDOWS"
	export TMUX_SMOKE_CURRENT_ID='$2'
	export TMUX_SMOKE_CURRENT_WINDOW='@2'

	sh "$ROOT/bin/tmux-session-sidebar/sidebar" </dev/null > "$TMP/sidebar-wrap.out"

	assert_file_contains "$TMP/sidebar-wrap.out" "  └ example_project_"
	assert_file_contains "$TMP/sidebar-wrap.out" "  │ name"
	pass "sidebar wraps long labels at text indent"
}

test_sidebar_uses_precomputed_window_focus() {
	set_sessions 'alpha|$1|10'
	write_pins 'alpha	$1'
	printf '$1|@1|0|main\n$1|@2|1|edit\n' > "$TMUX_SMOKE_WINDOWS"
	printf '@1 $1 @1\n' > "$TMUX_SMOKE_FOCUS_FILE"
	export TMUX_PANE='%side'
	export TMUX_SMOKE_PANE_WINDOW='@1'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_WINDOW='@2'

	sh "$ROOT/bin/tmux-session-sidebar/sidebar" </dev/null > "$TMP/sidebar-focus.out"

	assert_file_contains "$TMP/sidebar-focus.out" "▸ main"
	assert_file_not_contains "$TMP/sidebar-focus.out" "▸ edit"
	pass "sidebar uses precomputed window focus"
}

test_precompute_focus_sets_each_window_focus() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	printf '$1|@1|0|main\n$1|@2|1|edit\n$2|@3|1|work\n' > "$TMUX_SMOKE_WINDOWS"
	: > "$TMUX_SMOKE_FOCUS_FILE"

	run_script precompute-focus

	assert_file_contains "$TMUX_SMOKE_FOCUS_FILE" '@1 $1 @1'
	assert_file_contains "$TMUX_SMOKE_FOCUS_FILE" '@2 $1 @2'
	assert_file_contains "$TMUX_SMOKE_FOCUS_FILE" '@3 $2 @3'
	pass "precompute focus sets each window focus"
}

test_fit_windows_keeps_global_sizing_latest() {
	: > "$TMUX_SMOKE_COMMAND_LOG"

	run_script fit-windows

	assert_file_contains "$TMUX_SMOKE_COMMAND_LOG" 'resize-window -t @1 -x 120 -y 40'
	assert_file_contains "$TMUX_SMOKE_COMMAND_LOG" 'set-window-option -u -t @1 window-size'
	assert_file_not_contains "$TMUX_SMOKE_COMMAND_LOG" 'set-option -g window-size manual'
	pass "fit windows leaves global sizing unchanged"
}

test_reload_restarts_open_sidebars() {
	set_sessions 'alpha|$1|10'
	write_pins 'alpha	$1'
	printf '1\n' > "$TMUX_SMOKE_OPEN_FILE"
	printf '@1 %%old1\n@2 %%old2\n' > "$TMUX_SMOKE_WINDOW_PANES"
	printf '@1|1|main\n@2|1|main\n' > "$TMUX_SMOKE_WINDOWS"
	printf '@2 %%old2 1\n@2 %%old3 1\n' > "$TMUX_SMOKE_MARKED_PANES"
	: > "$TMUX_SMOKE_KILLED_PANES"
	: > "$TMUX_SMOKE_SPLIT_PANES"

	run_script reload

	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old1"
	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old2"
	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%old3"
	assert_line_count "$TMUX_SMOKE_SPLIT_PANES" 2
	pass "reload restarts open sidebar panes"
}

test_attach_saves_restore_layout() {
	set_sessions 'alpha|$1|10'
	printf '1\n' > "$TMUX_SMOKE_OPEN_FILE"
	printf 'layout-before-sidebar\n' > "$TMUX_SMOKE_LAYOUT_FILE"
	: > "$TMUX_SMOKE_WINDOW_PANES"
	: > "$TMUX_SMOKE_MARKED_PANES"
	: > "$TMUX_SMOKE_RESTORE_LAYOUT_FILE"

	run_script sidebar-attach '@1'

	assert_file_contains "$TMUX_SMOKE_RESTORE_LAYOUT_FILE" "layout-before-sidebar"
	pass "sidebar attach saves restore layout"
}

test_toggle_close_preserves_current_content_layout() {
	set_sessions 'alpha|$1|10'
	printf '1\n' > "$TMUX_SMOKE_OPEN_FILE"
	printf '@1 %%3\n' > "$TMUX_SMOKE_WINDOW_PANES"
	printf 'ef85,180x40,0,0{20x40,0,0,3,60x40,21,0[60x20,21,0,0,60x19,21,21,2],98x40,82,0,1}\n' > "$TMUX_SMOKE_LAYOUT_FILE"
	printf 'layout-before-sidebar\n' > "$TMUX_SMOKE_RESTORE_LAYOUT_FILE"
	: > "$TMUX_SMOKE_KILLED_PANES"
	: > "$TMUX_SMOKE_SELECTED_LAYOUTS"

	run_script sidebar-toggle

	assert_file_contains "$TMUX_SMOKE_KILLED_PANES" "%3"
	assert_file_contains "$TMUX_SMOKE_SELECTED_LAYOUTS" "@1 632a,180x40,0,0{68x40,0,0[68x20,0,0,0,68x19,0,21,2],111x40,69,0,1}"
	pass "sidebar close preserves current content layout"
}

test_sync_migrates_and_dedupes
test_sync_repairs_rename_by_id
test_sync_repairs_resurrect_id_by_name
test_toggle_pins_and_unpins
test_cycle_uses_canonical_ids
test_jump_uses_pin_slot
test_replace_last_active_updates_slot
test_prune_delegates_to_sync
test_sidebar_renders_canonical_pin
test_sidebar_batches_window_listing
test_sidebar_wraps_long_labels_at_text_indent
test_sidebar_uses_precomputed_window_focus
test_precompute_focus_sets_each_window_focus
test_fit_windows_keeps_global_sizing_latest
test_reload_restarts_open_sidebars
test_attach_saves_restore_layout
test_toggle_close_preserves_current_content_layout

printf 'PASS tmux sidebar smoke tests\n'
