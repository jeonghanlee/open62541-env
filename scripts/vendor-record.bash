#!/usr/bin/env bash
#
# Write the vendor record of this repository's installation: the file
# <prefix>/cfg/<name>/build-record and its digest file build-record.sha256.
#
# build-record holds key=value lines in this order: format, name, version, tag,
# source, upstream, patch, arch, then for each installed shared object
# artifact=<path> <sha256> directly followed by buildid=<path> <hex|none>, sorted
# by path, with the path relative to the prefix. The prefix is the
# CMAKE_INSTALL_PREFIX stored in the CMakeCache.txt of the cmake build directory.
# The shared objects are taken from the install_manifest.txt of the same build
# directory, so files that other packages installed into the same prefix are never
# listed. Symbolic links are not listed.
#
#   tag      the highest tag by version order on HEAD of this repository, untagged
#            when HEAD has none, unknown when git cannot tell
#   source   the commit of HEAD, followed by +dirty when a tracked file differs from
#            HEAD; untracked and ignored files do not count; unknown when git cannot tell
#   upstream the pinned upstream reference without the leading tags/
#   patch    one line naming the patch file when it is applied to the source clone;
#            no line when it is not applied or the patch file does not exist; the
#            line patch=unknown when the state cannot be classified
#   arch     linux- and the machine name
#
# Both files are written through a temporary file in the same directory and renamed,
# with the mode the umask gives; cfg and cfg/<name> are created only when absent; the
# digest file is written after the record and holds the sha256 of build-record.
# A cfg directory or a record directory that is a symlink is never followed: the
# script stops with an error, as the uninstall script refuses to remove below one.
# The records need GNU build-ids: on systems other than Linux a notice is printed
# and nothing is written.
#
# Usage: vendor-record.bash write <cmake-build-dir> <top> <source-dir> <name> <version> <src-tag> <patch-file>
#
#   top          the checkout of this repository; tag and source are read from it
#   source-dir   the clone of the upstream source; it is checked for the applied patch
#   name         record name, the library name, for example open62541
#   version      the upstream version, for example 1.3.15
#   src-tag      the pinned upstream reference, for example tags/v1.3.15
#   patch-file   the patch file of the pinned version, relative to top

set -euo pipefail
export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0
unset BASH_ENV ENV POSIXLY_CORRECT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

function die {
    printf "%s\n" "error: $*" >&2
    exit 1
}

function usage {
    printf "%s\n" "Usage: $0 write <cmake-build-dir> <top> <source-dir> <name> <version> <src-tag> <patch-file>" >&2
    exit 2
}

function require_tools {
    local tool
    local missing=0

    for tool in readelf sha256sum uname grep sort mv cat; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            printf "error: required command not found: %s\n" "${tool}" >&2
            missing=1
        fi
    done
    if [[ "${missing}" -ne 0 ]]; then
        printf "%s\n" "readelf belongs to the binutils package" >&2
        exit 1
    fi
}

# Prints the GNU build-id of a file as lower-case hex, or none.
function build_id {
    local file="$1"
    local notes

    notes="$(readelf -n "${file}")" || die "readelf failed: ${file}"
    if [[ "${notes}" =~ Build\ ID:\ ([0-9a-f]+) ]]; then
        printf "%s\n" "${BASH_REMATCH[1]}"
    else
        printf "%s\n" none
    fi
}

# Prints the tag= and source= lines of the checkout of this repository. Any git fact
# that cannot be established reads unknown; only exit status 1 of git diff marks the
# tree as modified.
function source_facts {
    local top="$1"
    local toplevel=""
    local commit=""
    local tag=""
    local marker=""
    local diff_status=0

    if ! command -v git > /dev/null 2>&1; then
        printf "%s\n" "tag=unknown" "source=unknown"
        return 0
    fi
    toplevel="$(git -c "safe.directory=${top}" -C "${top}" rev-parse --show-toplevel 2> /dev/null)" || toplevel=""
    if [[ -z "${toplevel}" || "$(cd "${toplevel}" && pwd -P)" != "${top}" ]]; then
        printf "%s\n" "tag=unknown" "source=unknown"
        return 0
    fi
    commit="$(git -c "safe.directory=${top}" -C "${top}" rev-parse HEAD 2> /dev/null)" || commit=""
    git -c "safe.directory=${top}" -C "${top}" diff --quiet HEAD > /dev/null 2>&1 || diff_status=$?
    case "${diff_status}" in
        0) marker="" ;;
        1) marker="+dirty" ;;
        *) commit="" ;;
    esac
    if [[ -z "${commit}" ]]; then
        printf "%s\n" "tag=unknown" "source=unknown"
        return 0
    fi
    tag="$(git -c "safe.directory=${top}" -C "${top}" tag --points-at HEAD | sort -V | tail -n 1)"
    printf "%s\n" "tag=${tag:-untagged}" "source=${commit}${marker}"
}

# Prints the patch= line when the patch is applied, patch=unknown when its state cannot
# be classified, and nothing when it is not applied or the patch file does not exist.
function patch_line {
    local top="$1"
    local src="$2"
    local patch_file="$3"
    local status=0

    if [[ ! -f "${patch_file}" ]]; then
        return 0
    fi
    bash "${top}/scripts/apply_patch.bash" check "${src}" "${patch_file}" > /dev/null 2>&1 || status=$?
    case "${status}" in
        0) printf "%s\n" "patch=${patch_file##*/}" ;;
        1) ;;
        *) printf "%s\n" "patch=unknown" ;;
    esac
}

# Replaces the destination with standard input through a temporary file in the same
# directory.
function write_atomic {
    local destination="$1"
    local temporary

    temporary="${destination%/*}/.${destination##*/}.tmp.$$"
    if ! cat > "${temporary}"; then
        rm -f -- "${temporary}"
        die "cannot write ${destination}"
    fi
    mv -f -- "${temporary}" "${destination}"
}

function do_write {
    local build="${1%/}"
    local top="$2"
    local src="$3"
    local name="$4"
    local version="$5"
    local src_tag="$6"
    local patch_rel="$7"
    local cache="${build}/CMakeCache.txt"
    local manifest="${build}/install_manifest.txt"
    local prefix
    local line
    local rel
    local id
    local sum
    local cfg
    local dir
    local artifact_lines=""
    local -a rels=()

    if [[ "$(uname -s)" != Linux ]]; then
        printf "%s\n" "notice: vendor record skipped: GNU build-id records apply to Linux only"
        return 0
    fi
    require_tools
    if [[ ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "record name may contain only letters, digits, dot, underscore and hyphen: ${name}"
    fi
    [[ -f "${cache}" ]] || die "${cache} does not exist; run make conf first"
    [[ -f "${manifest}" ]] || die "${manifest} does not exist; run make install first"

    line="$(grep -m1 '^CMAKE_INSTALL_PREFIX:' "${cache}")" || die "CMAKE_INSTALL_PREFIX not found in ${cache}"
    prefix="${line#*=}"
    prefix="${prefix%/}"
    [[ -n "${prefix}" && "${prefix}" == /* ]] || die "invalid install prefix in ${cache}"

    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line="${line//$'\r'/}"
        [[ "${line}" == "${prefix}"/* ]] || continue
        if [[ ! -f "${line}" || -L "${line}" ]]; then
            continue
        fi
        case "${line##*/}" in
            *.so | *.so.*) rels+=("${line#"${prefix}"/}") ;;
            *) ;;
        esac
    done < "${manifest}"
    if [[ "${#rels[@]}" -gt 0 ]]; then
        while IFS= read -r rel; do
            id="$(build_id "${prefix}/${rel}")"
            read -r sum _ < <(sha256sum -- "${prefix}/${rel}")
            artifact_lines+="artifact=${rel} ${sum}"$'\n'"buildid=${rel} ${id}"$'\n'
        done < <(printf "%s\n" "${rels[@]}" | sort -u)
    fi

    cfg="${prefix}/cfg"
    dir="${cfg}/${name}"
    if [[ -L "${cfg}" || -L "${dir}" ]]; then
        die "${cfg} or ${dir} is a symlink; the vendor record is not written through a symlink"
    fi
    mkdir -p "${dir}"
    {
        printf "%s\n" "format=1" "name=${name}" "version=${version}"
        source_facts "${top}"
        printf "%s\n" "upstream=${src_tag#tags/}"
        patch_line "${top}" "${src}" "${top}/${patch_rel}"
        printf "%s\n" "arch=linux-$(uname -m)"
        printf "%s" "${artifact_lines}"
    } | write_atomic "${dir}/build-record"
    read -r sum _ < <(sha256sum -- "${dir}/build-record")
    printf "%s\n" "${sum}" | write_atomic "${dir}/build-record.sha256"
    printf "%s\n" "Vendor record written: ${dir}/build-record and build-record.sha256"
}

function main {
    local top
    local src

    [[ "${1:-}" == write && $# -eq 8 ]] || usage
    top="$(cd "$3" && pwd -P)" || die "directory missing: $3"
    src="$4"
    if [[ -d "${src}" ]]; then
        src="$(cd "${src}" && pwd -P)"
    fi
    do_write "$2" "${top}" "${src}" "$5" "$6" "$7" "$8"
}

main "$@"
