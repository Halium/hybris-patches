#!/bin/bash
set -e

# Find the root of the source tree
# We assume the script is in hybris-patches/ inside the source root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -d "$SCRIPT_DIR/../.repo" ]; then
    ROOT_DIR="$SCRIPT_DIR/.."
elif [ -d "$SCRIPT_DIR/.repo" ]; then
    ROOT_DIR="$SCRIPT_DIR"
else
    if [ -d ".repo" ]; then
        ROOT_DIR="."
    else
        echo "Error: Could not find android source root (.repo directory)."
        exit 1
    fi
fi

PATCHES_ROOT="$SCRIPT_DIR"
export PATCHES_ROOT

echo "Exporting patches to $PATCHES_ROOT..."
cd "$ROOT_DIR"

repo forall -c '
    # Skip Halium repositories
    case "$REPO_PATH" in
        device/*|hybris-patches|vendor/halium/*) exit 0 ;;
    esac

    # Check for new commits relative to the upstream revision (REPO_LREV)
    count=$(git rev-list --count $REPO_LREV..HEAD 2>/dev/null || echo 0)

    if [ "$count" -gt 0 ]; then
        TARGET_DIR="$PATCHES_ROOT/$REPO_PATH"
        TEMP_DIR=$(mktemp -d)

        # Create patches
        git format-patch --no-signature --no-numbered --zero-commit $REPO_LREV -o "$TEMP_DIR" > /dev/null

        # Check against existing patches
        mkdir -p "$TARGET_DIR"

        # Iterate over generated patches
        for patch in "$TEMP_DIR"/*.patch; do
            filename=$(basename "$patch")
            target_file="$TARGET_DIR/$filename"

            if [ -f "$target_file" ]; then
                # Compare content
                if ! cmp -s "$patch" "$target_file"; then
                    echo "Modified: $REPO_PATH/$filename"
                    mv "$patch" "$target_file"
                else
                    # File is identical, no action needed
                    rm "$patch"
                fi
            else
                echo "New: $REPO_PATH/$filename"
                mv "$patch" "$target_file"
            fi
        done

        # Clean up temp dir
        rm -rf "$TEMP_DIR"
    fi
'
