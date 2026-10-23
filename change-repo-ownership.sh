#!/bin/bash
#
# change-repo-ownership.sh
#
# Normalizes ownership of everything *inside* a directory (recursively) to
# 411:510 and clears the setgid bit (chmod g-s) on every child directory,
# respecting the immutable (chattr +i) flag:
#
#   * mutable object                  -> chown 411:510, permissions preserved
#                                        (directories: also chmod g-s)
#   * immutable object, owner root:root -> left completely untouched
#   * immutable object, other owner    -> chattr -i, chown 411:510 (and chmod
#                                        g-s for directories), chattr +i
#
# The directory passed on the command line is never modified itself -- only
# its contents.
#
# Extended attributes are never touched: the script only calls chown, chmod
# and chattr, none of which read or write user/security/trusted xattrs.
#
# Requires: bash, GNU findutils/coreutils (find -printf, chown -h),
#           e2fsprogs (lsattr/chattr). Must run as root.
#

set -u
set -o pipefail

# ---------------------------------------------------------------- settings ---

TARGET_UID=411
TARGET_GID=510

DRY_RUN=0
VERBOSE=0
QUIET=0
ONE_FS=0
DO_APPEND=0        # also clear/restore the append-only flag (see -a)
CHUNK=500          # how many objects to query per lsattr invocation

PROG=${0##*/}

# ---------------------------------------------------------------- counters ---

n_total=0          # objects examined
n_chowned=0        # mutable objects re-owned
n_flipped=0        # immutable objects unlocked, re-owned, re-locked
n_kept_root=0      # immutable root:root objects deliberately left alone
n_already=0        # already 411:510, nothing to do
n_sgid=0           # directories whose setgid bit was cleared (chmod g-s)
n_noflag=0         # symlinks / fifos / sockets / devices (no inode flags)
n_append_skip=0    # append-only objects skipped because -a was not given
n_errors=0

declare -a UNLOCKED_LEFT_OPEN=()   # objects whose flags could not be restored

# --------------------------------------------------------------- utilities ---

usage() {
    cat <<EOF
Usage: $PROG [options] <directory>

Recursively sets ownership of every object *inside* <directory> to
${TARGET_UID}:${TARGET_GID} and clears the setgid bit (chmod g-s) on every
child directory. The directory itself is not modified.

  mutable                    -> chown, permissions preserved; dirs: chmod g-s
  immutable, owner root:root -> left untouched
  immutable, other owner     -> chattr -i, chown (+ chmod g-s), chattr +i

Options:
  -n            dry run: report what would be done, change nothing
  -o UID:GID    target ownership (numeric, default ${TARGET_UID}:${TARGET_GID})
  -a            also clear and restore the append-only flag (chattr +a), which
                blocks chown just like +i. Without this, an object carrying +a
                is reported and left completely untouched.
  -x            do not descend into other filesystems
  -v            verbose: also log objects that need no change
  -q            quiet: print the summary and errors only
  -h            this help

Exit status: 0 on success, 1 if any object could not be processed.
EOF
}

log()  { (( QUIET )) || printf '%s\n' "$*"; }
vlog() { (( VERBOSE )) && printf '%s\n' "$*"; return 0; }
err()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; n_errors=$(( n_errors + 1 )); }
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# ----------------------------------------------------------- option parsing ---

while getopts ':no:axvqh' opt; do
    case $opt in
        n) DRY_RUN=1 ;;
        o) case $OPTARG in
               [0-9]*:[0-9]*) TARGET_UID=${OPTARG%%:*}; TARGET_GID=${OPTARG##*:} ;;
               *) die "-o expects numeric UID:GID, got '$OPTARG'" ;;
           esac ;;
        a) DO_APPEND=1 ;;
        x) ONE_FS=1 ;;
        v) VERBOSE=1 ;;
        q) QUIET=1 ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG requires an argument" ;;
        *) die "unknown option -$OPTARG (try -h)" ;;
    esac
done
shift $(( OPTIND - 1 ))

(( $# == 1 )) || { usage >&2; exit 2; }

# ------------------------------------------------------------ sanity checks ---

for tool in find chown chmod lsattr chattr xargs readlink; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

(( DRY_RUN )) || [ "$(id -u)" = 0 ] || die "must run as root"

# Canonicalize the target so that every path handed to chattr is absolute.
# chattr has no '--' terminator, so a relative path starting with '-' or '+'
# would be parsed as a flag list.
ROOT=$(readlink -f -- "$1") || die "cannot resolve path: $1"
[ -d "$ROOT" ] || die "not a directory: $1"
[ "$ROOT" = "/" ] && die "refusing to operate on /"
[ -r "$ROOT" ] && [ -x "$ROOT" ] || die "directory not readable: $ROOT"

log "$PROG: target       $ROOT (contents only, the directory itself is left as is)"
log "$PROG: ownership     ${TARGET_UID}:${TARGET_GID}"
(( ONE_FS ))  && log "$PROG: scope         single filesystem"
(( DRY_RUN )) && log "$PROG: mode          DRY RUN - nothing will be changed"
log ""

# --------------------------------------------------------- per-object action ---

# read_flags_single <path>  -- prints the lsattr flag field for one object.
# Used for paths containing a newline, which cannot be matched back reliably in
# batched lsattr output.
read_flags_single() {
    local flags
    flags=$(lsattr -d "$1" 2>/dev/null) || return 1
    printf '%s' "${flags%% *}"
}

# set_owner <type> <mode> <path>  -- chown, then put back any setuid/setgid/
# sticky bit that the kernel strips on chown. Returns non-zero on failure.
#
# -h/--no-dereference is used unconditionally: it is what makes symlinks be
# re-owned themselves instead of their targets, and it is a no-op otherwise.
set_owner() {
    local ty=$1 mode=$2 path=$3 rc=0

    chown -h "${TARGET_UID}:${TARGET_GID}" -- "$path" || rc=1

    # Linux clears S_ISUID/S_ISGID on chown of a non-directory, even for root.
    # Restore the mode only in that case, so that plain objects (and every
    # directory) never see a chmod, which would otherwise rewrite a POSIX ACL
    # mask.
    if [ "$ty" != d ] && [ "${#mode}" -gt 3 ] && [ "${mode:0:1}" != 0 ]; then
        chmod "$mode" -- "$path" || rc=1
    fi
    return $rc
}

# has_sgid <type> <mode>  -- true for a directory whose octal mode (find %m)
# carries the setgid bit, e.g. 2775.
has_sgid() {
    [ "$1" = d ] && [ "${#2}" -gt 3 ] && (( 8#${2:0:1} & 2 ))
}

# apply_changes <type> <mode> <path> <do_chown> <do_sgid>  -- the actual
# modification, shared by the mutable and the unlocked-immutable paths.
# Symbolic g-s is used deliberately: it touches only the setgid bit, so the
# rwx bits (and with them any POSIX ACL mask) are left exactly as they are.
apply_changes() {
    local ty=$1 mode=$2 path=$3 do_chown=$4 do_sgid=$5 rc=0
    (( do_chown )) && { set_owner "$ty" "$mode" "$path" || rc=1; }
    (( do_sgid ))  && { chmod g-s -- "$path" || rc=1; }
    return $rc
}

handle_object() {
    local ty=$1 uid=$2 gid=$3 mode=$4 path=$5 flags=$6

    n_total=$(( n_total + 1 ))

    # The lsattr flag field uses one distinct letter per attribute; 'i' is the
    # immutable bit and 'a' the append-only bit. Both of them make chown(2)
    # return EPERM, even for root.
    local immutable=0 append=0
    case $flags in *i*) immutable=1 ;; esac
    case $flags in *a*) append=1 ;; esac

    # Rule 2: immutable and owned by root:root -> hands off.
    if [ "$immutable" = 1 ] && [ "$uid" = 0 ] && [ "$gid" = 0 ]; then
        n_kept_root=$(( n_kept_root + 1 ))
        vlog "keep     immutable root:root   $path"
        return 0
    fi

    local do_chown=1 do_sgid=0
    [ "$uid" = "$TARGET_UID" ] && [ "$gid" = "$TARGET_GID" ] && do_chown=0
    has_sgid "$ty" "$mode" && do_sgid=1

    (( do_chown )) || n_already=$(( n_already + 1 ))

    # Nothing to do if the ownership is already correct and there is no setgid
    # bit to clear. For immutable objects this also avoids a pointless -i/+i
    # window.
    if ! (( do_chown || do_sgid )); then
        vlog "ok       already ${TARGET_UID}:${TARGET_GID}         $path"
        return 0
    fi

    # Human-readable list of what is about to happen, for the log lines.
    local what=''
    (( do_chown )) && what="chown ${uid}:${gid} -> ${TARGET_UID}:${TARGET_GID}"
    (( do_sgid ))  && what="${what:+$what, }chmod g-s"

    # An append-only object cannot be changed unless 'a' is cleared too. Bail
    # out before clearing anything, so that nothing is left half-done.
    if [ "$append" = 1 ] && ! (( DO_APPEND )); then
        n_append_skip=$(( n_append_skip + 1 ))
        err "append-only (+a) blocks chown/chmod, left untouched (use -a to include it): $path"
        return 1
    fi

    # Rule 3: immutable, some other owner -> unlock, change, lock again.
    if [ "$immutable" = 1 ] || [ "$append" = 1 ]; then
        local clear='' restore=''
        [ "$immutable" = 1 ] && { clear+=i; restore+=i; }
        [ "$append"    = 1 ] && { clear+=a; restore+=a; }

        if (( DRY_RUN )); then
            n_flipped=$(( n_flipped + 1 ))
            (( do_sgid )) && n_sgid=$(( n_sgid + 1 ))
            log "would flip  -${clear}, ${what}, +${restore}  $path"
            return 0
        fi

        if ! chattr "-$clear" "$path"; then
            err "cannot clear -$clear, left untouched: $path"
            return 1
        fi

        local rc=0
        apply_changes "$ty" "$mode" "$path" "$do_chown" "$do_sgid" || rc=1

        # Always try to restore the flags, even if the change failed.
        if ! chattr "+$restore" "$path"; then
            UNLOCKED_LEFT_OPEN+=( "+$restore  $path" )
            err "FLAGS +$restore NOT RESTORED: $path"
            rc=1
        fi

        if (( rc )); then
            err "failed to change immutable object: $path"
            return 1
        fi
        n_flipped=$(( n_flipped + 1 ))
        (( do_sgid )) && n_sgid=$(( n_sgid + 1 ))
        log "flipped  ${what}  $path"
        return 0
    fi

    # Rule 1: mutable -> chown (keep permissions) and/or chmod g-s.
    if (( DRY_RUN )); then
        (( do_chown )) && n_chowned=$(( n_chowned + 1 ))
        (( do_sgid ))  && n_sgid=$(( n_sgid + 1 ))
        log "would    ${what}  $path"
        return 0
    fi

    if apply_changes "$ty" "$mode" "$path" "$do_chown" "$do_sgid"; then
        (( do_chown )) && n_chowned=$(( n_chowned + 1 ))
        (( do_sgid ))  && n_sgid=$(( n_sgid + 1 ))
        log "changed  ${what}  $path"
    else
        err "failed to change: $path"
        return 1
    fi
}

# ------------------------------------------------------------ chunk handling ---

declare -a C_TYPE=() C_UID=() C_GID=() C_MODE=() C_PATH=()
declare -A FLAGS=()

flush_chunk() {
    local n=${#C_PATH[@]} i
    (( n == 0 )) && return 0

    FLAGS=()

    # Only regular files and directories can carry inode flags; lsattr fails
    # with ENOTSUP on symlinks, FIFOs, sockets and device nodes.
    local -a batch=()
    for (( i = 0; i < n; i++ )); do
        case ${C_TYPE[i]} in
            f|d)
                case ${C_PATH[i]} in
                    *$'\n'*)   # unmatchable in batched output, ask separately
                        FLAGS[${C_PATH[i]}]=$(read_flags_single "${C_PATH[i]}") ;;
                    *) batch+=( "${C_PATH[i]}" ) ;;
                esac ;;
        esac
    done

    if (( ${#batch[@]} )); then
        # lsattr prints "<flag field> <path>", one object per line.
        local line
        while IFS= read -r line; do
            FLAGS[${line#* }]=${line%% *}
        done < <(printf '%s\0' "${batch[@]}" | xargs -0 -r lsattr -d 2>/dev/null)
    fi

    # An object lsattr could not report on (deleted meanwhile, filesystem
    # without flag support) ends up with an empty flag string and is therefore
    # treated as mutable: the worst case is a chown that fails and is reported,
    # never a chattr -i on something not confirmed to be immutable.
    for (( i = 0; i < n; i++ )); do
        case ${C_TYPE[i]} in
            f|d) : ;;
            *)   n_noflag=$(( n_noflag + 1 )) ;;   # counted, still re-owned
        esac
        handle_object "${C_TYPE[i]}" "${C_UID[i]}" "${C_GID[i]}" "${C_MODE[i]}" \
                      "${C_PATH[i]}" "${FLAGS[${C_PATH[i]}]:-}"
    done

    C_TYPE=(); C_UID=(); C_GID=(); C_MODE=(); C_PATH=()
}

# ------------------------------------------------------------------- main ---

# -mindepth 1 is what excludes the directory itself.
# '|' as the field separator is safe because the path is the last field and is
# extracted by stripping exactly four prefixes -- a path may contain '|'.
#
# The listing is taken first, into a temporary file, so that find's exit status
# can be checked and so that the traversal is not interleaved with the changes.
find_args=( "$ROOT" )
(( ONE_FS )) && find_args+=( -xdev )
find_args+=( -mindepth 1 -printf '%y|%U|%G|%m|%p\0' )

LISTING=$(mktemp -t "${PROG}.XXXXXXXX") || die "cannot create a temporary file"
trap 'rm -f -- "$LISTING"' EXIT INT TERM

find "${find_args[@]}" >"$LISTING"
find_rc=$?
(( find_rc == 0 )) || err "find exited with status $find_rc while walking $ROOT"

while IFS= read -r -d '' rec; do
    ty=${rec%%|*};   rest=${rec#*|}
    uid=${rest%%|*}; rest=${rest#*|}
    gid=${rest%%|*}; rest=${rest#*|}
    mode=${rest%%|*}; path=${rest#*|}

    C_TYPE+=( "$ty" ); C_UID+=( "$uid" ); C_GID+=( "$gid" )
    C_MODE+=( "$mode" ); C_PATH+=( "$path" )

    (( ${#C_PATH[@]} >= CHUNK )) && flush_chunk
done <"$LISTING"

flush_chunk

# ---------------------------------------------------------------- summary ---

printf '\n'
printf '%-42s %d\n' 'examined'                              "$n_total"
printf '%-42s %d\n' 'mutable, re-owned'                     "$n_chowned"
printf '%-42s %d\n' 'immutable, unlocked/re-owned/relocked' "$n_flipped"
printf '%-42s %d\n' 'immutable root:root, left untouched'   "$n_kept_root"
printf '%-42s %d\n' "already ${TARGET_UID}:${TARGET_GID}"   "$n_already"
printf '%-42s %d\n' 'directories, setgid cleared (g-s)'     "$n_sgid"
printf '%-42s %d\n' 'no inode-flag support (links, fifos)'  "$n_noflag"
(( n_append_skip )) && \
printf '%-42s %d\n' 'append-only (+a), skipped'             "$n_append_skip"
printf '%-42s %d\n' 'errors'                                "$n_errors"

if (( ${#UNLOCKED_LEFT_OPEN[@]} )); then
    printf '\n!! inode flags could NOT be restored on %d object(s):\n' \
           "${#UNLOCKED_LEFT_OPEN[@]}"
    printf '   chattr %s\n' "${UNLOCKED_LEFT_OPEN[@]}"
    printf '   re-apply the above manually.\n'
fi

(( n_errors == 0 )) || exit 1
exit 0
