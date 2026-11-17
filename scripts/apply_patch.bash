#!/usr/bin/env bash
# Copyright (c) 2026 - Jeong Han Lee
# The program is free software: you can redistribute
# it and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 2 of the
# License, or any newer version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
# You should have received a copy of the GNU General Public License along with
# this program. If not, see https://www.gnu.org/licenses/gpl-2.0.txt

# Applies one patch to a source tree after classifying its state, or checks that
# the patch is applied. The classification is the one of revert_patch.bash: the
# patch is tried in both directions with patch --dry-run, and only a state that
# the pair of results confirms is acted on.
#
# Usage: apply_patch.bash [--fuzz=N] apply|check <source> <patch>
#   apply  Already applied: says so and changes nothing (exit 0). Not applied:
#          applies the patch and confirms it by a reverse dry-run (exit 0); when
#          the apply or the confirmation fails the source may already be changed,
#          the tool says so, and exits 1. Any other state, including both
#          directions applying and a partly applied patch: stops before any
#          change (exit 3).
#   check  Succeeds when the patch is applied (exit 0), exits 1 when it is not
#          applied and 3 when the state cannot be classified.
#   --fuzz=N is passed to patch; without it patch keeps its default fuzz.
#
# A patch whose hunk also matches at a second place in the file cannot be
# confirmed as already applied: after the apply both directions succeed, so the
# first apply succeeds and a later apply or check stops. The same holds for a
# patch that creates a new file but names it in its --- line instead of
# /dev/null, as a hand-made diff does: once the file exists both directions
# succeed. A patch made by git diff for an added file uses /dev/null and is
# classified. A patch the tool cannot classify is applied by a direct call.
set -euo pipefail
export LC_ALL=C
unset BASH_ENV ENV POSIXLY_CORRECT PATCH_GET VERSION_CONTROL SIMPLE_BACKUP_SUFFIX

# BEGIN shared error settings (the same text in apply_patch.bash and revert_patch.bash)
# Exit status: 0 done, already so, or skipped; 1 the check found the patch not
# applied, or patch failed while changing the source; 2 usage or input error;
# 3 the state cannot be classified.
readonly EXIT_FAILED=1 EXIT_INPUT=2 EXIT_UNCLEAR=3

# Prints the message on standard error and exits with the given status.
function fail {
    local status="$1" message="$2"
    printf '%s\n' "${message}" >&2
    exit "${status}"
}

# Exits with EXIT_INPUT unless the source is a directory, the patch file is a
# non-empty readable file and the patch program is available; sets patch_command.
function require_input {
    local source="$1" patch="$2"
    [[ -d "${source}" ]] || fail "${EXIT_INPUT}" "Source directory missing: ${source}"
    [[ -s "${patch}" && -r "${patch}" ]] ||
        fail "${EXIT_INPUT}" "Patch file missing, empty or unreadable: ${patch}"
    if ! patch_command=$(command -v patch) || [[ ! -x "${patch_command}" ]]; then
        fail "${EXIT_INPUT}" "Required patch executable unavailable: source=${source} patch=${patch}"
    fi
}
# END shared error settings

declare -a patch_options=(--batch --forward --ignore-whitespace --no-backup-if-mismatch -p0)
declare action source_path patch_file patch_command
declare state="" reverse_output="" forward_output=""
declare reverse_status=0 forward_status=0

function usage {
    fail "${EXIT_INPUT}" "Usage: ${0##*/} [--fuzz=N] apply|check <source> <patch>"
}

# Sets state to applied, unapplied or unclear from the dry-run results of both
# directions; both directions applying, both failing and any other status are unclear.
function classify {
    reverse_status=0
    forward_status=0
    reverse_output=$("${patch_command}" "${patch_options[@]}" --dry-run -R -d "${source_path}" < "${patch_file}" 2>&1) || reverse_status=$?
    forward_output=$("${patch_command}" "${patch_options[@]}" --dry-run -d "${source_path}" < "${patch_file}" 2>&1) || forward_status=$?
    state=unclear
    if [[ ${reverse_status} -eq 0 && ${forward_status} -eq 1 ]]; then
        state=applied
    elif [[ ${forward_status} -eq 0 && ${reverse_status} -eq 1 ]]; then
        state=unapplied
    fi
}

function main {
    local detail
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fuzz=*) patch_options+=("$1"); shift ;;
            --) shift; break ;;
            -*) usage ;;
            *) break ;;
        esac
    done
    [[ $# -eq 3 ]] || usage
    action="$1"
    source_path="$2"
    patch_file="$3"
    [[ "${action}" == apply || "${action}" == check ]] || usage
    require_input "${source_path}" "${patch_file}"

    classify
    detail="source=${source_path} patch=${patch_file}"
    case "${action}" in
        apply)
            case "${state}" in
                applied)
                    printf 'Already applied: %s\n' "${detail}"
                    ;;
                unapplied)
                    printf 'Applying patch: %s\n' "${detail}"
                    "${patch_command}" "${patch_options[@]}" -d "${source_path}" < "${patch_file}" ||
                        fail "${EXIT_FAILED}" "Patch failed while applying; the source may be changed: ${detail}"
                    reverse_status=0
                    "${patch_command}" "${patch_options[@]}" --dry-run -R -d "${source_path}" < "${patch_file}" > /dev/null 2>&1 || reverse_status=$?
                    [[ ${reverse_status} -eq 0 ]] ||
                        fail "${EXIT_FAILED}" "Patch applied but not confirmed by the reverse dry-run: ${detail}"
                    ;;
                *)
                    fail "${EXIT_UNCLEAR}" "Cannot classify apply state: ${detail} (reverse=${reverse_status} forward=${forward_status})
Reverse dry-run:
${reverse_output}
Forward dry-run:
${forward_output}"
                    ;;
            esac
            ;;
        check)
            if [[ "${state}" == unapplied ]]; then
                fail "${EXIT_FAILED}" "Patch not applied: ${detail}"
            elif [[ "${state}" != applied ]]; then
                fail "${EXIT_UNCLEAR}" "Patch state unclear: ${detail} (reverse=${reverse_status} forward=${forward_status})"
            fi
            printf 'Patch verified as applied: %s\n' "${detail}"
            ;;
    esac
}

main "$@"
