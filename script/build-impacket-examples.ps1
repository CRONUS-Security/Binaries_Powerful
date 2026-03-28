param(
    [Parameter(Mandatory = $true)]
    [string]$PythonVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet('pyinstaller', 'nuitka')]
    [string]$Packager,

    [Parameter(Mandatory = $false)]
    [string]$ImpacketRoot = '.\\impacket',

    [Parameter(Mandatory = $false)]
    [string]$ScriptListFile = '.\\script\\impacket-examples.txt'
,
    [Parameter(Mandatory = $false)]
    [int]$NuitkaJobs = 0
)

$ErrorActionPreference = 'Stop'

if ($NuitkaJobs -le 0) {
    $NuitkaJobs = [Math]::Max(1, [Environment]::ProcessorCount)
}

function Get-TargetScripts {
    param(
        [string]$ImpacketExamplesPath,
        [string]$ListFilePath
    )

    $allScripts = Get-ChildItem -Path $ImpacketExamplesPath -Filter '*.py' -File | Sort-Object Name
    if ($allScripts.Count -eq 0) {
        throw "No Python scripts found under $ImpacketExamplesPath"
    }

    if (-not (Test-Path -Path $ListFilePath)) {
        Write-Host "Script list file not found: $ListFilePath. Fallback to all examples/*.py"
        return $allScripts
    }

    $rawLines = Get-Content -Path $ListFilePath -Encoding UTF8
    $targets = @()

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        $normalized = $trimmed.Replace('/', '\\')
        if ($normalized.StartsWith('examples\\')) {
            $normalized = $normalized.Substring(9)
        }

        $targets += $normalized
    }

    if ($targets.Count -eq 0) {
        Write-Host "Script list file is empty. Fallback to all examples/*.py"
        return $allScripts
    }

    $resolved = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($target in $targets) {
        $candidatePath = Join-Path $ImpacketExamplesPath $target
        if (Test-Path -Path $candidatePath -PathType Leaf) {
            $resolved.Add((Get-Item -Path $candidatePath))
        }
        else {
            $missing.Add($target)
        }
    }

    if ($missing.Count -gt 0) {
        $missingList = $missing -join ', '
        throw "These scripts from list file were not found in impacket/examples: $missingList"
    }

    return $resolved | Sort-Object Name -Unique
}

$examplesPath = Join-Path $ImpacketRoot 'examples'
if (-not (Test-Path -Path $examplesPath -PathType Container)) {
    throw "Impacket examples directory not found: $examplesPath"
}

New-Item -ItemType Directory -Path '.\\artifacts' -Force | Out-Null
New-Item -ItemType Directory -Path '.\\build' -Force | Out-Null

# Pre-warm the Nuitka depends.exe cache to avoid a slow download at the start
# of the first actual build. Nuitka looks for the file at:
#   %LOCALAPPDATA%\Nuitka\Nuitka\Cache\downloads\depends\x86_64\depends.exe
if ($Packager -eq 'nuitka') {
    $dependsCacheDir = Join-Path $env:LOCALAPPDATA 'Nuitka\Nuitka\Cache\downloads\depends\x86_64'
    $dependsExe      = Join-Path $dependsCacheDir 'depends.exe'

    if (-not (Test-Path -Path $dependsExe -PathType Leaf)) {
        Write-Host 'Pre-warming Nuitka depends.exe cache...'
        New-Item -ItemType Directory -Path $dependsCacheDir -Force | Out-Null
        $zipTemp = Join-Path ([System.IO.Path]::GetTempPath()) 'depends22_x64.zip'
        try {
            Invoke-WebRequest -Uri 'https://dependencywalker.com/depends22_x64.zip' `
                              -OutFile $zipTemp -UseBasicParsing
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipTemp)
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'depends.exe' } | Select-Object -First 1
            if ($entry) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dependsExe, $true)
                Write-Host "Nuitka depends.exe cached to: $dependsExe"
            } else {
                Write-Warning 'depends.exe not found in downloaded zip; Nuitka will fall back to its own download.'
            }
            $zip.Dispose()
        } catch {
            Write-Warning "Failed to pre-warm depends.exe cache: $($_.Exception.Message). Nuitka will download it on first use."
        } finally {
            Remove-Item -Path $zipTemp -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Nuitka depends.exe cache already present: $dependsExe"
    }
}

$failedScripts = New-Object System.Collections.Generic.List[string]
$targetScripts = Get-TargetScripts -ImpacketExamplesPath $examplesPath -ListFilePath $ScriptListFile

Write-Host "Target scripts count: $($targetScripts.Count)"
Write-Host 'Target scripts:'
$targetScripts | ForEach-Object { Write-Host " - $($_.Name)" }
Write-Host "Nuitka jobs: $NuitkaJobs"

foreach ($script in $targetScripts) {
    $scriptPath = $script.FullName
    $scriptBaseName = $script.BaseName
    $safeScriptName = $scriptBaseName -replace '[^A-Za-z0-9_]+', '_'
    $outputBaseName = "impacket_${safeScriptName}_${PythonVersion}_${Packager}"
    $outputExeName = "${outputBaseName}.exe"

    Write-Host "::group::Building $($script.Name) -> $outputExeName"

    try {
        if ($Packager -eq 'pyinstaller') {
            python -m PyInstaller `
                --noconfirm `
                --clean `
                --onefile `
                --name $outputBaseName `
                --distpath '.\\artifacts' `
                --workpath '.\\build\\pyinstaller' `
                --specpath '.\\build\\pyinstaller\\spec' `
                $scriptPath

            if ($LASTEXITCODE -ne 0) {
                throw "PyInstaller failed with exit code $LASTEXITCODE"
            }
        }
        elseif ($Packager -eq 'nuitka') {
            python -m nuitka `
                --assume-yes-for-downloads `
                --onefile `
                --jobs=$NuitkaJobs `
                --output-dir='.\\artifacts' `
                --output-filename=$outputExeName `
                $scriptPath

            if ($LASTEXITCODE -ne 0) {
                throw "Nuitka failed with exit code $LASTEXITCODE"
            }
        }

        if (-not (Test-Path -Path ".\\artifacts\\$outputExeName")) {
            throw "Expected output not found: .\\artifacts\\$outputExeName"
        }
    }
    catch {
        Write-Warning "Failed: $($script.Name) - $($_.Exception.Message)"
        $failedScripts.Add($script.Name)
    }
    finally {
        Write-Host '::endgroup::'
    }
}

Write-Host 'Generated files:'
Get-ChildItem -Path '.\\artifacts' -Filter '*.exe' -File | Select-Object -ExpandProperty Name

if ($failedScripts.Count -gt 0) {
    $failedList = $failedScripts -join ', '
    throw "Build failed for scripts: $failedList"
}
