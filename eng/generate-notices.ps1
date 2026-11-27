<#
.SYNOPSIS
    Regenerates NOTICE.txt from the real third-party dependencies of the artifacts this repository ships.

.DESCRIPTION
    Shipped artifacts covered:
      * every NuGet package built from a project with <IsPackable>true</IsPackable> under src/
        (this includes the dotnet-interactive .NET tool, which bundles its whole dependency closure);
      * the npm production dependencies bundled into the Polyglot Notebooks VS Code extensions
        (stable and insiders), the JS embedded in the dotnet-interactive tool, the variable grid,
        and the @microsoft/polyglot-notebooks npm package;
      * third-party source code vendored into this repository (listed in eng/notices/overrides.json).

    NuGet dependencies are enumerated with nuget-license and npm dependencies with
    license-checker-rseidelsohn; both tool versions are pinned below. License and NOTICE texts are
    read from the restored packages. Anything the packages don't state clearly is filled in from
    eng/notices/overrides.json, which records the manual review so it survives regeneration.

    Prerequisites: the .NET SDK from global.json, Node.js/npm, and network access to nuget.org and
    registry.npmjs.org. The script restores the packable projects and runs `npm ci` in any npm
    project that has no node_modules folder yet.

.PARAMETER OutputPath
    Where to write the notices. Defaults to NOTICE.txt at the repository root.

.PARAMETER Check
    Don't write anything. Exit with code 1 if the generated notices differ from the existing file.

.PARAMETER SkipRestore
    Don't run `dotnet restore` or `npm ci`; use what is already restored.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$OutputPath,
    [switch]$Check,
    [switch]$SkipRestore
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$NuGetLicenseVersion = '4.0.19'
$LicenseCheckerPackage = 'license-checker-rseidelsohn@4.4.2'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$noticesDir = Join-Path $PSScriptRoot 'notices'
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'NOTICE.txt' }
$workDir = Join-Path $repoRoot 'artifacts/notices'
New-Item -ItemType Directory -Force $workDir | Out-Null

# npm projects whose production dependencies end up in a shipped artifact.
$npmProjects = @(
    'src/polyglot-notebooks',                 # activation.js in the extension; @microsoft/polyglot-notebooks on npm
    'src/polyglot-notebooks-browser',         # dist/dotnet-interactive.js, embedded in the dotnet-interactive tool
    'src/polyglot-notebooks-ui-components',   # variable-grid.bundle.js in the extension
    'src/polyglot-notebooks-vscode',          # node_modules packed into the stable .vsix
    'src/polyglot-notebooks-vscode-insiders'  # node_modules packed into the insiders .vsix
)

$separator = '---------------------------------------------------------'

function Get-NormalizedText([string]$text) {
    if ($null -eq $text) { return '' }
    $text = $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $text.Split("`n") | ForEach-Object { $_.TrimEnd() }
    return ($lines -join "`n").Trim("`n")
}

function Read-TextFile([string]$path) {
    return Get-NormalizedText ([IO.File]::ReadAllText($path))
}

function Resolve-RepoPath([string]$path) {
    return Join-Path $repoRoot $path
}

function Get-LicenseTemplate([string]$spdx) {
    $file = Join-Path $noticesDir "licenses/$spdx.txt"
    if (-not (Test-Path $file)) { return $null }
    # Drop the placeholder copyright line ("Copyright (c) <year> <owner>") that SPDX templates start with.
    $lines = (Read-TextFile $file).Split("`n")
    $kept = for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -lt 5 -and $lines[$i] -match '<year>') { continue }
        $lines[$i]
    }
    return Get-NormalizedText (($kept -join "`n") -replace "`n{3,}", "`n`n")
}

function Test-IsLicenseFileName([string]$name) {
    return ($name -match '(?i)(licen[cs]e|copying|eula)') -and ($name -notmatch '(?i)\.(rtf|html?|xml|json|ps1|psm1|psd1|dll|nupkg|sha512|p7s)$')
}

function Test-IsNoticeFileName([string]$name) {
    return $name -match '(?i)^(notices?|third-?party-?notices)(\.(txt|md))?$'
}

# ---------------------------------------------------------------------------------------------
# Overrides (manual review)
# ---------------------------------------------------------------------------------------------

$overridesFile = Join-Path $noticesDir 'overrides.json'
$overrides = Get-Content $overridesFile -Raw | ConvertFrom-Json -AsHashtable
$packageOverrides = @{}
foreach ($key in $overrides.packages.Keys) { $packageOverrides[$key.ToLowerInvariant()] = $overrides.packages[$key] }
$excluded = @{}
foreach ($key in $overrides.exclude.Keys) { $excluded[$key.ToLowerInvariant()] = $overrides.exclude[$key] }
$usedOverrides = @{}

function Get-Override([string]$name, [string]$version) {
    foreach ($key in @("$name@$version".ToLowerInvariant(), $name.ToLowerInvariant())) {
        if ($packageOverrides.ContainsKey($key)) {
            $usedOverrides[$key] = $true
            return $packageOverrides[$key]
        }
    }
    return $null
}

function Test-Excluded([string]$name, [string]$version) {
    foreach ($key in @("$name@$version".ToLowerInvariant(), $name.ToLowerInvariant())) {
        if ($excluded.ContainsKey($key)) { $usedOverrides["exclude:$key"] = $true; return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------
# NuGet
# ---------------------------------------------------------------------------------------------

function Get-PackableProjects {
    Get-ChildItem (Join-Path $repoRoot 'src') -Recurse -Include *.csproj, *.fsproj |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|bin|obj)[\\/]' -and $_.Name -notmatch 'Tests?\.' } |
        Where-Object { (Get-Content $_.FullName -Raw) -match '<IsPackable>\s*true\s*</IsPackable>' } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName }
}

function Install-NuGetLicense {
    $toolDir = Join-Path $workDir 'tools'
    $exe = Join-Path $toolDir ($IsWindows ? 'nuget-license.exe' : 'nuget-license')
    if (Test-Path $exe) {
        $installed = (& $exe --version | Select-Object -First 1).Trim()
        if ($installed -eq $NuGetLicenseVersion) { return $exe }
        dotnet tool uninstall nuget-license --tool-path $toolDir | Out-Null
    }
    # The repo NuGet.config maps every package to the dotnet-public feed, which doesn't carry this
    # tool, so install it from nuget.org with a config of its own.
    $config = Join-Path $workDir 'nuget.org.config'
    Set-Content $config '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>'
    dotnet tool install nuget-license --version $NuGetLicenseVersion --tool-path $toolDir --configfile $config | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to install nuget-license $NuGetLicenseVersion" }
    return $exe
}

function Get-NuGetPackagesRoot {
    if ($env:NUGET_PACKAGES) { return $env:NUGET_PACKAGES }
    $line = dotnet nuget locals global-packages --list | Select-Object -First 1
    return ($line -replace '^global-packages:\s*', '').Trim()
}

function Get-NuGetComponents {
    $projects = @(Get-PackableProjects)
    Write-Host "Packable projects: $($projects.Count)"

    # Restore without Arcade so each project.assets.json is in the project's own obj/, where
    # nuget-license looks for it (Arcade moves it under artifacts/obj).
    $env:DisableArcade = '1'
    if (-not $SkipRestore) {
        foreach ($project in $projects) {
            dotnet restore $project --verbosity quiet | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed for $project" }
        }
    }

    $exe = Install-NuGetLicense
    $projectsJson = Join-Path $workDir 'projects.json'
    ConvertTo-Json -InputObject $projects | Set-Content $projectsJson
    $resultJson = Join-Path $workDir 'nuget-license.json'
    # nuget-license exits non-zero when it finds packages without license metadata; those are
    # handled below through the overrides, so only a missing result file is fatal.
    & $exe --json-input $projectsJson --include-transitive --output Json --file-output $resultJson | Out-Null
    if (-not (Test-Path $resultJson)) { throw "nuget-license produced no output (exit code $LASTEXITCODE)" }

    $packagesRoot = Get-NuGetPackagesRoot
    $components = @()
    foreach ($package in (Get-Content $resultJson -Raw | ConvertFrom-Json -AsHashtable)) {
        $id = $package['PackageId']
        $version = $package['PackageVersion']
        if (Test-Excluded $id $version) { continue }

        $dir = Join-Path $packagesRoot "$($id.ToLowerInvariant())/$($version.ToLowerInvariant())"
        if (-not (Test-Path $dir)) { throw "Package folder not found: $dir" }
        $nuspec = [xml](Get-Content (Get-ChildItem $dir -Filter *.nuspec | Select-Object -First 1).FullName -Raw)
        $metadata = $nuspec.package.metadata

        $license = $null
        $licenseFiles = @()
        $licenseNode = $metadata.SelectSingleNode("*[local-name()='license']")
        if ($licenseNode) {
            if ($licenseNode.GetAttribute('type') -eq 'expression') { $license = $licenseNode.InnerText.Trim() }
            elseif ($licenseNode.GetAttribute('type') -eq 'file') { $licenseFiles += Join-Path $dir $licenseNode.InnerText.Trim() }
        }
        $licenseFiles += Get-ChildItem $dir -File | Where-Object { Test-IsLicenseFileName $_.Name } | Sort-Object Name | ForEach-Object { $_.FullName }
        $noticeFiles = @(Get-ChildItem $dir -File | Where-Object { Test-IsNoticeFileName $_.Name } | ForEach-Object { $_.FullName })

        $url = $package['PackageProjectUrl']
        if (-not $url) {
            $repo = $metadata.SelectSingleNode("*[local-name()='repository']")
            if ($repo) { $url = $repo.GetAttribute('url') }
        }

        $components += [ordered]@{
            Name         = $id
            Version      = $version
            License      = $license
            LicenseUrl   = $package['LicenseUrl']
            Url          = $url
            Copyright    = @($package['Copyright'] | Where-Object { $_ })
            LicenseFiles = @($licenseFiles | Select-Object -Unique)
            NoticeFiles  = $noticeFiles
            Source       = 'nuget'
        }
    }
    return $components
}

# ---------------------------------------------------------------------------------------------
# npm
# ---------------------------------------------------------------------------------------------

function Get-NpmComponents {
    $components = @{}
    foreach ($project in $npmProjects) {
        $projectDir = Resolve-RepoPath $project
        if (-not (Test-Path (Join-Path $projectDir 'node_modules'))) {
            if ($SkipRestore) { throw "$project has no node_modules; run 'npm ci' there or drop -SkipRestore" }
            Push-Location $projectDir
            try {
                npm ci --ignore-scripts | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "npm ci failed in $project" }
            }
            finally { Pop-Location }
        }

        $rootName = (Get-Content (Join-Path $projectDir 'package.json') -Raw | ConvertFrom-Json).name
        $output = npx --yes $LicenseCheckerPackage --production --json --start $projectDir
        if ($LASTEXITCODE -ne 0) { throw "license-checker failed in $project" }
        $result = ($output -join "`n") | ConvertFrom-Json -AsHashtable

        foreach ($key in $result.Keys) {
            $info = $result[$key]
            $at = $key.LastIndexOf('@')
            $name = $key.Substring(0, $at)
            $version = $key.Substring($at + 1)
            if ($name -eq $rootName) { continue }
            if (Test-Excluded $name $version) { continue }
            if ($components.ContainsKey($key)) { continue }

            $path = $info['path']
            $files = @(Get-ChildItem $path -File)
            $licenseFiles = @($files | Where-Object { Test-IsLicenseFileName $_.Name } | Sort-Object Name | ForEach-Object { $_.FullName })
            $noticeFiles = @($files | Where-Object { Test-IsNoticeFileName $_.Name } | ForEach-Object { $_.FullName })
            $packageJson = Get-Content (Join-Path $path 'package.json') -Raw | ConvertFrom-Json -AsHashtable
            $url = $packageJson['homepage'] ?? $info['repository']

            $license = $info['licenses']
            if ($license -is [array]) { $license = $license -join ' OR ' }

            $components[$key] = [ordered]@{
                Name         = $name
                Version      = $version
                License      = $license
                LicenseUrl   = $null
                Url          = $url
                Copyright    = @()
                LicenseFiles = $licenseFiles
                NoticeFiles  = $noticeFiles
                Source       = 'npm'
            }
        }
    }
    return $components.Values
}

# ---------------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------------

$problems = [System.Collections.Generic.List[string]]::new()

function Format-Component($component) {
    $name = $component.Name
    $version = $component.Version
    $override = Get-Override $name $version

    $license = $component.License
    $url = $component.Url
    $copyright = @($component.Copyright)
    $licenseFiles = @($component.LicenseFiles)
    $noticeFiles = @($component.NoticeFiles)
    $extraNoticeFiles = @()
    $note = $null

    if ($override) {
        if ($override.ContainsKey('license')) { $license = $override.license }
        if ($override.ContainsKey('url')) { $url = $override.url }
        if ($override.ContainsKey('copyright')) { $copyright = @($override.copyright) }
        if ($override.ContainsKey('licenseFiles')) { $licenseFiles = @($override.licenseFiles | ForEach-Object { Resolve-RepoPath $_ }) }
        if ($override.ContainsKey('noticeFiles')) { $extraNoticeFiles = @($override.noticeFiles | ForEach-Object { Resolve-RepoPath $_ }) }
        if ($override.ContainsKey('note')) { $note = $override.note }
    }

    $licenseText = (@($licenseFiles | ForEach-Object { Read-TextFile $_ } | Where-Object { $_ }) | Select-Object -Unique) -join "`n`n"

    if (-not $license) {
        # Older packages only point at a license URL or file; recognize the common texts.
        if ($licenseText -match 'Permission is hereby granted, free of charge') { $license = 'MIT' }
        elseif ($licenseText -match 'Apache License\s+Version 2\.0') { $license = 'Apache-2.0' }
        else { $problems.Add("$name $version`: no license identified") }
    }

    $copyrightInText = $licenseText -match '(?im)^\W*(copyright|\(c\)|©)'
    if (-not $licenseText -and $license) {
        $licenseText = Get-LicenseTemplate $license
        if (-not $licenseText) { $problems.Add("$name $version`: no license text for '$license'") }
    }
    if (-not $copyrightInText -and $copyright.Count -eq 0 -and $license -notmatch '^(0BSD|Unlicense|CC0-1.0|blessing|MPL-2.0|LGPL-3.0)$') {
        $problems.Add("$name $version`: no copyright notice found")
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("$name $version - $license`n")
    if ($url) { [void]$sb.Append("$url`n") }
    if ($note) { [void]$sb.Append("`n$(Get-NormalizedText $note)`n") }
    if (-not $copyrightInText -and $copyright.Count -gt 0) {
        [void]$sb.Append("`n$((@($copyright | ForEach-Object { Get-NormalizedText $_ }) | Select-Object -Unique) -join "`n")`n")
    }
    if ($licenseText) { [void]$sb.Append("`n$licenseText`n") }
    # Notices files are copied in full for Apache-2.0 components (the license requires passing on the
    # NOTICE file) and for npm packages (they are small and describe code bundled into the package).
    # Other NuGet packages' notices files, typically a THIRD-PARTY-NOTICES.TXT that the vendor generates
    # for its whole build, are named rather than copied.
    $inline = @($extraNoticeFiles)
    if ($license -match 'Apache-2\.0' -or $component.Source -ne 'nuget') { $inline = @($noticeFiles) + $inline }
    else {
        $names = @($noticeFiles | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object -Unique)
        if ($names.Count -gt 0) { [void]$sb.Append("`nThe package also contains notices for software it incorporates: $($names -join ', ').`n") }
    }
    foreach ($noticeText in (@($inline | Select-Object -Unique | ForEach-Object { Read-TextFile $_ }) | Select-Object -Unique)) {
        [void]$sb.Append("`nNOTICE file:`n`n$noticeText`n")
    }
    $component.ResolvedLicense = $license
    return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

$components = @()
$components += Get-NuGetComponents
$components += Get-NpmComponents
foreach ($extra in $overrides.additionalComponents) {
    $components += [ordered]@{
        Name         = $extra.name
        Version      = $extra.version
        License      = $extra.license
        LicenseUrl   = $null
        Url          = $extra.url
        Copyright    = @($extra['copyright'] ?? @())
        LicenseFiles = @($extra.licenseFiles | ForEach-Object { Resolve-RepoPath $_ })
        NoticeFiles  = @(($extra['noticeFiles'] ?? @()) | ForEach-Object { Resolve-RepoPath $_ })
        Source       = 'vendored'
    }
}

$sorted = $components | Sort-Object -Property @{ Expression = { $_.Name.ToLowerInvariant() } }, @{ Expression = { $_.Version } } -CaseSensitive

$builder = [System.Text.StringBuilder]::new()
[void]$builder.Append((Read-TextFile (Join-Path $noticesDir 'header.txt')))
[void]$builder.Append("`n`n$separator`n")
foreach ($component in $sorted) {
    [void]$builder.Append("`n")
    [void]$builder.Append((Format-Component $component))
    [void]$builder.Append("`n$separator`n")
}
$generated = $builder.ToString()

$staleOverrides = @($packageOverrides.Keys | Where-Object { -not $usedOverrides.ContainsKey($_) }) +
                  @($excluded.Keys | Where-Object { -not $usedOverrides.ContainsKey("exclude:$_") })
foreach ($stale in $staleOverrides) { $problems.Add("override for '$stale' matched no dependency; remove it from overrides.json") }

$summary = $sorted | ForEach-Object { $_.ResolvedLicense } | Group-Object | Sort-Object Count, Name -Descending

Write-Host "Components: $($sorted.Count)"
$summary | ForEach-Object { Write-Host ("  {0,4}  {1}" -f $_.Count, $_.Name) }

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host 'These need a manual review entry in eng/notices/overrides.json:' -ForegroundColor Red
    $problems | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

if ($Check) {
    $existing = if (Test-Path $OutputPath) { Read-TextFile $OutputPath } else { '' }
    if ($existing -ne (Get-NormalizedText $generated)) {
        Write-Host "$OutputPath is out of date. Run eng/generate-notices.ps1 and commit the result." -ForegroundColor Red
        exit 1
    }
    Write-Host "$OutputPath is up to date."
    exit 0
}

[IO.File]::WriteAllText($OutputPath, $generated, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath"
