#!/bin/sh
# Bakes the map's sprite atlases (MapRendering's AtlasBaker, docs/ART.md §10) into the
# directory given, so the app reads them at launch instead of painting them. The App target
# runs it as a build phase (project.yml) with the bundle's Atlases folder.
#
# The bake is kept in build/atlas-bake with a stamp of the engine sources it came from, so a
# build that changed none of them only copies the files. The baker is built and run for this
# Mac, outside Xcode's iOS build environment.
set -eu

out="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
engine="$root/Packages/Engine"
work="$root/build/atlas-bake"
bake="$work/atlases"

stamp=$(cd "$engine" && find Package.swift Sources/GameCore Sources/MapRendering Sources/AtlasBaker -name '*.swift' -type f \
    | LC_ALL=C sort | xargs shasum | shasum | cut -c1-16)

if [ "$(cat "$bake/stamp" 2>/dev/null || true)" != "$stamp" ]; then
    # Only what the Mac toolchain needs: Xcode's SDKROOT, ARCHS and the like target iOS.
    host() {
        if [ -n "${DEVELOPER_DIR:-}" ]; then
            env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" "$@"
        else
            env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$@"
        fi
    }
    host xcrun swift build -c release --package-path "$engine" --scratch-path "$work/build" --product atlas-baker
    bin=$(host xcrun swift build -c release --package-path "$engine" --scratch-path "$work/build" --show-bin-path)
    mkdir -p "$bake"
    printf '' > "$bake/stamp"
    "$bin/atlas-baker" "$bake"
    printf '%s\n' "$stamp" > "$bake/stamp"
fi

mkdir -p "$out"
cp "$bake"/*.atlas "$out/"
