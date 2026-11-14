using System;
using System.Runtime.CompilerServices;

namespace Microsoft.DotNet.Interactive.CSharpProject.Tests;

internal static class TestEnvironment
{
    // `dotnet test` exports MSBuildSDKsPath / MSBuildExtensionsPath for the SDK selected by the repo's
    // global.json (10.0.x), and the test host inherits them. The prebuild tests run `dotnet new` and
    // `dotnet build` in directories outside the repo (~/.trydotnet/prebuilds), where the newest installed SDK
    // is selected (e.g. 11.0.x -> net11.0). If the inherited variables reach those child processes, `dotnet build`
    // loads the pinned SDK's targets for a project targeting the newer TFM and fails with NETSDK1045.
    // Clear them so child processes resolve their SDK from their own working directory.
    [ModuleInitializer]
    internal static void ClearInheritedSdkResolutionVariables()
    {
        Environment.SetEnvironmentVariable("MSBuildSDKsPath", null);
        Environment.SetEnvironmentVariable("MSBuildExtensionsPath", null);
    }
}
