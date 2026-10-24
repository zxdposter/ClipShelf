#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d /private/tmp/clipshelf-readme-render.XXXXXX)"
printf 'Screenshot helper directory: %s\n' "$work_dir"
sources=()
for source in "$project_dir"/Sources/ClipShelf/*.swift; do
    [[ "$source" == */ClipShelfApp.swift ]] || sources+=("$source")
done
nice -n 15 swiftc -swift-version 5 -parse-as-library -emit-library -emit-module -module-name ClipboardCore \
    "$project_dir"/Sources/ClipboardCore/*.swift -o "$work_dir/libClipboardCore.dylib" \
    -emit-module-path "$work_dir/ClipboardCore.swiftmodule"
nice -n 15 swiftc -swift-version 5 -I "$work_dir" -L "$work_dir" -lClipboardCore \
    -Xlinker -rpath -Xlinker "$work_dir" "${sources[@]}" \
    "$project_dir/docs/screenshots/main.swift" -o "$work_dir/render"
nice -n 15 "$work_dir/render" "$project_dir/docs/images"
