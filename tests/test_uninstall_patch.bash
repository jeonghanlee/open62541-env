#!/usr/bin/env bash
# Checks the uninstall, patch and extra-options behavior of this repository by
# running the real scripts and the real make targets in a temporary copy of the
# tracked files.
#
#   uninstall  scripts/uninstall-manifest.bash through make uninstall, on the
#              CMakeCache.txt and install_manifest.txt that cmake itself writes
#              for a small shared-library project installed into a temporary prefix
#   patch      make patch.apply and make patch.revert on the CMakeLists.txt of the
#              pinned upstream clone (open62541-src); reported Incomplete when
#              that clone is absent or not at the pinned tag
#   record     scripts/vendor-record.bash through make install and directly: the
#              build-record and its digest file for the installed shared objects
#   options    make -n conf, conf.rocky8 and conf.static with and without
#              CMAKE_EXTRA_OPTIONS, and the digests recorded in the .source files
#
# Usage: tests/test_uninstall_patch.bash
# Needs: bash (run with 5.2; older versions are not tested), git, make, cmake, a C
# compiler, patch, readelf, and the GNU versions of cp, sed, find, xargs and
# sha256sum (the setup uses cp --parents -t and sed -i). Run it from a git work
# tree: the copy takes the tracked files and the untracked files that git does not
# ignore.
# Runs as a normal user, needs no network, and writes only below work/tmp and
# work/test-evidence.
#
# Evidence: work/test-evidence/run-<UTC time>-<random suffix>/ holds files.sha256
# (the SHA-256 of every file the run used) and result.txt (verdict, counts, status).
# Each run adds such a directory; older ones are not removed.
# KEEP_WORKSPACE=1 keeps the temporary directory; it is also kept when the run
# does not pass.
#
# Proof that the checks can fail: tests/mutations.json lists one change of the
# shipped files per row, with the checks that change must fail (intended) and the
# other checks it is expected to fail (also). tests/prove_mutations.bash runs this
# test on the unchanged tree, then on one scratch copy per row, and compares the
# failing checks with the row. A check that no row names is not proven to fail.
# Exit status: 0 Passed, 1 a check Failed, 2 Incomplete (missing evidence or an
# environment error); a native status of the script itself is kept.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="."
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
    SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
fi
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO
readonly SCRIPT_PATH="${REPO}/tests/test_uninstall_patch.bash"
WORK=""
BUILD=""
EVIDENCE=""
MK_OUT=""
MK_RC=0

declare -g TEST_TOTAL=0
declare -g TEST_PASSED=0
declare -g TEST_FAILED=0
declare -g TEST_COMPLETE=0
declare -g -a FAILED_DETAILS=()
declare -g -a INCOMPLETE_DETAILS=()

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly NC=$'\033[0m'

function mark_incomplete {
    INCOMPLETE_DETAILS+=("$1")
    printf "%b[ INCOMPLETE ]%b %s\n" "${YELLOW}" "${NC}" "$1"
}

# short <text>: one line, at most 48 characters
function short {
    local text="${1//$'\n'/ }"

    printf "%s" "${text:0:48}"
}

# report_pass <description> <value>
function report_pass {
    TEST_TOTAL=$((TEST_TOTAL + 1))
    TEST_PASSED=$((TEST_PASSED + 1))
    printf "%b[ PASS ]%b %-70s = %s\n" "${GREEN}" "${NC}" "$1" "$(short "$2")"
}

# report_fail <description> <expected> <actual>
function report_fail {
    TEST_TOTAL=$((TEST_TOTAL + 1))
    TEST_FAILED=$((TEST_FAILED + 1))
    printf "%b[ FAIL ]%b %s\n" "${RED}" "${NC}" "$1" >&2
    printf "  %bExpected : %s%b\n" "${YELLOW}" "$2" "${NC}" >&2
    printf "  %bActual   : %s%b\n" "${YELLOW}" "$3" "${NC}" >&2
    FAILED_DETAILS+=("$1 (expected: $(short "$2"); actual: $(short "$3"))")
}

# expect_eq <description> <expected> <actual>
function expect_eq {
    if [[ "$2" == "$3" ]]; then
        report_pass "$1" "$3"
    else
        report_fail "$1" "$2" "$3"
    fi
}

# expect_has <description> <text> <needle>
function expect_has {
    if [[ "$2" == *"$3"* ]]; then
        report_pass "$1" "$3"
    else
        report_fail "$1" "text containing: $3" "${2:0:400}"
    fi
}

# expect_path <description> <exists|absent> <path>
function expect_path {
    local state="absent"

    if [[ -e "$3" || -L "$3" ]]; then
        state="exists"
    fi
    expect_eq "$1" "$2" "${state}"
}

# run_make <make arguments>: sets MK_OUT and MK_RC from make in the temporary copy
function run_make {
    MK_RC=0
    MK_OUT="$(make -C "${WORK}/repo" "$@" 2>&1)" || MK_RC=$?
}

# run_script <script arguments>: sets MK_OUT and MK_RC from the uninstall script
function run_script {
    MK_RC=0
    MK_OUT="$(bash "${WORK}/repo/scripts/uninstall-manifest.bash" "$@" 2>&1)" || MK_RC=$?
}

function cleanup {
    local rc="$1"
    local target

    [[ -n "${WORK}" ]] || return 0
    if [[ "${rc}" -ne 0 || "${KEEP_WORKSPACE:-0}" -eq 1 ]]; then
        printf "Workspace retained: %s\n" "${WORK}"
        return 0
    fi
    [[ "${WORK}" == /* && "${WORK}" != / && -d "${WORK}" && ! -L "${WORK}" ]] || return 1
    target="$(readlink -f -- "${WORK}")" || return 1
    [[ "${target}" == "${WORK}" ]] || return 1
    printf "Removing scratch workspace: %s\n" "${target}"
    rm -rf -- "${WORK:?}"
}

function print_divider {
    printf "%s\n" "------------------------------------------------------------"
}

function print_summary {
    local detail

    printf "\n"
    print_divider
    printf "%b%s%b\n" "${BLUE}" "UNINSTALL AND PATCH TEST SUMMARY" "${NC}"
    printf "  %-20s : %d\n" "Total Assertions" "${TEST_TOTAL}"
    printf "  %-20s : %d\n" "Passed" "${TEST_PASSED}"
    printf "  %-20s : %d\n" "Failed" "${TEST_FAILED}"
    printf "  %-20s : %d\n" "Incomplete Reasons" "${#INCOMPLETE_DETAILS[@]}"
    for detail in "${FAILED_DETAILS[@]}"; do
        printf "%b  [FAIL] %s%b\n" "${RED}" "${detail}" "${NC}"
    done
    for detail in "${INCOMPLETE_DETAILS[@]}"; do
        printf "%b  [INCOMPLETE] %s%b\n" "${YELLOW}" "${detail}" "${NC}"
    done
    if [[ "${TEST_FAILED}" -gt 0 ]]; then
        printf "%b[VERDICT] Failed%b\n" "${RED}" "${NC}"
    elif [[ "${#INCOMPLETE_DETAILS[@]}" -gt 0 ]]; then
        printf "%b[VERDICT] Incomplete%b\n" "${YELLOW}" "${NC}"
    else
        printf "%b[VERDICT] Passed%b\n" "${GREEN}" "${NC}"
    fi
    print_divider
}

function write_result {
    local rc="$1"
    local verdict="Passed"

    [[ -n "${EVIDENCE}" && -d "${EVIDENCE}" ]] || return 0
    if [[ "${TEST_FAILED}" -gt 0 ]]; then
        verdict="Failed"
    elif [[ "${#INCOMPLETE_DETAILS[@]}" -gt 0 ]]; then
        verdict="Incomplete"
    fi
    {
        printf "verdict=%s\n" "${verdict}"
        printf "assertions=%d passed=%d failed=%d incomplete_reasons=%d\n" \
            "${TEST_TOTAL}" "${TEST_PASSED}" "${TEST_FAILED}" "${#INCOMPLETE_DETAILS[@]}"
        printf "native_status=%d\n" "${rc}"
        printf "finished_utc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${EVIDENCE}/result.txt"
}

function _handle_exit {
    local rc=$?
    local final_rc=0
    local cleanup_rc=0

    if [[ "${rc}" -ne 0 ]]; then
        printf "Script exited with native status %d\n" "${rc}" >&2
    fi
    if [[ "${TEST_COMPLETE}" -ne 1 ]]; then
        INCOMPLETE_DETAILS+=("Required capture or evaluation did not complete")
    fi
    final_rc="${rc}"
    if [[ "${final_rc}" -eq 0 ]]; then
        if [[ "${TEST_FAILED}" -gt 0 ]]; then
            final_rc=1
        elif [[ "${#INCOMPLETE_DETAILS[@]}" -gt 0 ]]; then
            final_rc=2
        fi
    fi
    write_result "${final_rc}"
    cleanup "${final_rc}" || cleanup_rc=$?
    print_summary
    if [[ "${cleanup_rc}" -ne 0 ]]; then
        printf "Cleanup tool error: status %d\n" "${cleanup_rc}" >&2
        if [[ "${final_rc}" -eq 0 ]]; then
            final_rc="${cleanup_rc}"
        fi
    fi
    exit "${final_rc}"
}

function require_tools {
    local tool
    local missing=0

    for tool in git make cmake patch cc readelf cp date find grep ln mkdir mktemp readlink rm sed sha256sum sort tail tr wc xargs; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            printf "error: required command not found: %s\n" "${tool}" >&2
            missing=1
        fi
    done
    if [[ "${missing}" -ne 0 ]]; then
        exit 2
    fi
}

function setup {
    if [[ "$(git -C "${REPO}" ls-files | wc -l)" -eq 0 ]]; then
        printf "error: git ls-files lists no tracked file below %s; run the test from a git work tree\n" "${REPO}" >&2
        exit 2
    fi
    mkdir -p "${REPO}/work/tmp" "${REPO}/work/test-evidence"
    WORK="$(mktemp -d "${REPO}/work/tmp/test-uninstall-patch.XXXXXX")" || exit 2
    EVIDENCE="$(mktemp -d "${REPO}/work/test-evidence/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || exit 2
    mkdir -p "${WORK}/repo" "${WORK}/tiny/tools"
    (cd "${REPO}" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "${WORK}/repo") || exit 2
    BUILD="${WORK}/repo/open62541-src/build"
    (cd "${WORK}/repo" && find . -type f | LC_ALL=C sort | xargs sha256sum) > "${EVIDENCE}/files.sha256"
    sha256sum "${SCRIPT_PATH}" >> "${EVIDENCE}/files.sha256"

    printf "int tiny(void) { return 1; }\n" > "${WORK}/tiny/tiny.c"
    printf "int tiny(void);\n" > "${WORK}/tiny/tiny.h"
    printf "# module\n" > "${WORK}/tiny/tools/mod.py"
    {
        printf "cmake_minimum_required(VERSION 3.10)\n"
        printf "project(tiny C)\n"
        printf "add_library(tiny SHARED tiny.c)\n"
        printf "set_target_properties(tiny PROPERTIES VERSION 1.0 SOVERSION 1)\n"
        printf "install(TARGETS tiny LIBRARY DESTINATION lib)\n"
        printf "install(FILES tiny.h DESTINATION include)\n"
        printf "install(FILES tools/mod.py DESTINATION share/tiny/tools/nodeset)\n"
    } > "${WORK}/tiny/CMakeLists.txt"
}

# install_tiny <prefix>: configures, builds and installs the small project with
# cmake, then adds the files of another package and the empty directory that an
# install leaves behind
function install_tiny {
    local prefix="$1"

    rm -rf -- "${prefix}"
    mkdir -p "${prefix}"
    cmake -S "${WORK}/tiny" -B "${BUILD}" -DCMAKE_INSTALL_PREFIX="${prefix}" > "${WORK}/cmake.log" 2>&1 || return 1
    cmake --build "${BUILD}" >> "${WORK}/cmake.log" 2>&1 || return 1
    cmake --install "${BUILD}" >> "${WORK}/cmake.log" 2>&1 || return 1
    mkdir -p "${prefix}/cfg" "${prefix}/share/tiny/tools/nodeset/__pycache__"
    printf "other\n" > "${prefix}/lib/libother.so.1"
    printf "other\n" > "${prefix}/cfg/other.buildid"
}

# reinstall <prefix> <what the reinstall is for>
function reinstall {
    if ! install_tiny "$1"; then
        mark_incomplete "the install for the $2 check failed: $(tail -1 "${WORK}/cmake.log")"
        return 1
    fi
}

function listing {
    (cd "$1" && find . | sort | tr '\n' ' ')
}

function test_uninstall {
    local prefix="${WORK}/prefix"
    local expected=". ./cfg ./cfg/other.buildid ./lib ./lib/libother.so.1 "
    local entries
    local elsewhere="${WORK}/elsewhere"
    local outside="${WORK}/outside"
    local linked="${WORK}/linked"
    local bdir

    printf "\n== uninstall\n"
    if ! reinstall "${prefix}" "uninstall"; then
        return 0
    fi
    entries="$(grep -c '' "${BUILD}/install_manifest.txt")"
    expect_has "cmake lists the versioned library and its links in the manifest" \
        "$(tr '\n' ' ' < "${BUILD}/install_manifest.txt")" "libtiny.so.1"

    run_make uninstall
    expect_eq "uninstall exits 0" "0" "${MK_RC}"
    expect_has "uninstall reports every manifest entry removed" "${MK_OUT}" "Removed ${entries} file(s) from ${prefix}"
    expect_eq "only the other package's files and their directories remain" \
        "${expected}" "$(listing "${prefix}")"

    run_make uninstall
    expect_eq "a second uninstall exits 0" "0" "${MK_RC}"
    expect_has "a second uninstall removes nothing" "${MK_OUT}" "Removed 0 file(s)"

    if reinstall "${prefix}" "INSTALL_LOCATION"; then
        mkdir -p "${elsewhere}/lib"
        printf "mine\n" > "${elsewhere}/lib/libmine.so"
        run_make uninstall INSTALL_LOCATION="${elsewhere}"
        expect_eq "uninstall with another INSTALL_LOCATION exits 0" "0" "${MK_RC}"
        expect_path "a file at the INSTALL_LOCATION given to uninstall is kept" exists "${elsewhere}/lib/libmine.so"
        expect_path "the library at the configured prefix is removed" absent "${prefix}/lib/libtiny.so.1.0"
    fi

    run_make uninstall SRC_PATH="${WORK}/no-such-source"
    expect_eq "uninstall without a build directory exits 0" "0" "${MK_RC}"
    expect_has "uninstall without a build directory prints a notice" "${MK_OUT}" "does not exist; nothing was removed"

    bdir="${WORK}/cache-only"
    mkdir -p "${bdir}"
    cp "${BUILD}/CMakeCache.txt" "${bdir}/CMakeCache.txt"
    run_script "${bdir}"
    expect_eq "a cache without a manifest exits 0" "0" "${MK_RC}"
    expect_has "a cache without a manifest prints a notice" "${MK_OUT}" "install_manifest.txt does not exist"

    bdir="${WORK}/empty-prefix"
    mkdir -p "${bdir}"
    sed 's|^CMAKE_INSTALL_PREFIX:PATH=.*|CMAKE_INSTALL_PREFIX:PATH=|' "${BUILD}/CMakeCache.txt" > "${bdir}/CMakeCache.txt"
    run_script "${bdir}"
    expect_eq "an empty install prefix exits 1" "1" "${MK_RC}"
    expect_has "an empty install prefix is named" "${MK_OUT}" "CMAKE_INSTALL_PREFIX is empty"
    bdir="${WORK}/root-prefix"
    mkdir -p "${bdir}"
    sed 's|^CMAKE_INSTALL_PREFIX:PATH=.*|CMAKE_INSTALL_PREFIX:PATH=/|' "${BUILD}/CMakeCache.txt" > "${bdir}/CMakeCache.txt"
    run_script "${bdir}"
    expect_eq "the filesystem root as prefix exits 1" "1" "${MK_RC}"
    expect_has "the filesystem root as prefix is refused" "${MK_OUT}" "must not be the filesystem root"
    run_script
    expect_eq "a call without arguments exits 1" "1" "${MK_RC}"

    if reinstall "${prefix}" "unsafe entries"; then
        mkdir -p "${outside}" "${linked}"
        printf "keep\n" > "${outside}/f"
        printf "keep\n" > "${linked}/g"
        ln -s "${linked}" "${prefix}/lnk"
        printf "\n%s\n%s\n%s\n" "${outside}/f" "${prefix}/lnk/g" "${prefix}/../outside/f" >> "${BUILD}/install_manifest.txt"
        run_make uninstall
        expect_eq "entries outside the prefix or below a symlink make uninstall exit 2" "2" "${MK_RC}"
        expect_has "the skipped entries are counted" "${MK_OUT}" "entries skipped: 3"
        expect_path "a file outside the prefix is kept" exists "${outside}/f"
        expect_path "a file below a symlinked directory is kept" exists "${linked}/g"
        expect_path "the library is still removed" absent "${prefix}/lib/libtiny.so.1.0"
    fi

    if reinstall "${prefix}" "record"; then
        mkdir -p "${prefix}/cfg/open62541"
        printf "r\n" > "${prefix}/cfg/open62541/build-record"
        printf "r\n" > "${prefix}/cfg/open62541/build-record.sha256"
        run_make uninstall
        expect_path "make uninstall removes the record directory of the library" absent "${prefix}/cfg/open62541"
        expect_path "make uninstall keeps another package's file in cfg" exists "${prefix}/cfg/other.buildid"
    fi

    if reinstall "${prefix}" "record name"; then
        mkdir -p "${prefix}/cfg/demo"
        printf "r\n" > "${prefix}/cfg/demo/build-record"
        printf "r\n" > "${prefix}/cfg/demo/build-record.sha256"
        printf "x\n" > "${prefix}/cfg/demo/notes.txt"
        run_script "${BUILD}" demo
        expect_eq "uninstall with a record name exits 0" "0" "${MK_RC}"
        expect_path "the build-record file is removed" absent "${prefix}/cfg/demo/build-record"
        expect_path "the digest file is removed" absent "${prefix}/cfg/demo/build-record.sha256"
        expect_path "a record directory keeps a file that is not a record file" exists "${prefix}/cfg/demo/notes.txt"
        expect_path "cfg stays while another package's file is in it" exists "${prefix}/cfg/other.buildid"
    fi

    if reinstall "${prefix}" "empty cfg"; then
        rm -f -- "${prefix}/cfg/other.buildid"
        mkdir -p "${prefix}/cfg/demo"
        printf "r\n" > "${prefix}/cfg/demo/build-record"
        run_script "${BUILD}" demo
        expect_path "cfg is removed when the record was its only content" absent "${prefix}/cfg"
    fi

    if reinstall "${prefix}" "symlinked cfg"; then
        mkdir -p "${WORK}/realcfg/demo"
        printf "r\n" > "${WORK}/realcfg/demo/build-record"
        rm -rf -- "${prefix}/cfg"
        ln -s "${WORK}/realcfg" "${prefix}/cfg"
        run_script "${BUILD}" demo
        expect_eq "a symlinked cfg makes uninstall exit 1" "1" "${MK_RC}"
        expect_path "a record below a symlinked cfg is kept" exists "${WORK}/realcfg/demo/build-record"
    fi
}

function test_patch {
    local upstream="${REPO}/open62541-src"
    local source="${WORK}/repo/open62541-src"
    local pinned
    local before
    local after

    printf "\n== patch\n"
    pinned="$(sed -n 's/^SRC_TAG:=tags\///p' "${REPO}/configure/RELEASE")"
    if ! git -C "${upstream}" rev-parse --verify --quiet HEAD > /dev/null 2>&1; then
        mark_incomplete "patch checks did not run: no upstream clone at ${upstream}"
        return 0
    fi
    if [[ "$(git -C "${upstream}" describe --tags --exact-match HEAD 2> /dev/null)" != "${pinned}" ]]; then
        mark_incomplete "patch checks did not run: the upstream clone is not at ${pinned}"
        return 0
    fi
    mkdir -p "${source}"
    git -C "${upstream}" show HEAD:CMakeLists.txt > "${source}/CMakeLists.txt"
    sha256sum "${source}/CMakeLists.txt" >> "${EVIDENCE}/files.sha256"

    run_make patch.revert
    expect_eq "revert on a clean source exits 0" "0" "${MK_RC}"
    expect_has "revert on a clean source skips" "${MK_OUT}" "Skipping unapplied patch"

    run_make patch.apply
    expect_eq "apply exits 0" "0" "${MK_RC}"
    expect_eq "apply adds the patched line" "1" "$(grep -c 'NO_SONAME TRUE' "${source}/CMakeLists.txt" || true)"

    run_make patch.apply
    expect_eq "a second apply exits 0" "0" "${MK_RC}"
    expect_has "a second apply says so" "${MK_OUT}" "Already applied"
    expect_eq "a second apply leaves no reject or backup file" "0" \
        "$(find "${source}" -maxdepth 1 \( -name '*.rej' -o -name '*.orig' \) | wc -l)"

    run_make patch.revert
    expect_eq "revert exits 0" "0" "${MK_RC}"
    expect_eq "revert removes the patched line" "0" "$(grep -c 'NO_SONAME TRUE' "${source}/CMakeLists.txt" || true)"
    run_make patch.revert
    expect_eq "a second revert exits 0" "0" "${MK_RC}"
    expect_has "a second revert skips" "${MK_OUT}" "Skipping unapplied patch"
    expect_eq "the source equals the upstream file again" "$(git -C "${upstream}" show HEAD:CMakeLists.txt | sha256sum)" \
        "$(sha256sum < "${source}/CMakeLists.txt")"

    sed -i 's/ALIAS open62541)/ALIAS open62541 )/' "${source}/CMakeLists.txt"
    before="$(sha256sum < "${source}/CMakeLists.txt")"
    run_make patch.apply
    after="$(sha256sum < "${source}/CMakeLists.txt")"
    expect_eq "an unclassifiable state makes apply exit 2" "2" "${MK_RC}"
    expect_has "an unclassifiable state is named" "${MK_OUT}" "Cannot classify apply state"
    expect_eq "an unclassifiable state is left unchanged" "${before}" "${after}"
    git -C "${upstream}" show HEAD:CMakeLists.txt > "${source}/CMakeLists.txt"

    run_make patch.apply SRC_VERSION=9.9.9
    expect_eq "apply without a patch file exits 0" "0" "${MK_RC}"
    expect_has "apply without a patch file prints a notice" "${MK_OUT}" "No patch file for version 9.9.9: nothing to apply"
    run_make patch.revert SRC_VERSION=9.9.9
    expect_has "revert without a patch file prints a notice" "${MK_OUT}" "No patch file for version 9.9.9: nothing to revert"

    run_make patch.apply SRC_PATH="${WORK}/no-such-source"
    expect_eq "apply without a source directory exits 2" "2" "${MK_RC}"
    expect_has "apply without a source directory says so" "${MK_OUT}" "Source directory missing"
}

# run_record <top> <source> <patch file relative to top> [build directory]: sets MK_OUT
# and MK_RC from the vendor record script
function run_record {
    MK_RC=0
    MK_OUT="$(bash "${WORK}/repo/scripts/vendor-record.bash" write "${4:-${BUILD}}" "$1" "$2" open62541 1.3.15 tags/v1.3.15 "$3" 2>&1)" || MK_RC=$?
}

# record_lines <key>: the lines of the record that start with the key
function record_lines {
    grep "^$1=" "${WORK}/prefix/cfg/open62541/build-record" || true
}

function test_record {
    local prefix="${WORK}/prefix"
    local dir="${prefix}/cfg/open62541"
    local lib="${prefix}/lib/libtiny.so.1.0"
    local top="${WORK}/top"
    local src="${WORK}/tinysrc"
    local head
    local sum
    local id
    local old_umask

    printf "\n== record\n"
    if ! reinstall "${prefix}" "record"; then
        return 0
    fi
    old_umask="$(umask)"
    umask 022
    run_make install
    umask "${old_umask}"
    expect_eq "make install exits 0" "0" "${MK_RC}"
    expect_eq "the record files get the mode that the umask gives" "644 644" \
        "$(stat -c '%a' "${dir}/build-record") $(stat -c '%a' "${dir}/build-record.sha256")"
    expect_eq "the digest file holds the sha256 of build-record" "$(sha256sum < "${dir}/build-record" | cut -d' ' -f1)" "$(cat "${dir}/build-record.sha256")"
    expect_eq "the record keys come in the decided order" \
        "format name version tag source upstream patch arch artifact buildid " "$(cut -d= -f1 "${dir}/build-record" | tr '\n' ' ')"
    expect_eq "the upstream line is the pinned reference without tags/" "upstream=v1.3.15" "$(record_lines upstream)"
    expect_eq "tag and source read unknown outside the own git root" "tag=unknown source=unknown" \
        "$(record_lines tag | tr -d '\n') $(record_lines source)"
    sum="$(sha256sum < "${lib}" | cut -d' ' -f1)"
    id="$(readelf -n "${lib}" | sed -n 's/.*Build ID: *//p')"
    id="${id:-none}"
    expect_eq "the record lists the library only, with its sha256 and build-id" \
        "artifact=lib/libtiny.so.1.0 ${sum} buildid=lib/libtiny.so.1.0 ${id}" \
        "$(grep -E '^(artifact|buildid)=' "${dir}/build-record" | tr '\n' ' ' | sed 's/ $//')"
    if [[ -f "${dir}/build-record" ]]; then
        printf "junk=1\n" >> "${dir}/build-record"
    fi
    run_make install
    expect_eq "a second install writes the record completely again" "0" "$(grep -c '^junk=' "${dir}/build-record" || true)"
    expect_eq "no temporary file stays in the record directory" "build-record build-record.sha256 " \
        "$(find "${dir}" -type f | sed 's|.*/||' | sort | tr '\n' ' ')"

    mkdir -p "${top}/scripts" "${top}/patch" "${src}"
    cp "${REPO}/scripts/apply_patch.bash" "${top}/scripts/apply_patch.bash"
    printf -- "--- tiny.h\n+++ tiny.h\n@@ -2,6 +2,7 @@\n l2\n l3\n l4\n+new\n l5\n l6\n l7\n" > "${top}/patch/t.p0.patch"
    printf "tracked\n" > "${top}/tracked.txt"
    printf "l1\nl2\nl3\nl4\nl5\nl6\nl7\n" > "${src}/tiny.h"
    git -C "${top}" init -q
    git -C "${top}" add -A
    git -C "${top}" -c user.name=test -c user.email=test@example.invalid commit -q --no-verify -m init
    head="$(git -C "${top}" rev-parse HEAD)"

    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "a clean tree without a tag reads untagged and the commit" "tag=untagged source=${head}" \
        "$(record_lines tag | tr -d '\n') $(record_lines source)"
    expect_eq "an unapplied patch writes no patch line" "0" "$(record_lines patch | grep -c '' || true)"
    printf "u\n" > "${top}/untracked.txt"
    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "an untracked file does not make the tree dirty" "source=${head}" "$(record_lines source)"
    git -C "${top}" tag 1.3.15-1
    git -C "${top}" tag 1.3.15-2
    git -C "${top}" tag 1.3.15-10
    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "the tag is the highest by version order" "tag=1.3.15-10" "$(record_lines tag)"
    printf "m\n" >> "${top}/tracked.txt"
    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "a changed tracked file adds +dirty to the commit" "source=${head}+dirty" "$(record_lines source)"

    printf "l1\nl2\nl3\nl4\nnew\nl5\nl6\nl7\n" > "${src}/tiny.h"
    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "an applied patch is named in a patch line" "patch=t.p0.patch" "$(record_lines patch)"
    printf "x1\nx2\nx3\nx4\nx5\nx6\nx7\n" > "${src}/tiny.h"
    run_record "${top}" "${src}" patch/t.p0.patch
    expect_eq "a state that cannot be classified reads patch=unknown" "patch=unknown" "$(record_lines patch)"
    run_record "${top}" "${src}" patch/none.p0.patch
    expect_eq "a missing patch file writes no patch line" "0" "$(record_lines patch | grep -c '' || true)"

    if reinstall "${prefix}" "record symlinked cfg"; then
        mkdir -p "${WORK}/linkcfg"
        rm -rf -- "${prefix}/cfg"
        ln -s "${WORK}/linkcfg" "${prefix}/cfg"
        run_record "${top}" "${src}" patch/t.p0.patch
        expect_eq "a symlinked cfg makes the record script exit 1" "1" "${MK_RC}"
        expect_eq "nothing is written below a symlinked cfg" "0" "$(find "${WORK}/linkcfg" -mindepth 1 | wc -l)"
    fi

    mkdir -p "${WORK}/record-cache-only"
    cp "${BUILD}/CMakeCache.txt" "${WORK}/record-cache-only/CMakeCache.txt"
    run_record "${top}" "${src}" patch/t.p0.patch "${WORK}/record-cache-only"
    expect_eq "a build directory without a manifest makes the record script exit 1" "1" "${MK_RC}"
    MK_RC=0
    bash "${WORK}/repo/scripts/vendor-record.bash" > /dev/null 2>&1 || MK_RC=$?
    expect_eq "a call without arguments exits 2" "2" "${MK_RC}"
}

# conf_line <target> [make arguments]: prints the cmake line that make -n shows
function conf_line {
    local target="$1"

    shift
    make -C "${WORK}/repo" -n "${target}" "$@" 2>&1 | grep 'cmake -D' | head -1
}

function test_options {
    local tool
    local declared
    local actual
    local key
    local line

    printf "\n== options and copies\n"
    expect_has "conf without extra options ends in the old command" "$(conf_line conf)" "-DCMAKE_INSTALL_LIBDIR=lib  .."
    expect_has "conf with an extra option" "$(conf_line conf CMAKE_EXTRA_OPTIONS=-DX=1)" "-DCMAKE_INSTALL_LIBDIR=lib -DX=1 .."
    expect_has "conf.rocky8 with an extra option" "$(conf_line conf.rocky8 CMAKE_EXTRA_OPTIONS=-DX=1)" "-DCMAKE_INSTALL_LIBDIR=lib -DX=1 .."
    expect_has "conf.static with an extra option" "$(conf_line conf.static CMAKE_EXTRA_OPTIONS=-DX=1)" "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DX=1 .."
    expect_has "conf.static without extra options" "$(conf_line conf.static)" "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF  .."

    printf "CMAKE_EXTRA_OPTIONS=-DY=2\n" > "${WORK}/repo/configure/CONFIG_SITE.local"
    expect_has "CONFIG_SITE.local sets the extra options" "$(conf_line conf)" "-DCMAKE_INSTALL_LIBDIR=lib -DY=2 .."
    rm -f -- "${WORK}/repo/configure/CONFIG_SITE.local"

    for tool in apply_patch.bash revert_patch.bash; do
        declared="$(sed -n 's/^sha256: *//p' "${REPO}/scripts/${tool}.source")"
        actual="$(sha256sum < "${REPO}/scripts/${tool}")"
        expect_eq "${tool}.source records the digest of the copy" "${actual%% *}" "${declared}"
        for key in Original "Skill commit" sha256 "Copied on"; do
            line="$(grep -c "^${key}:" "${REPO}/scripts/${tool}.source" || true)"
            expect_eq "${tool}.source has the line ${key}" "1" "${line}"
        done
    done
}

function main {
    trap _handle_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_tools
    setup
    test_uninstall
    test_record
    test_patch
    test_options
    TEST_COMPLETE=1
}

main "$@"
