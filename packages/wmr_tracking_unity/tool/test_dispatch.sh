#!/usr/bin/env bash
# 1. Compiles the Unity-dependent unified bridge against minimal stubs, in both
#    the Android-player and editor preprocessor configurations.
# 2. Compiles the Unity-independent vendor dispatch and runs its assertions.
#
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

dotnet_bin="${DOTNET:-dotnet}"
stub_project="tests/WmrTrackingUnity.StubCompile/WmrTrackingUnity.StubCompile.csproj"
dispatch_project="tests/WmrTrackingUnity.Dispatch.Tests/WmrTrackingUnity.Dispatch.Tests.csproj"

"$dotnet_bin" build "$stub_project" --configuration Release --nologo
"$dotnet_bin" build "$stub_project" --configuration Release --nologo \
  -p:UnityEditorStub=true
"$dotnet_bin" run --configuration Release --project "$dispatch_project"
