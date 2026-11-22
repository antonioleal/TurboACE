#!/bin/sh
# Delete what the builds make, so a clean tree is left (everything here is remade by
# make, build.sh or kicad/*/generate.py --check):
#   rom/build  firmware/build  fpga/build  fpga/impl (but the settings it keeps in git)
#   fpga/*.gprj.user  test/gfxtest  test/syms.h  kicad/*/build  __pycache__  release/
#   tools/sjasmplus/build and the sjasmplus binary (build.sh builds the assembler again)
#
#   ./clean.sh                       delete them
#   ./clean.sh -n                    only list what would be deleted
#   ./clean.sh --toolchain           also empty toolchain/, the downloaded tools, which
#                                    ./download_toolchain.sh brings back (a long build),
#                                    but for Gowin EDA (toolchain/gowim), a download by hand
#   ./clean.sh --toolchain --gowin   empty toolchain/ altogether
#
# Never deleted: anything in git; KiCad's per-user and recovery files (kicad/*/.history,
# the local history that can bring back routing; *.kicad_prl; ~*.lck, the project open
# in KiCad); the stock ROM wherever it is; files that are neither in git nor ignored.
#
# Then, to prepare a commit (for GitHub), it reports what git would see: files neither
# in git nor ignored (they would go in with `git add -A`: commit or ignore each), files
# too big for GitHub (over 50 MB it warns, over 100 MB it refuses), a KiCad project
# still open, and what is ready to commit. It exits 1 if any of these needs attention.
set -eu
cd "$(dirname "$0")"

DRY=0
TOOLS=0
GOWIN=0
for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY=1 ;;
        --toolchain) TOOLS=1 ;;
        --gowin) GOWIN=1 ;;
        *) echo "usage: $0 [-n] [--toolchain [--gowin]]" >&2; exit 2 ;;
    esac
done

gone=0
remove() {
    for p in "$@"; do
        [ -e "$p" ] || continue
        if [ $DRY = 1 ]; then echo "would delete $p"; else rm -rf "$p"; echo "deleted $p"; fi
        gone=$((gone + 1))
    done
}

remove rom/build firmware/build fpga/build test/gfxtest test/syms.h release
remove fpga/*.gprj.user
# fpga/impl: Gowin's output; impl/project_process_config.json is the project's settings
for p in fpga/impl/*; do
    [ "$p" = fpga/impl/project_process_config.json ] || remove "$p"
done
remove kicad/*/build
remove tools/sjasmplus/build tools/sjasmplus/sjasmplus
remove $(find . -path ./toolchain/gowim -prune -o -type d -name __pycache__ -print)

if [ $GOWIN = 1 ] && [ $TOOLS = 0 ]; then
    echo "--gowin goes with --toolchain" >&2; exit 2
fi
if [ $TOOLS = 1 ]; then
    for p in toolchain/* toolchain/.[!.]*; do
        [ -e "$p" ] || continue
        if [ "$p" = toolchain/gowim ] && [ $GOWIN = 0 ]; then
            echo "kept $p (Gowin EDA is downloaded by hand: --gowin to delete it too)"
            continue
        fi
        remove "$p"
    done
fi

[ $gone = 0 ] && echo "nothing to delete"

# ---- ready for a commit? -----------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
attention=0
echo
echo "== for the next commit"
untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
    echo "not in git and not ignored (commit them, or add them to .gitignore):"
    echo "$untracked" | sed 's/^/    /'
    attention=1
fi
big=$( { git ls-files; git ls-files --others --exclude-standard; } | sort -u | while IFS= read -r f; do
    if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 52428800 ]; then
        echo "$f ($(($(wc -c < "$f") / 1048576)) MB)"
    fi
done)
if [ -n "$big" ]; then
    echo "over 50 MB (GitHub warns over 50 MB and refuses over 100 MB):"
    echo "$big" | sed 's/^/    /'
    attention=1
fi
locks=$(find kicad -name '~*.lck' 2>/dev/null)
if [ -n "$locks" ]; then
    echo "KiCad has a project open (save and close it before committing):"
    echo "$locks" | sed 's/^/    /'
    attention=1
fi
changed=$(git status --short --untracked-files=no)
if [ -n "$changed" ]; then
    n=$(echo "$changed" | wc -l)
    echo "changes to commit ($n):"
    echo "$changed" | head -20 | sed 's/^/    /'
    [ "$n" -gt 20 ] && echo "    ... and $((n - 20)) more (git status)"
    true
else
    echo "no changes to commit"
fi
[ $attention = 0 ] && echo "clean: ready for a commit"
exit $attention
