#!/usr/bin/env bash
# 1. Verifies the vendor Runtime folders copied into the unified project match
#    their per-vendor sources.
# 2. Compiles the Unity-dependent unified bridge and the real vendor bridges
#    against minimal stubs, in both the Android-player and editor
#    preprocessor configurations.
# 3. Compiles the Unity-independent vendor dispatch and runs its assertions.
# 4. Runs the VendorLoaderGate switch-after-start regression checks.
#
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

dotnet_bin="${DOTNET:-dotnet}"
stub_project="tests/WmrTrackingUnity.StubCompile/WmrTrackingUnity.StubCompile.csproj"
dispatch_project="tests/WmrTrackingUnity.Dispatch.Tests/WmrTrackingUnity.Dispatch.Tests.csproj"
loader_gate_project="tests/WmrTrackingUnity.LoaderGate.Tests/WmrTrackingUnity.LoaderGate.Tests.csproj"

"$package_dir/tool/sync_vendor_unity_runtime.sh" --check
"$dotnet_bin" build "$stub_project" --configuration Release --nologo
"$dotnet_bin" build "$stub_project" --configuration Release --nologo \
  -p:UnityEditorStub=true
"$dotnet_bin" run --configuration Release --project "$dispatch_project"
"$dotnet_bin" run --configuration Release --project "$loader_gate_project"
