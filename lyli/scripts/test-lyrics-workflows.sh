#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/swiftpm.sh build --product lyli
bin_path="$(./scripts/swiftpm.sh build --show-bin-path)"

python3 - "$bin_path" "$PWD" <<'PY'
from pathlib import Path
import platform
import subprocess
import sys

bin_path = Path(sys.argv[1])
root = Path(sys.argv[2])
objects = (bin_path / 'lyli.product/Objects.LinkFileList').read_text().splitlines()
# Replace the SwiftUI app entry point with the workflow test runner.
objects = [p for p in objects if Path(p).name != 'App.swift.o']
runner = bin_path / 'lyli-workflow-selftest'
command = ['swiftc', '-parse-as-library', '-swift-version', '5',
           '-target', platform.machine() + '-apple-macosx14.0',
           '-module-cache-path', str(bin_path / 'ModuleCache'),
           '-I', str(bin_path / 'Modules')]
command += [str(p) for p in sorted((root / 'Tests/LyliWorkflowTests').glob('*.swift'))]
command += objects + ['-o', str(runner)]
subprocess.run(command, check=True)
sys.exit(subprocess.run([str(runner)]).returncode)
PY
