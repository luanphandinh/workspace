#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

if [[ ${WORKSPACE_LINUX_TEST_GUEST:-0} == 1 ]]; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install --yes --no-install-recommends ca-certificates curl git make nix-bin xz-utils
	mkdir -p /etc/nix
	printf '%s\n' 'experimental-features = nix-command flakes' 'sandbox = false' >> /etc/nix/nix.conf
	nix-store --init

	cp -a /source /workspace
	cd /workspace
	make setup-deps
	make setup-runtime
	make nvim-test
	if [[ ${WORKSPACE_LINUX_TEST_PHASE:-all} == all ]]; then
		make update
		make nvim-test
	fi
	exit 0
fi

if [[ $(uname -s) != Darwin ]] || ! command -v container >/dev/null 2>&1; then
	echo "nvim-test-linux requires Apple's container CLI on macOS" >&2
	exit 1
fi

started_system=0
if ! container system status >/dev/null 2>&1; then
	container system start --enable-kernel-install
	started_system=1
fi
cleanup() {
	if [[ $started_system == 1 ]]; then
		container system stop >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

container_args=(
	run --rm
	--arch "${WORKSPACE_LINUX_TEST_ARCH:-amd64}"
	--cpus 4
	--memory 8G
	--env WORKSPACE_LINUX_TEST_GUEST=1
	--env "WORKSPACE_LINUX_TEST_PHASE=${WORKSPACE_LINUX_TEST_PHASE:-all}"
	--mount "type=bind,source=$repo_root,target=/source,readonly"
)
if [[ -n ${WORKSPACE_LINUX_TEST_DNS:-} ]]; then
	container_args+=(--dns "$WORKSPACE_LINUX_TEST_DNS")
fi
container "${container_args[@]}" ubuntu:24.04 /bin/bash /source/scripts/nvim-test-linux-container.sh
