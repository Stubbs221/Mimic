#!/usr/bin/env python3
# Created by Василий Маслов on 01.10.2026.
"""Exercise only CLI error propagation using disposable roots and substituted tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(os.environ.get("MIMIC_CHECKOUT", "/private/tmp/MimicExample"))
checks = []

def check(name, condition):
    checks.append((name, bool(condition)))
    print(("PASS " if condition else "FAIL ") + name)

def executable(path, content):
    path.write_text(content)
    path.chmod(0o700)

with tempfile.TemporaryDirectory(prefix="MimicCLI-") as temporary:
    root = Path(temporary)
    # Literal shell metacharacters must remain a path, never executable text.
    formatter_root = root / "Project ' $(touch NEVER)"
    tools = root / "bin"
    tools.mkdir()
    buildtools = formatter_root / "BuildTools"
    buildtools.mkdir(parents=True)
    source = buildtools / "run_swiftformat.swift"
    shutil.copyfile(REPO / "BuildTools/run_swiftformat.swift", source)
    binary = buildtools / "run_swiftformat"
    compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], capture_output=True, text=True)
    check("formatter compiles", compiled.returncode == 0)
    if compiled.returncode:
        print(compiled.stderr)
        raise SystemExit(1)
    executable(tools / "git", '#!/usr/bin/python3\nimport os,sys\nsys.stdout.buffer.write(b"File With Space.swift\\0")\nsys.exit(int(os.environ.get("GIT_EXIT","0")))\n')
    executable(tools / "mint", '#!/usr/bin/python3\nimport os,sys,json\nopen(os.environ["ARGS"],"w").write(json.dumps(sys.argv[1:]))\nsys.stderr.write("fake formatter error\\n" if os.environ.get("MINT_EXIT","0") != "0" else "")\nsys.exit(int(os.environ.get("MINT_EXIT","0")))\n')
    env = dict(os.environ, PATH=str(tools) + ":/usr/bin:/bin", ARGS=str(root / "args.json"))
    result = subprocess.run([str(binary), "uncommitted"], env=env, capture_output=True, text=True)
    args = json.loads((root / "args.json").read_text())
    check("space-containing path is one argv", str(formatter_root / "File With Space.swift") in args)
    check("literal path does not execute shell code", not (formatter_root / "NEVER").exists() and not (REPO / "NEVER").exists())
    check("formatter success", result.returncode == 0 and "finished" in result.stdout)
    result = subprocess.run([str(binary), "uncommitted"], env=dict(env, MINT_EXIT="9"), capture_output=True, text=True)
    check("formatter error propagates", result.returncode != 0 and "SwiftFormat finished" not in result.stdout and "fake formatter error" in result.stderr)
    result = subprocess.run([str(binary), "uncommitted"], env=dict(env, GIT_EXIT="8"), capture_output=True, text=True)
    check("git error is not empty successful diff", result.returncode != 0 and "No files to format" not in result.stdout)
    result = subprocess.run([str(binary), "unknown"], env=env, capture_output=True, text=True)
    check("invalid mode is nonzero", result.returncode == 2)

    babylon_root = root / "babylon"
    (babylon_root / "BuildTools").mkdir(parents=True)
    (babylon_root / "CodeGenerateTools/Babylon").mkdir(parents=True)
    shutil.copyfile(REPO / "BuildTools/babylon.sh", babylon_root / "BuildTools/babylon.sh")
    executable(tools / "swift", '''#!/bin/bash
if [ "${BUILD_EXIT:-0}" != 0 ]; then exit "$BUILD_EXIT"; fi
mkdir -p ".build/$(uname -m)-apple-macosx/debug"
cat > ".build/$(uname -m)-apple-macosx/debug/BabylonGeneratorClient" <<'GEN'
#!/bin/bash
exit "${GEN_EXIT:-0}"
GEN
chmod +x ".build/$(uname -m)-apple-macosx/debug/BabylonGeneratorClient"
''')
    executable(tools / "xcrun", '''#!/bin/bash
if [ "${COMPILE_EXIT:-0}" != 0 ]; then exit "$COMPILE_EXIT"; fi
while [ "$#" -gt 0 ]; do
if [ "$1" = -o ]; then shift; output="$1"; fi
shift
done
cat > "$output" <<'FMT'
#!/bin/bash
exit "${FORMAT_EXIT:-0}"
FMT
chmod +x "$output"
''')
    for name, key in [("build", "BUILD_EXIT"), ("generator", "GEN_EXIT"), ("compile", "COMPILE_EXIT"), ("format", "FORMAT_EXIT")]:
        result = subprocess.run(["/bin/bash", "BuildTools/babylon.sh"], cwd=babylon_root, env=dict(env, **{key: "13"}), capture_output=True, text=True)
        check("Babylon " + name + " failure propagates", result.returncode == 13 and "SwiftFormat завершено" not in result.stdout)
    result = subprocess.run(["/bin/bash", "BuildTools/babylon.sh"], cwd=babylon_root, env=env, capture_output=True, text=True)
    check("Babylon success", result.returncode == 0 and "SwiftFormat завершено" in result.stdout)

print(json.dumps({"passed": sum(ok for _, ok in checks), "total": len(checks)}))
raise SystemExit(0 if all(ok for _, ok in checks) else 1)
