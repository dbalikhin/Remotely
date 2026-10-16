param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$repoName = (($env:SONAR_TARGET_REPOSITORY ?? $env:GITHUB_REPOSITORY) -split '/')[1]
$solution = $env:SONAR_SOLUTION
if ($repoName -eq 'Remotely') {
    # Docker Compose is not a C# project. Include every valid C# project, plus
    # compile the two malformed-TFM projects separately with explicit frameworks.
    $extra = @('Desktop.Core/Desktop.Core.csproj', 'Tests/Desktop.Win.Tests/Desktop.Win.Tests.csproj')
    $paths = @(git ls-files '*.csproj' | Where-Object { $_ -notin $extra })
    $xml = '<Solution>' + (($paths | ForEach-Object { '<Project Path="' + $_ + '" />' }) -join '') + '</Solution>'
    $solution = 'SonarComparison.slnx'
    $xml | Set-Content $solution
    @{ included = $paths; extra_builds = @(
        @{ project = $extra[0]; target_framework_override = 'net8.0' },
        @{ project = $extra[1]; target_framework_override = 'net8.0-windows' }
    ); excluded_non_csharp = @('docker-compose/docker-compose.dcproj') } | ConvertTo-Json -Depth 5 | Set-Content sonar-artifacts/compiled/build-scope.json
}
if ($Restore) {
    dotnet restore $solution
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($repoName -eq 'LANCommander') {
        npm.cmd ci --prefix LANCommander.UI
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        npm.cmd ci --prefix LANCommander.Server
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    exit 0
}
$timer = [Diagnostics.Stopwatch]::StartNew()
$scanExit = 0
$common = @('--no-restore', '--no-incremental', '--disable-build-servers', '--configuration', 'Release', '-m:2', '-p:UseSharedCompilation=false', '-p:LibraryRestore=false', '-p:TypeScriptCompileBlocked=true', '-v:minimal')
dotnet build $solution @common 2>&1 | Tee-Object sonar-artifacts/compiled/build.log
$scanExit = $LASTEXITCODE
$failedProjects = @()
if ($scanExit -ne 0) { $failedProjects += $solution }
if ($repoName -eq 'Remotely' -and $scanExit -eq 0) {
    $extraCommon = @($common | Where-Object { $_ -ne '--no-restore' })
    dotnet build Desktop.Core/Desktop.Core.csproj @extraCommon -p:TargetFramework=net8.0 -p:TargetFrameworks=net8.0 2>&1 | Tee-Object -Append sonar-artifacts/compiled/build.log
    if ($LASTEXITCODE -ne 0) { $failedProjects += 'Desktop.Core/Desktop.Core.csproj'; $scanExit = 1 }
    dotnet build Tests/Desktop.Win.Tests/Desktop.Win.Tests.csproj @extraCommon -p:TargetFramework=net8.0-windows -p:TargetFrameworks=net8.0-windows 2>&1 | Tee-Object -Append sonar-artifacts/compiled/build.log
    if ($LASTEXITCODE -ne 0) { $failedProjects += 'Tests/Desktop.Win.Tests/Desktop.Win.Tests.csproj'; $scanExit = 1 }
}
@{ build_with_analysis_seconds = $timer.Elapsed.TotalSeconds; build_exit_code = $scanExit; failed_projects = $failedProjects } | ConvertTo-Json | Set-Content sonar-artifacts/compiled/timing-build.json
exit $scanExit
