#!/usr/bin/env bash
#
# resolve-pinned-deps.sh - verify or fetch the pinned build inputs for the
# RHEL-parity packages (postfix, heirloom-mailx) named in DEPENDENCIES.lock.
#
# See DEPENDENCIES.lock for the pin format and the vendored/remote modes.

set -euo pipefail

PROG="resolve-pinned-deps.sh"
VERSION="0.1.0"
LOCKFILE="DEPENDENCIES.lock"
VERBOSE=0
TERSE=0
DEBUG=0
DRY_RUN=1
DIRECTORY="."
declare -a WANT_PACKAGES=()

usage() {
	cat <<'EOF'
Usage:
  resolve-pinned-deps.sh [options] [PACKAGE...]
  resolve-pinned-deps.sh -h | --help
  resolve-pinned-deps.sh --version

Verify (or, once a package is in 'remote' mode, fetch) the pinned build
inputs named in DEPENDENCIES.lock. With no PACKAGE arguments, resolves
every package in the lock file.

Options:
  -h, --help            Show this help and exit.
  --version             Show version and exit.
  -v, --verbose         More detail; repeatable (-vv).
  -t, --terse           Minimal, machine-friendly output.
  -d, --debug           Debug/trace output; implies --verbose.
  -n, --dry-run         Print what a remote fetch would do; change nothing
                         (default).
  --no-dry-run          Actually perform a remote fetch.
  -C, --directory DIR   Run as if started in DIR. [default: .]
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--version) echo "${PROG} ${VERSION}"; exit 0 ;;
	-v|--verbose) VERBOSE=$((VERBOSE + 1)); shift ;;
	-t|--terse) TERSE=1; shift ;;
	-d|--debug) DEBUG=1; VERBOSE=$((VERBOSE + 1)); shift ;;
	-n|--dry-run) DRY_RUN=1; shift ;;
	--no-dry-run) DRY_RUN=0; shift ;;
	-C|--directory) DIRECTORY="$2"; shift 2 ;;
	--) shift; break ;;
	-*) echo "${PROG}: unknown option: $1" >&2; exit 2 ;;
	*) WANT_PACKAGES+=("$1"); shift ;;
	esac
done

cd "${DIRECTORY}"

[ -f "${LOCKFILE}" ] || {
	echo "${PROG}: ${LOCKFILE} not found in ${DIRECTORY}" >&2
	exit 1
}

log() { [ "${TERSE}" -eq 1 ] && return 0; echo "$@" >&2; }
debug() { [ "${DEBUG}" -eq 1 ] && echo "+ $*" >&2; return 0; }

get_field() {
	# get_field SECTION KEY
	sed -n "/^\[$1\]/,/^\[/p" "${LOCKFILE}" \
		| grep -e "^$2[[:space:]]*=" \
		| head -n1 \
		| sed -e "s/^$2[[:space:]]*=[[:space:]]*//" \
		      -e 's/[[:space:]]*#.*$//' \
		      -e 's/[[:space:]]*$//'
}

mapfile -t sections < <(grep -e '^\[' "${LOCKFILE}" | tr -d '[]')
if [ "${#WANT_PACKAGES[@]}" -gt 0 ]; then
	sections=("${WANT_PACKAGES[@]}")
fi

status=0
for pkg in "${sections[@]}"; do
	mode=$(get_field "${pkg}" mode)
	debug "package=${pkg} mode=${mode}"

	if [ "${mode}" = "vendored" ]; then
		local_cygport=$(get_field "${pkg}" local_cygport)
		local_packages=$(get_field "${pkg}" local_packages)
		vendored_commit=$(get_field "${pkg}" vendored_commit)

		if [ ! -d "${local_cygport}" ]; then
			echo "${PROG}: ${pkg}: missing ${local_cygport}" >&2
			status=1
			continue
		fi
		if [ ! -d "${local_packages}" ]; then
			echo "${PROG}: ${pkg}: missing ${local_packages}" >&2
			status=1
			continue
		fi

		if [ -d .git ] && command -v git >/dev/null 2>&1; then
			actual_commit=$(git log -1 --format=%H -- "${local_cygport}" 2>/dev/null || true)
			if [ -n "${vendored_commit}" ] && [ "${actual_commit}" != "${vendored_commit}" ]; then
				echo "${PROG}: ${pkg}: DEPENDENCIES.lock is stale (recorded ${vendored_commit}, ${local_cygport} last touched by ${actual_commit})" >&2
				status=1
				continue
			fi
		fi

		if [ "${VERBOSE}" -ge 1 ]; then
			log "${PROG}: ${pkg}: vendored, ok (${local_cygport} @ ${vendored_commit})"
		else
			log "${PROG}: ${pkg}: vendored, ok"
		fi

	elif [ "${mode}" = "remote" ]; then
		remote_repo=$(get_field "${pkg}" remote_repo)
		remote_ref=$(get_field "${pkg}" remote_ref)
		local_cygport=$(get_field "${pkg}" local_cygport)

		if [ -z "${remote_ref}" ]; then
			echo "${PROG}: ${pkg}: mode=remote but remote_ref is empty, refusing" >&2
			status=1
			continue
		fi

		clone_cmd="git clone --depth 1 --branch ${remote_ref} https://github.com/${remote_repo}.git ${local_cygport}"
		if [ "${DRY_RUN}" -eq 1 ]; then
			log "${PROG}: ${pkg}: dry-run, would run: ${clone_cmd}"
		else
			log "${PROG}: ${pkg}: fetching ${remote_repo}@${remote_ref}"
			eval "${clone_cmd}"
		fi

	else
		echo "${PROG}: ${pkg}: unknown mode '${mode}'" >&2
		status=1
	fi
done

exit "${status}"
