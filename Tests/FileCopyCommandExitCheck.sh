#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/main.swift" <<'SWIFT'
import AppKit
let arguments = Array(CommandLine.arguments.dropFirst())
let board = arguments[1] == "general" ? NSPasteboard.general : NSPasteboard(name: .init(arguments[1]))
let paths = Array(arguments.dropFirst(2))
if arguments[0] == "copy" {
    try FileCopyCommand.copy(paths, to: board)
} else if arguments[0] == "release" {
    if arguments[1] != "general" { board.releaseGlobally() }
} else {
    let actual = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    guard actual?.map(\.path) == paths else {
        fputs("File references lost after command exit: \(String(describing: actual))\n", stderr)
        exit(1)
    }
}
SWIFT
swiftc "$root/Sources/ClipShelf/FileCopyCommand.swift" "$work/main.swift" -o "$work/check"
touch "$work/中文 file.txt"
mkdir "$work/folder"
board="ClipShelf-fcp-exit-$$"
if [[ "${1:-}" == "--general" ]]; then board="general"; fi
trap '"$work/check" release "$board"; rm -rf "$work"' EXIT
for attempt in {1..30}; do
    "$work/check" copy "$board" "$work/中文 file.txt" "$work/folder" 2> "$work/copy.stderr"
    if [[ -s "$work/copy.stderr" ]]; then cat "$work/copy.stderr" >&2; exit 1; fi
    "$work/check" read "$board" "$work/中文 file.txt" "$work/folder"
done
printf 'File references survived all 30 command exits.\n'
