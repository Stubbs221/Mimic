//
//  CacheCleanup.swift
//  MimicCore
//
//  Created by Василий Маслов on 03.10.2026.
import Foundation

/// Fixed cleanup targets; home and checkout paths are positional shell arguments, never shell source.
enum CacheCleanup {
    static func command(action: MimicAction, project: ProjectContext, environment: [String: String], home: String) throws -> CommandSpec {
        guard action.isCleanup, home.hasPrefix("/"), !home.split(separator: "/").contains(".."), URL(fileURLWithPath: home).standardizedFileURL.path != "/" else { throw MimicError.invalidCleanup }
        // Parallelize independent Xcode caches, never individual files in the same tree.
        // Wait for every worker before reporting success or releasing the local queue.
        let derivedData = """
            target="$1/Library/Developer/Xcode/DerivedData"
            printf 'DerivedData: removing build caches…\\n'
            if [ -d "$target" ] && [ ! -L "$target" ]; then
                shopt -s dotglob nullglob
                entries=("$target"/*)
                pids=()
                completed=0
                wait_batch() {
                    failed=0
                    for pid in "${pids[@]}"; do
                        if ! wait "$pid"; then failed=1; fi
                    done
                    [ "$failed" -eq 0 ] || return 1
                    completed=$((completed + ${#pids[@]}))
                    printf 'DerivedData: removed %s/%s cache entries\\n' "$completed" "${#entries[@]}"
                    pids=()
                }
                for entry in "${entries[@]}"; do
                    /bin/rm -rf -- "$entry" &
                    pids+=("$!")
                    if [ "${#pids[@]}" -eq 4 ]; then wait_batch; fi
                done
                if [ "${#pids[@]}" -gt 0 ]; then wait_batch; fi
                /bin/rmdir -- "$target"
            else
                /bin/rm -f -- "$target"
            fi
            printf 'DerivedData: cleanup complete\\n'
            """
        let script: String
        if action == .fullCleanup {
            script = """
                set -e
                /bin/rm -rf -- "$1/Library/org.swift.swiftpm/"
                /bin/rm -rf -- "$1/Library/Caches/org.swift.swiftpm/"
                \(derivedData)
                /bin/rm -rf -- "$1/Library/Developer/Xcode/SourcePackages"
                """
        } else {
            script = """
                set -e
                \(derivedData)
                """
        }
        return CommandSpec(executable: "/bin/bash", arguments: ["-c", script, "mimic-cleanup", home, project.path], directory: project.path, environment: environment)
    }
}
