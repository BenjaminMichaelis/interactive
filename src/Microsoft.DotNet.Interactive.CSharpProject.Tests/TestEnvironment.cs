using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace Microsoft.DotNet.Interactive.CSharpProject.Tests;

internal static class TestEnvironment
{
    // The prebuild tests run `dotnet new` / `dotnet build` in directories outside the repo. By default those are
    // under ~/.trydotnet/prebuilds, where no global.json applies, so the newest installed SDK is selected
    // (e.g. 11.0.x on a runner that has it preinstalled) even though the test host itself runs on the SDK pinned by
    // the repo's global.json. That mismatch makes the tests depend on whichever SDKs a machine happens to have.
    //
    // Point the prebuilds root at a test-owned directory that carries a copy of the repo's SDK pin, so every
    // prebuild resolves the same SDK as the test host. Prebuild reads TRYDOTNET_PREBUILDS_PATH in a static
    // constructor, so this has to run before the first use of Prebuild; a module initializer guarantees that.
    [ModuleInitializer]
    internal static void PinPrebuildsToRepositorySdk()
    {
        if (Environment.GetEnvironmentVariable("TRYDOTNET_PREBUILDS_PATH") is not null)
        {
            // An explicit override wins.
            return;
        }

        var repoGlobalJson = FindGlobalJson(AppContext.BaseDirectory);

        if (repoGlobalJson is null)
        {
            return;
        }

        using var document = JsonDocument.Parse(File.ReadAllText(repoGlobalJson));

        if (!document.RootElement.TryGetProperty("sdk", out var sdk))
        {
            return;
        }

        var version = sdk.TryGetProperty("version", out var v) ? v.GetString() : "unpinned";

        // Keyed by SDK version so a stale prebuild created under a different SDK is never reused.
        var prebuildsRoot = Path.Combine(Path.GetTempPath(), "dotnet-interactive-tests", $"prebuilds-{version}");

        Directory.CreateDirectory(prebuildsRoot);

        // Only the "sdk" section: the repo's msbuild-sdks (Arcade) must not apply to the generated projects.
        using var stream = File.Create(Path.Combine(prebuildsRoot, "global.json"));
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("sdk");
            sdk.WriteTo(writer);
            writer.WriteEndObject();
        }

        Environment.SetEnvironmentVariable("TRYDOTNET_PREBUILDS_PATH", prebuildsRoot);
    }

    private static string FindGlobalJson(string startDirectory)
    {
        for (var directory = new DirectoryInfo(startDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "global.json");

            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
