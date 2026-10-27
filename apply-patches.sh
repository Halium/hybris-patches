#!/bin/bash
#
# Apply the hybris patches to an Android source tree, then verify that every
# patch really is applied.
#
# The verification exists because this script used to fail silently as far as
# the caller was concerned. It ran under "set -e", so the first patch that
# would not apply aborted the whole run - and since projects are processed in
# sorted order, everything alphabetically after that point was never attempted.
# The build then carried on and produced an image that looked fine.
#
# That is not hypothetical. A Halium 11 tree had system/core synced forward to
# android-security-11.0.0_r76 twelve days before a GSI build. Its 17 patches no
# longer applied, the run stopped there, and system/core,
# system/hwservicemanager, system/libhwbinder and system/vold - the four
# projects sorting after it - were left unpatched. The GSI shipped with a stock
# AOSP init, which aborted on every boot inside the LXC container:
#
#     init: mount("proc", ...) failed Device or resource busy
#     init: mount("selinuxfs", ...) failed No such file or directory
#     init: Could not bind mount /first_stage_ramdisk to itself
#     init: InitFatalReboot: signal 6
#
# Each of those has a patch here that had not been applied.
#
# So: do not stop at the first failure, report all of them, and check the tree
# at the end rather than trusting the exit status of the last command.

MB=$1

USE_PATCH=0
if [ "$MB" != "--mb" ]; then
    USE_PATCH=1
fi

OLD_WD=$(pwd)
cd hybris-patches || exit 1

failed_apply=()
missing=()

if [ "$USE_PATCH" == "1" ]; then
    for patch in $(find . -name '*.patch' | sort); do
        if ! cd "$OLD_WD/$(dirname "$patch")" 2>/dev/null; then
            failed_apply+=("$patch (no such directory)")
            continue
        fi
        patch -p1 < "$OLD_WD/hybris-patches/$patch" || failed_apply+=("$patch")
    done
else
    MBS=$(find . -name '*.patch' -exec dirname {} \; | sort -u)
    for mb in $MBS; do
        if ! cd "$OLD_WD/$mb" 2>/dev/null; then
            failed_apply+=("$mb (no such directory)")
            continue
        fi
        for patch in "$OLD_WD/hybris-patches/$mb"/*.patch; do
            [ -e "$patch" ] || continue
            if ! git am "$patch"; then
                git am --abort 2>/dev/null
                failed_apply+=("$mb/$(basename "$patch")")
            fi
        done
    done
fi

# Verify. Two independent tests, because either alone gives wrong answers:
#
#   - the patch reverses cleanly, so its changes are in the tree. Content
#     based, works on a non-git checkout, but reports a false positive when a
#     later patch has touched the same lines - two frameworks/av patches are
#     applied yet no longer reverse.
#
#   - a commit with the patch's subject exists. Catches the above, but only
#     works for a git tree patched with git am, and would be fooled by a
#     project that was patched and later reset.
#
# A patch counts as applied if either says so.
for mb in $(find "$OLD_WD/hybris-patches" -name '*.patch' -exec dirname {} \; \
            | sed "s|^$OLD_WD/hybris-patches/||" | sort -u); do
    if ! cd "$OLD_WD/$mb" 2>/dev/null; then
        missing+=("$mb (no such directory)")
        continue
    fi
    for patch in "$OLD_WD/hybris-patches/$mb"/*.patch; do
        [ -e "$patch" ] || continue
        # git apply for a git checkout, patch(1) for anything else.
        git apply -R --check "$patch" >/dev/null 2>&1 && continue
        patch -p1 -R --dry-run -f -s -i "$patch" >/dev/null 2>&1 && continue
        # Fall back to the commit subject. git format-patch folds a long
        # subject onto continuation lines starting with a space, so unfold it
        # before comparing or the match silently never happens.
        subject=$(awk '
            /^Subject:/ { sub(/^Subject: (\[[^]]*\] )?/, ""); s=$0; f=1; next }
            f && /^[ \t]/ { sub(/^[ \t]+/, " "); s=s $0; next }
            f { exit }
            END { print s }' "$patch")
        if [ -n "$subject" ] && \
           git log --format=%s 2>/dev/null | grep -qxF "$subject"; then
            continue
        fi
        missing+=("$mb/$(basename "$patch")")
    done
done

cd "$OLD_WD" || exit 1

if [ ${#failed_apply[@]} -ne 0 ]; then
    echo
    echo "Patches that did not apply (${#failed_apply[@]}):"
    printf '    %s\n' "${failed_apply[@]}"
fi

if [ ${#missing[@]} -ne 0 ]; then
    echo
    echo "NOT APPLIED IN THE TREE (${#missing[@]}):"
    printf '    %s\n' "${missing[@]}"
    echo
    echo "Do not build from this tree. The build will succeed and the image"
    echo "will behave as though these patches do not exist."
    exit 1
fi

echo
echo "All hybris patches are applied."
