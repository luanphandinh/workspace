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
export TMUX_SMOKE_FZF_INPUT="$TMP/fzf-input"
export TMUX_SMOKE_CURRENT_ID='$1'
export TMUX_SMOKE_CURRENT_NAME="alpha"
export TMUX_SMOKE_LAST_NAME=""

PIN_FILE="$HOME/.config/tmux/pinned-sessions"

mkdir -p "$TMP/bin" "$HOME/.config/tmux" "$HOME/bin"
ln -s "$ROOT/bin/tmux-pins" "$HOME/bin/tmux-pins"

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

session_name() {
	target="$1"
	while IFS='|' read -r name id activity; do
		[ "$id" = "$target" ] && {
			printf '%s\n' "$name"
			return 0
		}
	done < "$TMUX_SMOKE_SESSIONS"
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

			'#{session_id}')
				case "$target" in
					'$'*) printf '%s\n' "$target" ;;
					*) printf '%s\n' "$TMUX_SMOKE_CURRENT_ID" ;;
				esac
				;;

			'#S')
				if [ -n "$target" ]; then
					session_name "$target"
				else
					printf '%s\n' "$TMUX_SMOKE_CURRENT_NAME"
				fi
				;;
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

run_script() {
	script="$1"
	shift
	sh "$ROOT/bin/tmux-pins/$script" "$@"
}

test_sync_migrates_and_dedupes() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'beta' '$1' 'missing' 'alpha	$9' 'beta	$2'

	run_script sync-pins

	assert_pins "$(printf 'default\tbeta\t$2\ndefault\talpha\t$1')"
	pass "sync migrates legacy pins and dedupes"
}

test_sync_repairs_rename_by_id() {
	set_sessions 'new-name|$1|10'
	write_pins 'coding	old-name	$1'

	run_script sync-pins

	assert_pins "$(printf 'coding\tnew-name\t$1')"
	pass "sync repairs rename by id"
}

test_sync_repairs_resurrect_id_by_name() {
	set_sessions 'alpha|$7|10'
	write_pins 'coding	alpha	$1'

	run_script sync-pins

	assert_pins "$(printf 'coding\talpha\t$7')"
	pass "sync repairs resurrect id by name"
}

test_sync_keeps_one_profile_per_session() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'coding	alpha	$1' 'operations	alpha	$1' 'operations	beta	$2'

	run_script sync-pins

	assert_pins "$(printf 'coding\talpha\t$1\noperations\tbeta\t$2')"
	pass "sync keeps one profile per session"
}

test_sync_preserves_empty_profiles() {
	set_sessions 'alpha|$1|10'
	write_pins '@profile	code' 'default	alpha	$1' '@profile	code'

	run_script sync-pins

	assert_pins "$(printf '@profile\tcode\ndefault\talpha\t$1')"
	pass "sync preserves empty profiles"
}

test_toggle_pins_and_unpins() {
	set_sessions 'alpha|$1|10'
	: > "$PIN_FILE"
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"

	run_script toggle
	assert_pins "$(printf '@profile\tdefault\ndefault\talpha\t$1')"

	run_script toggle
	assert_pins "$(printf '@profile\tdefault')"
	pass "toggle pins and unpins canonical entry"
}

test_toggle_moves_session_between_profiles() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'coding	alpha	$1' 'operations	beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"

	run_script toggle pin operations '$1'

	assert_pins "$(printf 'operations\tbeta\t$2\n@profile\toperations\noperations\talpha\t$1')"
	assert_file_not_contains "$PIN_FILE" "coding"
	[ "$(run_script current-profile '$1')" = "operations" ]

	run_script toggle unpin '$1'
	assert_pins "$(printf 'operations\tbeta\t$2\n@profile\toperations')"
	pass "toggle moves session between profiles"
}

test_profile_views_are_per_session() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'coding	alpha	$1' 'operations	beta	$2'

	[ "$(run_script current-profile '$1')" = "coding" ]
	[ "$(run_script current-profile '$2')" = "operations" ]
	pass "profile views follow pin membership"
}

test_profile_selection_switches_to_member() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins '@profile	default' 'default	alpha	$1' '@profile	code' 'code	beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script profile select code '$1'

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$2'
	[ "$(run_script current-profile '$1')" = "default" ]
	[ "$(run_script current-profile '$2')" = "code" ]
	assert_pins "$(printf '@profile\tdefault\ndefault\talpha\t$1\n@profile\tcode\ncode\tbeta\t$2')"
	pass "profile selection switches instead of relabeling current session"
}

test_profile_picker_accepts_new_name() {
	set_sessions 'alpha|$1|10'
	write_pins 'default	alpha	$1'
	: > "$TMUX_SMOKE_SWITCH_FILE"
	cat > "$TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat > "$TMUX_SMOKE_FZF_INPUT"
printf 'review\ndefault\n'
EOF
	chmod +x "$TMP/bin/fzf"

	export TMUX_SMOKE_CURRENT_ID='$1'
	run_script profile pick

	assert_file_contains "$PIN_FILE" "$(printf '@profile\treview')"
	[ ! -s "$TMUX_SMOKE_SWITCH_FILE" ]
	[ "$(run_script current-profile '$1')" = "default" ]

	cat > "$TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat > "$TMUX_SMOKE_FZF_INPUT"
printf '\nreview\n'
EOF
	chmod +x "$TMP/bin/fzf"
	run_script profile pick

	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "review"
	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "del review"
	[ ! -s "$TMUX_SMOKE_SWITCH_FILE" ]
	rm -f "$TMP/bin/fzf"
	pass "profile picker preserves and reopens empty profile"
}

test_profile_picker_deletes_profile() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins '@profile	default' 'default	alpha	$1' '@profile	code' 'code	beta	$2'
	cat > "$TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat > "$TMUX_SMOKE_FZF_INPUT"
printf 'del \ndel code\n'
EOF
	chmod +x "$TMP/bin/fzf"

	run_script profile pick

	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "del code"
	assert_pins "$(printf '@profile\tdefault\ndefault\talpha\t$1')"
	[ "$(run_script current-profile '$2')" = "default" ]
	rm -f "$TMP/bin/fzf"
	pass "profile picker keeps delete suggestions and deletes selected profile"
}

test_pin_picker_assigns_and_unpins() {
	set_sessions 'alpha|$1|10'
	write_pins '@profile	default' '@profile	code'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"
	cat > "$TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat > "$TMUX_SMOKE_FZF_INPUT"
printf 'code\n'
EOF
	chmod +x "$TMP/bin/fzf"

	run_script pin pick

	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "default"
	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "code"
	assert_file_contains "$TMUX_SMOKE_FZF_INPUT" "unpin"
	assert_pins "$(printf '@profile\tdefault\n@profile\tcode\ncode\talpha\t$1')"
	[ "$(run_script current-profile '$1')" = "code" ]

	cat > "$TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat >/dev/null
printf 'unpin\n'
EOF
	chmod +x "$TMP/bin/fzf"
	run_script pin pick

	assert_pins "$(printf '@profile\tdefault\n@profile\tcode')"
	rm -f "$TMP/bin/fzf"
	pass "pin picker assigns and unpins explicitly"
}

test_cycle_uses_canonical_ids() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'default	alpha	$1' 'default	beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$1'
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script cycle next

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$2'
	pass "cycle switches by canonical id"
}

test_cycle_uses_selected_profile() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30' 'delta|$4|40'
	write_pins 'coding	alpha	$1' 'coding	beta	$2' 'operations	gamma	$3' 'operations	delta	$4'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script profile select operations '$1'
	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$3'
	export TMUX_SMOKE_CURRENT_ID='$3'
	export TMUX_SMOKE_CURRENT_NAME="gamma"
	: > "$TMUX_SMOKE_SWITCH_FILE"
	run_script cycle next

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$4'
	pass "cycle uses selected profile"
}

test_jump_uses_pin_slot() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'default	alpha	$1' 'default	beta	$2' 'default	gamma	$3'
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script jump 2

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$2'
	pass "jump switches by pinned slot"
}

test_jump_uses_selected_profile() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30' 'delta|$4|40'
	write_pins 'coding	alpha	$1' 'coding	beta	$2' 'operations	gamma	$3' 'operations	delta	$4'
	export TMUX_SMOKE_CURRENT_ID='$1'
	export TMUX_SMOKE_CURRENT_NAME="alpha"
	: > "$TMUX_SMOKE_SWITCH_FILE"

	run_script profile select operations '$1'
	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$3'
	export TMUX_SMOKE_CURRENT_ID='$3'
	export TMUX_SMOKE_CURRENT_NAME="gamma"
	: > "$TMUX_SMOKE_SWITCH_FILE"
	run_script jump 2

	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$4'
	pass "jump uses selected profile"
}

test_manual_session_switch_updates_profile_and_cycle_scope() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30' 'delta|$4|40'
	write_pins 'default	alpha	$1' 'default	beta	$2' 'code	gamma	$3' 'code	delta	$4'
	export TMUX_SMOKE_CURRENT_ID='$3'
	export TMUX_SMOKE_CURRENT_NAME="gamma"
	: > "$TMUX_SMOKE_SWITCH_FILE"

	[ "$(run_script current-profile)" = "code" ]
	run_script cycle next
	assert_file_contains "$TMUX_SMOKE_SWITCH_FILE" '$4'
	pass "manual session switch updates the movement profile"
}

test_clear_only_selected_profile() {
	set_sessions 'alpha|$1|10' 'beta|$2|20'
	write_pins 'operations	beta	$2' '@profile	coding' 'coding	alpha	$1'
	export TMUX_SMOKE_CURRENT_ID='$1'

	run_script clear

	assert_pins "$(printf 'operations\tbeta\t$2\n@profile\tcoding')"
	pass "clear only selected profile"
}

test_replace_last_active_updates_slot() {
	set_sessions 'alpha|$1|10' 'beta|$2|20' 'gamma|$3|30'
	write_pins 'default	alpha	$1' 'default	beta	$2'
	export TMUX_SMOKE_CURRENT_ID='$3'
	export TMUX_SMOKE_CURRENT_NAME="gamma"
	export TMUX_SMOKE_LAST_NAME="beta"

	run_script replace-last-active

	assert_pins "$(printf 'default\talpha\t$1\ndefault\tgamma\t$3')"
	pass "replace-last-active writes name and id"
}

test_sync_migrates_and_dedupes
test_sync_repairs_rename_by_id
test_sync_repairs_resurrect_id_by_name
test_sync_keeps_one_profile_per_session
test_sync_preserves_empty_profiles
test_toggle_pins_and_unpins
test_toggle_moves_session_between_profiles
test_profile_views_are_per_session
test_profile_selection_switches_to_member
test_profile_picker_accepts_new_name
test_profile_picker_deletes_profile
test_pin_picker_assigns_and_unpins
test_cycle_uses_canonical_ids
test_cycle_uses_selected_profile
test_jump_uses_pin_slot
test_jump_uses_selected_profile
test_manual_session_switch_updates_profile_and_cycle_scope
test_clear_only_selected_profile
test_replace_last_active_updates_slot

printf 'PASS tmux pinned-session smoke tests\n'
