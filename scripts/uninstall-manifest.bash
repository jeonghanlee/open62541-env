#!/usr/bin/env bash
#
# Remove exactly the files named in the install_manifest.txt of a cmake build
# directory, then remove the parent directories that became empty. The install
# prefix is the CMAKE_INSTALL_PREFIX stored in the CMakeCache.txt of the same
# build directory, the value the installation itself used. Nothing outside the
# prefix is touched, and the prefix itself is never removed. An entry is
# skipped when it lies outside the prefix, contains a parent reference, or
# sits below a symlinked directory inside the prefix.
#
# When a record name is given, the two files <prefix>/cfg/<name>.buildid and
# <prefix>/cfg/<name>.source are removed as well, and the cfg directory is
# removed when it becomes empty. The Makefile passes no record name, so
# make uninstall removes only the manifest files.
#
# Usage: uninstall-manifest.bash <cmake-build-dir> [<record-name>]
#
# A build directory without CMakeCache.txt or without install_manifest.txt
# means nothing is known to be installed by this build tree: a notice is
# printed, nothing is removed, and the exit status is 0.
#
# Only bash 3.2 syntax is used. The script was run under bash 3.2.57; the
# external tools (grep, sort, rmdir) were not run with the macOS versions.

set -euo pipefail

function die {
    printf "%s\n" "error: $*" >&2
    exit 1
}

function remove_empty_parents {
    local dir="$1"
    local prefix="$2"

    while [[ "${dir}" == "${prefix}"/* ]]; do
        rmdir "${dir}" 2>/dev/null || break
        dir="${dir%/*}"
    done
}

# Succeeds when a directory between the entry and the prefix is a symlink.
function below_symlinked_dir {
    local dir="${1%/*}"
    local prefix="$2"

    while [[ "${dir}" == "${prefix}"/* ]]; do
        if [[ -L "${dir}" ]]; then
            return 0
        fi
        dir="${dir%/*}"
    done
    return 1
}

# Prints one skipped entry to stderr; only the first few are shown so that a
# manifest written for another prefix does not flood the terminal.
function report_skip {
    local count="$1"
    local reason="$2"
    local path="$3"

    if [[ "${count}" -le 5 ]]; then
        printf "%s\n" "skip (${reason}): ${path}" >&2
    fi
}

function main {
    local build="${1:-}"
    local name="${2:-}"
    local cache
    local manifest
    local prefix
    local record
    local ext
    local line
    local dir
    local dirs
    local removed=0
    local skipped=0
    local -a parents=()

    [[ -n "${build}" ]] || die "usage: $0 <cmake-build-dir> [<record-name>]"

    if [[ -n "${name}" && ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "record name may contain only letters, digits, dot, underscore and hyphen: ${name}"
    fi

    cache="${build%/}/CMakeCache.txt"
    manifest="${build%/}/install_manifest.txt"

    if [[ ! -f "${cache}" ]]; then
        printf "%s\n" "notice: ${cache} does not exist; nothing was removed"
        return 0
    fi

    line="$(grep -m1 '^CMAKE_INSTALL_PREFIX:' "${cache}")" || die "CMAKE_INSTALL_PREFIX not found in ${cache}"
    prefix="${line#*=}"
    [[ -n "${prefix}" ]] || die "CMAKE_INSTALL_PREFIX is empty in ${cache}"
    prefix="${prefix%/}"
    [[ -n "${prefix}" ]] || die "install prefix must not be the filesystem root"
    [[ "${prefix}" == /* ]] || die "install prefix must be an absolute path: ${prefix}"

    if [[ ! -f "${manifest}" ]]; then
        printf "%s\n" "notice: ${manifest} does not exist; nothing was removed"
        return 0
    fi

    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line="${line//$'\r'/}"
        [[ -n "${line}" ]] || continue

        # Refuse any entry outside the prefix or containing a parent reference.
        if [[ "${line}" != "${prefix}"/* || "${line}" == *"/../"* ]]; then
            skipped=$((skipped + 1))
            report_skip "${skipped}" "outside prefix" "${line}"
            continue
        fi

        # Refuse an entry that would be reached through a symlinked directory.
        if below_symlinked_dir "${line}" "${prefix}"; then
            skipped=$((skipped + 1))
            report_skip "${skipped}" "below symlinked directory" "${line}"
            continue
        fi

        if [[ -f "${line}" || -L "${line}" ]]; then
            rm -f -- "${line}"
            removed=$((removed + 1))
            parents+=("${line%/*}")
        fi
    done < "${manifest}"

    if [[ -n "${name}" ]]; then
        for ext in buildid source; do
            record="${prefix}/cfg/${name}.${ext}"
            if below_symlinked_dir "${record}" "${prefix}"; then
                skipped=$((skipped + 1))
                report_skip "${skipped}" "below symlinked directory" "${record}"
                continue
            fi
            if [[ -f "${record}" || -L "${record}" ]]; then
                rm -f -- "${record}"
                removed=$((removed + 1))
                parents+=("${record%/*}")
            fi
        done
    fi

    if [[ "${#parents[@]}" -gt 0 ]]; then
        # Unique directories, deepest first, so a parent is empty by the time
        # it is tried.
        dirs="$(printf "%s\n" "${parents[@]}" | LC_ALL=C sort -ru)"

        # An empty __pycache__ directly below a directory that held installed
        # files is a byproduct of the install and is not listed in the manifest.
        while IFS= read -r dir; do
            if [[ -d "${dir}/__pycache__" ]]; then
                rmdir "${dir}/__pycache__" 2>/dev/null || true
            fi
        done <<< "${dirs}"

        while IFS= read -r dir; do
            remove_empty_parents "${dir}" "${prefix}"
        done <<< "${dirs}"
    fi

    printf "%s\n" "Removed ${removed} file(s) from ${prefix}"
    if [[ "${skipped}" -gt 0 ]]; then
        die "entries skipped: ${skipped} (outside the prefix or below a symlinked directory); the prefix read from ${cache} is ${prefix}"
    fi
}

main "$@"
