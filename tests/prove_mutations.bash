#!/usr/bin/env bash
# Proves that the checks of tests/test_uninstall_patch.bash can fail: runs the test
# on the unchanged tree, then on one scratch copy of the tree per row of
# tests/mutations.json, and compares the checks that fail with the row.
#
# A row names a file, the text to replace (it must occur exactly once), the new
# text, the checks the change must fail (intended) and the other checks it is
# expected to fail (also). A row counts as a clean kill when the test exits 1,
# every intended check fails, no check fails outside intended and also, and the
# hash of the file that the run read equals the hash of the changed file.
#
# Usage: tests/prove_mutations.bash [ID ...]
#   Without ID every row runs. The unchanged tree runs first and has to pass.
# Needs: bash, git, jq, cmp (diffutils, which a minimal image may lack), awk, and
# the commands base64, cat, comm, cp, cut, date, find, grep, ln, mkdir, mktemp,
# readlink, rm, sed, sha256sum, sort, tail, wc and xargs, plus what the test needs;
# a missing one stops the run before any copy is made. The test also needs the
# upstream clone open62541-src at the pinned tag; without it the unchanged tree
# is Incomplete (exit 2) and the series does not start. Run it from a git work
# tree; the copy takes the tracked files and the untracked files that git does
# not ignore.
# Writes only below work/tmp and work/mutation-run. The results of a run are in
# work/mutation-run/run-<UTC time>-<random suffix>/results.tsv. Each run adds such
# a directory; older ones are not removed.
# KEEP_WORKSPACE=1 keeps the scratch copies; they are also kept when a row is not
# a clean kill.
# Exit status: 0 every row is a clean kill, 1 a row is not, 2 the unchanged tree
# does not pass or the environment is incomplete.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="."
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
    SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
fi
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO
readonly TABLE="${REPO}/tests/mutations.json"
readonly TEST_REL="tests/test_uninstall_patch.bash"
WORK=""
RESULTS=""
RUN_RC=0
ROWS=0
CLEAN=0
NOT_CLEAN=0
COMPLETE=0

function die {
    printf "error: %s\n" "$*" >&2
    exit 2
}

function cleanup {
    local rc="$1"

    [[ -n "${WORK}" ]] || return 0
    if [[ "${rc}" -ne 0 || "${NOT_CLEAN}" -gt 0 || "${KEEP_WORKSPACE:-0}" -eq 1 ]]; then
        printf "Workspace retained: %s\n" "${WORK}"
        return 0
    fi
    [[ "${WORK}" == /* && "${WORK}" != / && -d "${WORK}" && ! -L "${WORK}" ]] || return 1
    [[ "$(readlink -f -- "${WORK}")" == "${WORK}" ]] || return 1
    rm -rf -- "${WORK:?}"
}

function _handle_exit {
    local rc=$?
    local final_rc="${rc}"

    if [[ "${rc}" -eq 0 ]]; then
        if [[ "${COMPLETE}" -ne 1 ]]; then
            final_rc=2
        elif [[ "${NOT_CLEAN}" -gt 0 ]]; then
            final_rc=1
        fi
    fi
    cleanup "${final_rc}" || printf "Cleanup tool error\n" >&2
    printf "\n%d rows, %d clean kills, %d not clean\n" "${ROWS}" "${CLEAN}" "${NOT_CLEAN}"
    if [[ "${final_rc}" -eq 0 ]]; then
        printf "[VERDICT] Passed\n"
    elif [[ "${final_rc}" -eq 1 ]]; then
        printf "[VERDICT] Failed\n"
    else
        printf "[VERDICT] Incomplete\n"
    fi
    exit "${final_rc}"
}

function require_tools {
    local tool
    local missing=0

    for tool in git jq bash awk base64 cat cmp comm cp cut date find grep ln mkdir mktemp readlink rm sed sha256sum sort tail wc xargs; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            printf "error: required command not found: %s\n" "${tool}" >&2
            missing=1
        fi
    done
    if [[ "${missing}" -ne 0 ]]; then
        exit 2
    fi
    [[ -f "${TABLE}" ]] || die "the mutation table ${TABLE} does not exist"
    jq -e '.mutations | length > 0' "${TABLE}" > /dev/null 2>&1 || die "the mutation table ${TABLE} holds no rows"
}

# run_test <tree> <output file>: runs the test of one tree; sets RUN_RC and writes
# its output without color codes to the file
function run_test {
    local rc=0

    bash "$1/${TEST_REL}" > "$2.raw" 2>&1 || rc=$?
    sed 's/\x1b\[[0-9;]*m//g' "$2.raw" > "$2"
    RUN_RC="${rc}"
}

# failing_checks <output file>: the descriptions of the failed checks, sorted
function failing_checks {
    sed -n 's/^\[ FAIL \] //p' "$1" | sort -u
}

# read_hash <tree> <relative file>: the digest that the last run of the tree recorded
function read_hash {
    local dir

    dir="$(find "$1/work/test-evidence" -maxdepth 1 -type d -name 'run-*' 2> /dev/null | sort | tail -1 || true)"
    [[ -n "${dir}" ]] || return 0
    awk -v f="./$2" '$2 == f { print $1 }' "${dir}/files.sha256"
}

# row_field <id> <jq filter on the row> : prints the value
function row_field {
    jq -r --arg id "$1" ".mutations[] | select(.id == \$id) | $2" "${TABLE}"
}

# build_row <id> <row directory>: makes the scratch copy of the tree with the change
# of the row; prints the digest of the changed file, or a reason and returns 1
function build_row {
    local id="$1"
    local dir="$2"
    local file
    local count

    file="$(row_field "${id}" '.file')"
    case "${file}" in
        /* | *..*) printf "the file %s is not a plain relative path" "${file}"; return 1 ;;
    esac
    [[ -f "${WORK}/tree/${file}" && ! -L "${WORK}/tree/${file}" ]] || { printf "the file %s is not a regular file of the tree" "${file}"; return 1; }
    mkdir -p "${dir}"
    row_field "${id}" '.old | @base64' | base64 -d > "${dir}/old.txt"
    row_field "${id}" '.new | @base64' | base64 -d > "${dir}/new.txt"
    count="$(jq -Rs --rawfile old "${dir}/old.txt" 'split($old) | length - 1' "${WORK}/tree/${file}")"
    if [[ "${count}" -ne 1 ]]; then
        printf "the old text occurs %s times in %s" "${count}" "${file}"
        return 1
    fi
    jq -Rsj --rawfile old "${dir}/old.txt" --rawfile new "${dir}/new.txt" \
        'split($old) | .[0] + $new + .[1]' "${WORK}/tree/${file}" > "${dir}/mutated"
    if cmp -s "${dir}/mutated" "${WORK}/tree/${file}"; then
        printf "the changed file equals the original"
        return 1
    fi
    cp -a "${WORK}/tree" "${dir}/src"
    cat "${dir}/mutated" > "${dir}/src/${file}"
    sha256sum < "${dir}/mutated" | cut -d' ' -f1
}

function prove_row {
    local id="$1"
    local dir="${WORK}/rows/${id}"
    local file
    local mutated
    local read
    local missing
    local unexpected
    local clean=1

    ROWS=$((ROWS + 1))
    file="$(row_field "${id}" '.file')"
    if ! mutated="$(build_row "${id}" "${dir}")"; then
        printf "[ NOT CLEAN ] %s the change was not built: %s\n" "${id}" "${mutated}"
        NOT_CLEAN=$((NOT_CLEAN + 1))
        printf "%s\t-\t-\t-\t-\tnot built\n" "${id}" >> "${RESULTS}"
        return 0
    fi
    run_test "${dir}/src" "${dir}/output.txt"
    failing_checks "${dir}/output.txt" > "${dir}/failing.txt"
    row_field "${id}" '.intended[]' | sort -u > "${dir}/intended.txt"
    row_field "${id}" '(.intended + (.also // []))[]' | sort -u > "${dir}/allowed.txt"
    missing="$(comm -23 "${dir}/intended.txt" "${dir}/failing.txt" || true)"
    unexpected="$(comm -13 "${dir}/allowed.txt" "${dir}/failing.txt" || true)"
    read="$(read_hash "${dir}/src" "${file}")"
    if [[ "${RUN_RC}" -ne 1 || -n "${missing}" || -n "${unexpected}" || "${read}" != "${mutated}" ]]; then
        clean=0
    fi
    if [[ "${clean}" -eq 1 ]]; then
        CLEAN=$((CLEAN + 1))
        printf "[ KILL ] %s exit %d, %d checks failed, all intended\n" "${id}" "${RUN_RC}" "$(wc -l < "${dir}/failing.txt")"
    else
        NOT_CLEAN=$((NOT_CLEAN + 1))
        printf "[ NOT CLEAN ] %s exit %d, %d checks failed\n" "${id}" "${RUN_RC}" "$(wc -l < "${dir}/failing.txt")"
        if [[ "${read}" != "${mutated}" ]]; then
            printf "      the run read another file than the changed one: %s, changed %s\n" "${read:-none}" "${mutated}"
        fi
        if [[ -n "${missing}" ]]; then
            printf "      intended but did not fail: %s\n" "${missing//$'\n'/; }"
        fi
        if [[ -n "${unexpected}" ]]; then
            printf "      failed outside the row: %s\n" "${unexpected//$'\n'/; }"
        fi
    fi
    printf "%s\t%d\t%d\t%d\t%d\t%s\n" "${id}" "${RUN_RC}" "$(wc -l < "${dir}/failing.txt")" \
        "$(printf '%s' "${missing}" | grep -c '' || true)" "$(printf '%s' "${unexpected}" | grep -c '' || true)" \
        "$([[ "${clean}" -eq 1 ]] && printf 'kill' || printf 'not clean')" >> "${RESULTS}"
}

function main {
    local id
    local -a ids=()

    trap _handle_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_tools
    if [[ $# -gt 0 ]]; then
        ids=("$@")
    else
        mapfile -t ids < <(jq -r '.mutations[].id' "${TABLE}")
    fi
    for id in "${ids[@]}"; do
        if [[ -z "$(row_field "${id}" '.id')" ]]; then
            die "unknown row ${id}"
        fi
    done
    if [[ "$(git -C "${REPO}" ls-files | wc -l)" -eq 0 ]]; then
        die "git ls-files lists no tracked file below ${REPO}; run it from a git work tree"
    fi
    mkdir -p "${REPO}/work/tmp" "${REPO}/work/mutation-run"
    WORK="$(mktemp -d "${REPO}/work/tmp/prove-mutations.XXXXXX")" || exit 2
    RESULTS="$(mktemp -d "${REPO}/work/mutation-run/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")/results.tsv"
    printf "id\texit\tfailed\tmissing\tunexpected\tresult\n" > "${RESULTS}"
    mkdir -p "${WORK}/tree" "${WORK}/rows"
    (cd "${REPO}" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "${WORK}/tree") || die "the tree could not be copied"
    git -C "${WORK}/tree" init -q
    git -C "${WORK}/tree" add -A
    if [[ -d "${REPO}/open62541-src" ]]; then
        ln -s "${REPO}/open62541-src" "${WORK}/tree/open62541-src"
    fi

    run_test "${WORK}/tree" "${WORK}/baseline.txt"
    if [[ "${RUN_RC}" -ne 0 || -n "$(failing_checks "${WORK}/baseline.txt")" ]]; then
        printf "the unchanged tree does not pass (exit %d); the series does not start\n" "${RUN_RC}" >&2
        sed 's/^/    /' "${WORK}/baseline.txt" | tail -20 >&2
        exit 2
    fi
    printf "unchanged tree: passes (exit %d)\n" "${RUN_RC}"

    for id in "${ids[@]}"; do
        prove_row "${id}"
    done
    printf "results: %s\n" "${RESULTS}"
    COMPLETE=1
}

main "$@"
