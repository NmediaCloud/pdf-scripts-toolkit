@echo off
rem ============================================================
rem  01_Adjust-Images- BR-CONT-SAT.bat
rem  Self-contained batch image adjuster (no external files)
rem
rem  VERSION HISTORY
rem  v1.0  2026-03-30  Initial release
rem  v1.1  2026-03-30  Fix ColorMatrix inline arithmetic crash
rem                    Add overwrite-in-place option
rem                    Add save / load presets
rem  v1.2  2026-03-30  Fix preset menu stuck in loop (array typing + TryParse)
rem  v1.3  2026-03-30  Individual preset files (preset_01_desc.json)
rem                    Folder path stored in preset + auto-fill on load
rem ============================================================
setlocal
set "BATFILE=%~f0"

rem ── Auto-backup this script to _versions\ ───────────────────
if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PS_BEGIN'){$s=$i+1;break}};iex(($l[$s..($l.Count-1)])-join[char]10)"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Script exited with an error. Press any key to close.
    if not defined PDF_RUN pause >nul
)
exit /b
#PS_BEGIN
# =============================================================================
#  Batch Image Adjuster — BR / CONT / SAT  v1.1
#  Self-contained inside 01_Adjust-Images- BR-CONT-SAT.bat
#  Supports input:  JPG, JPEG, PNG, BMP, GIF, TIF/TIFF
#  Supports output: keep original | JPG (custom quality) | PNG (lossless)
#  Extras:          overwrite in place | save & load presets
# =============================================================================

$VERSION   = "1.4"
$CHANGELOG = @"
v1.0  2026-03-30  Initial release
v1.1  2026-03-30  Fix ColorMatrix crash  |  Overwrite-in-place  |  Presets
v1.2  2026-03-30  Fix preset menu loop (array typing + TryParse)
v1.3  2026-03-30  Individual preset files (preset_01_desc.json)
                  Folder path stored in preset, auto-fills on load
v1.4  2026-06-17  Parallel processing across CPU cores (runspace pool) -
                  identical output, ~Ncores faster. (CRLF line endings.)
v1.5  2026-06-17  Batch mode: each subfolder -> its own adjusted_ folder
"@

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Image helpers
# ---------------------------------------------------------------------------

function Get-ScriptFolder {
    if ($env:BATFILE) { return [System.IO.Path]::GetDirectoryName($env:BATFILE) }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Save-Bitmap {
    param(
        [System.Drawing.Bitmap]$Bmp,
        [string]$OutputPath,
        [string]$OutputFormat,
        [string]$OriginalExt,
        [int]$JpegQuality = 95
    )
    $saveAsJpeg = ($OutputFormat -eq 'jpg') -or
                  ($OutputFormat -eq 'original' -and $OriginalExt -in '.jpg','.jpeg')

    if ($saveAsJpeg) {
        $enc   = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                 Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep    = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
        $Bmp.Save($OutputPath, $enc, $ep)
        $ep.Dispose()
        return
    }
    if ($OutputFormat -eq 'png') { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png); return }

    switch ($OriginalExt) {
        '.png'                    { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)  }
        '.bmp'                    { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)  }
        '.gif'                    { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Gif)  }
        { $_ -in '.tif','.tiff' } { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Tiff) }
        default                   { $Bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)  }
    }
}

function Apply-ColorMatrix {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [System.Drawing.Imaging.ColorMatrix]$ColorMatrix,
        [string]$OutputFormat = 'original',
        [int]$JpegQuality     = 95
    )
    $img = [System.Drawing.Image]::FromFile($InputPath)
    try {
        $bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height,
               [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $ia = New-Object System.Drawing.Imaging.ImageAttributes
                $ia.SetColorMatrix($ColorMatrix,
                    [System.Drawing.Imaging.ColorMatrixFlag]::Default,
                    [System.Drawing.Imaging.ColorAdjustType]::Default)
                $r = New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height)
                $g.DrawImage($img, $r, 0, 0, $img.Width, $img.Height,
                    [System.Drawing.GraphicsUnit]::Pixel, $ia)
                $ia.Dispose()
            } finally { $g.Dispose() }

            $origExt = [System.IO.Path]::GetExtension($InputPath).ToLower()
            Save-Bitmap -Bmp $bmp -OutputPath $OutputPath `
                -OutputFormat $OutputFormat -OriginalExt $origExt -JpegQuality $JpegQuality
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

# --- Matrix builders ---
# All intermediate values pre-computed as [float] to avoid iex arithmetic resolution issues

function Build-BrightnessMatrix {
    param([float]$Value)
    [float]$v = [Math]::Max([float]-1, [Math]::Min([float]1, $Value))
    [float]$z = 0; [float]$o = 1
    return New-Object System.Drawing.Imaging.ColorMatrix (
        ,[float[][]]@(
            [float[]]@($o, $z, $z, $z, $z),
            [float[]]@($z, $o, $z, $z, $z),
            [float[]]@($z, $z, $o, $z, $z),
            [float[]]@($z, $z, $z, $o, $z),
            [float[]]@($v, $v, $v, $z, $o)
        )
    )
}

function Build-ContrastMatrix {
    param([float]$Value)
    [float]$c = [Math]::Max([float]0, $Value)
    [float]$t = ([float]1 - $c) / [float]2
    [float]$z = 0; [float]$o = 1
    return New-Object System.Drawing.Imaging.ColorMatrix (
        ,[float[][]]@(
            [float[]]@($c, $z, $z, $z, $z),
            [float[]]@($z, $c, $z, $z, $z),
            [float[]]@($z, $z, $c, $z, $z),
            [float[]]@($z, $z, $z, $o, $z),
            [float[]]@($t, $t, $t, $z, $o)
        )
    )
}

function Build-SaturationMatrix {
    param([float]$Value)
    [float]$s  = [Math]::Max([float]0, $Value)
    [float]$rw = [float]0.2126
    [float]$gw = [float]0.7152
    [float]$bw = [float]0.0722
    [float]$z  = 0; [float]$o = 1
    # Pre-compute every cell — avoids inline arithmetic crash under iex
    [float]$rr = $rw + ([float]1 - $rw) * $s   # R->R
    [float]$rg = $rw - $rw * $s                 # R->G, R->B (cross-bleed)
    [float]$gg = $gw + ([float]1 - $gw) * $s   # G->G
    [float]$gr = $gw - $gw * $s                 # G->R, G->B
    [float]$bb = $bw + ([float]1 - $bw) * $s   # B->B
    [float]$br = $bw - $bw * $s                 # B->R, B->G
    return New-Object System.Drawing.Imaging.ColorMatrix (
        ,[float[][]]@(
            [float[]]@($rr, $rg, $rg, $z, $z),
            [float[]]@($gr, $gg, $gr, $z, $z),
            [float[]]@($br, $br, $bb, $z, $z),
            [float[]]@($z,  $z,  $z,  $o, $z),
            [float[]]@($z,  $z,  $z,  $z, $o)
        )
    )
}

# ---------------------------------------------------------------------------
# Parallel processing — runspace pool across CPU cores (output is IDENTICAL
# to the old single-threaded path; same per-step ColorMatrix math/clamping).
# ---------------------------------------------------------------------------

# Worker: process ONE file through all adjustments. Runs in a pool runspace.
# The matrix/save helpers are injected into each runspace via InitialSessionState.
$script:AdjustWorker = {
    param($FilePath, $OutName, $Adjustments, $OutputFormat, $JpegQuality,
          $Overwrite, $InputFolder, $OutputFolder)
    Add-Type -AssemblyName System.Drawing
    $tmpOut = $null
    try {
        if ($Overwrite) {
            $tmpOut     = [IO.Path]::Combine([IO.Path]::GetTempPath(),
                          [IO.Path]::GetRandomFileName() + [IO.Path]::GetExtension($OutName))
            $finalOut   = Join-Path $InputFolder $OutName
            $dest4write = $tmpOut
        } else {
            $finalOut   = Join-Path $OutputFolder $OutName
            $dest4write = $finalOut
        }
        $currentInput = $FilePath
        $tempFiles    = @()
        for ($k = 0; $k -lt $Adjustments.Count; $k++) {
            $adj = $Adjustments[$k]
            if ($k -eq $Adjustments.Count - 1) {
                $dest = $dest4write; $passFormat = $OutputFormat; $passQuality = $JpegQuality
            } else {
                $dest = [IO.Path]::Combine([IO.Path]::GetTempPath(),
                        [IO.Path]::GetRandomFileName() + '.png')
                $passFormat = 'png'; $passQuality = 95; $tempFiles += $dest
            }
            $matrix = switch ($adj.Type) {
                'Brightness' { Build-BrightnessMatrix -Value $adj.Value }
                'Contrast'   { Build-ContrastMatrix   -Value $adj.Value }
                'Saturation' { Build-SaturationMatrix -Value $adj.Value }
            }
            Apply-ColorMatrix -InputPath $currentInput -OutputPath $dest `
                -ColorMatrix $matrix -OutputFormat $passFormat -JpegQuality $passQuality
            $currentInput = $dest
        }
        if ($Overwrite -and (Test-Path $tmpOut)) {
            if ((Test-Path $FilePath) -and $FilePath -ne $finalOut) {
                Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
            }
            Move-Item -Path $tmpOut -Destination $finalOut -Force
        }
        foreach ($t in $tempFiles) { if (Test-Path $t) { Remove-Item $t -ErrorAction SilentlyContinue } }
        return "OK`t$OutName"
    } catch {
        if ($tmpOut -and (Test-Path $tmpOut)) { Remove-Item $tmpOut -ErrorAction SilentlyContinue }
        return "FAIL`t$OutName`t$_"
    }
}

function Get-AdjustOutName {
    param($File, $OutputFormat)
    $outName = $File.Name
    if ($OutputFormat -eq 'jpg' -and $File.Extension.ToLower() -notin '.jpg','.jpeg') {
        $outName = [IO.Path]::GetFileNameWithoutExtension($File.Name) + '.jpg'
    } elseif ($OutputFormat -eq 'png' -and $File.Extension.ToLower() -ne '.png') {
        $outName = [IO.Path]::GetFileNameWithoutExtension($File.Name) + '.png'
    }
    return $outName
}

function Invoke-AdjustParallel {
    param(
        [array]$Images, [array]$Adjustments, [string]$OutputFormat, [int]$JpegQuality,
        [bool]$Overwrite, [string]$InputFolder, [string]$OutputFolder, [switch]$Quiet
    )
    if ($JpegQuality -lt 1) { $JpegQuality = 95 }
    $maxThreads = [Math]::Max(1, [Environment]::ProcessorCount)
    $fnNames = 'Save-Bitmap','Apply-ColorMatrix','Build-BrightnessMatrix',
               'Build-ContrastMatrix','Build-SaturationMatrix'
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in $fnNames) {
        $body = (Get-Command $fn).Definition
        $iss.Commands.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $body)))
    }
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
                1, $maxThreads, $iss, $Host)
    $pool.Open()
    if (-not $Quiet) {
        Write-Host "Processing $($Images.Count) image(s) on up to $maxThreads parallel workers..." -ForegroundColor Cyan
    }
    $jobs = New-Object System.Collections.ArrayList
    foreach ($file in $Images) {
        $outName = Get-AdjustOutName -File $file -OutputFormat $OutputFormat
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($script:AdjustWorker).
            AddArgument($file.FullName).AddArgument($outName).AddArgument($Adjustments).
            AddArgument($OutputFormat).AddArgument([int]$JpegQuality).AddArgument([bool]$Overwrite).
            AddArgument($InputFolder).AddArgument($OutputFolder)
        [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }
    $ok = 0; $fail = 0; $done = 0; $total = $jobs.Count
    foreach ($j in $jobs) {
        $res = $j.PS.EndInvoke($j.Handle)
        $j.PS.Dispose()
        $done++
        foreach ($line in $res) {
            $parts = $line -split "`t"
            if ($parts[0] -eq 'OK') {
                $ok++
                if ($Quiet) { Write-Host "[$done/$total] saved $($parts[1])" }
            } elseif ($parts[0] -eq 'FAIL') {
                $fail++
                Write-Warning "Failed on $($parts[1]): $($parts[2])"
            }
        }
        Write-Progress -Activity "Adjusting images" -Status "$done of $total" `
            -PercentComplete ([int](($done / $total) * 100))
    }
    $pool.Close(); $pool.Dispose()
    return [pscustomobject]@{ Ok = $ok; Fail = $fail }
}

# Original single-threaded path — kept as an option (slower but simplest).
function Invoke-AdjustSequential {
    param(
        [array]$Images, [array]$Adjustments, [string]$OutputFormat, [int]$JpegQuality,
        [bool]$Overwrite, [string]$InputFolder, [string]$OutputFolder, [switch]$Quiet
    )
    if ($JpegQuality -lt 1) { $JpegQuality = 95 }
    $ok = 0; $fail = 0; $i = 0; $total = $Images.Count
    if (-not $Quiet) { Write-Host "Processing $total image(s) sequentially..." -ForegroundColor Cyan }
    foreach ($file in $Images) {
        $i++
        $outName = Get-AdjustOutName -File $file -OutputFormat $OutputFormat
        if ($Overwrite) {
            $tmpOut     = [IO.Path]::Combine([IO.Path]::GetTempPath(),
                          [IO.Path]::GetRandomFileName() + [IO.Path]::GetExtension($outName))
            $finalOut   = Join-Path $InputFolder $outName
            $dest4write = $tmpOut
        } else {
            $tmpOut = $null; $finalOut = Join-Path $OutputFolder $outName; $dest4write = $finalOut
        }
        $currentInput = $file.FullName; $tempFiles = @(); $failed = $false
        for ($k = 0; $k -lt $Adjustments.Count; $k++) {
            $adj = $Adjustments[$k]
            if ($k -eq $Adjustments.Count - 1) {
                $dest = $dest4write; $passFormat = $OutputFormat; $passQuality = $JpegQuality
            } else {
                $dest = [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName() + '.png')
                $passFormat = 'png'; $passQuality = 95; $tempFiles += $dest
            }
            $matrix = switch ($adj.Type) {
                'Brightness' { Build-BrightnessMatrix -Value $adj.Value }
                'Contrast'   { Build-ContrastMatrix   -Value $adj.Value }
                'Saturation' { Build-SaturationMatrix -Value $adj.Value }
            }
            try {
                Apply-ColorMatrix -InputPath $currentInput -OutputPath $dest `
                    -ColorMatrix $matrix -OutputFormat $passFormat -JpegQuality $passQuality
            } catch { Write-Warning "Failed on $($file.Name): $_"; $failed = $true; break }
            $currentInput = $dest
        }
        if (-not $failed -and $Overwrite -and (Test-Path $tmpOut)) {
            if ((Test-Path $file.FullName) -and $file.FullName -ne $finalOut) {
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
            Move-Item -Path $tmpOut -Destination $finalOut -Force
        }
        foreach ($t in $tempFiles) { if (Test-Path $t) { Remove-Item $t -ErrorAction SilentlyContinue } }
        if ($failed -and $tmpOut -and (Test-Path $tmpOut)) { Remove-Item $tmpOut -ErrorAction SilentlyContinue }
        if ($failed) { $fail++ } else { $ok++; if ($Quiet) { Write-Host "[$i/$total] saved $outName" } }
        Write-Progress -Activity "Adjusting images" -Status "$i of $total" `
            -PercentComplete ([int](($i / $total) * 100))
    }
    return [pscustomobject]@{ Ok = $ok; Fail = $fail }
}

# Dispatch by mode ('parallel' = fast/default, 'sequential' = original).
function Invoke-Adjust {
    param(
        [string]$Mode, [array]$Images, [array]$Adjustments, [string]$OutputFormat,
        [int]$JpegQuality, [bool]$Overwrite, [string]$InputFolder, [string]$OutputFolder, [switch]$Quiet
    )
    if ($Mode -eq 'sequential') {
        return Invoke-AdjustSequential -Images $Images -Adjustments $Adjustments `
            -OutputFormat $OutputFormat -JpegQuality $JpegQuality -Overwrite $Overwrite `
            -InputFolder $InputFolder -OutputFolder $OutputFolder -Quiet:$Quiet
    }
    return Invoke-AdjustParallel -Images $Images -Adjustments $Adjustments `
        -OutputFormat $OutputFormat -JpegQuality $JpegQuality -Overwrite $Overwrite `
        -InputFolder $InputFolder -OutputFolder $OutputFolder -Quiet:$Quiet
}

# --- Batch helpers ---------------------------------------------------------
$script:IMG_EXTS = '*.jpg','*.jpeg','*.png','*.bmp','*.gif','*.tif','*.tiff'

function Get-AdjustImages {
    param([string]$Folder)
    $imgs = @()
    foreach ($e in $script:IMG_EXTS) { $imgs += Get-ChildItem -Path $Folder -Filter $e -File }
    return @($imgs | Sort-Object Name)
}

function Get-ImageSubfolders {
    # Immediate subfolders that contain images, excluding our own output dirs.
    param([string]$Parent)
    Get-ChildItem -Path $Parent -Directory | Where-Object {
        $_.Name -notlike 'adjusted_*' -and $_.Name -notlike 'cropped_*' -and
        $_.Name -notlike 'framed_*'   -and $_.Name -ne '_internal' -and
        (Get-AdjustImages $_.FullName).Count -gt 0
    } | Sort-Object Name
}

function Invoke-AdjustFolder {
    # Process ONE source folder -> its own adjusted_* subfolder. Returns {Ok,Fail}.
    param(
        [string]$SourceFolder, [array]$Adjustments, [string]$OutputFormat,
        [int]$JpegQuality, [string]$Processing, [string]$FormatSuffix
    )
    $images = Get-AdjustImages $SourceFolder
    if ($images.Count -eq 0) {
        Write-Host "  (no images in $SourceFolder)"; return [pscustomobject]@{ Ok = 0; Fail = 0 }
    }
    $suffix = ($Adjustments | ForEach-Object { "$($_.Type.Substring(0,1).ToLower())$($_.Value)" }) -join '_'
    $outputFolder = Join-Path $SourceFolder "adjusted_${suffix}_${FormatSuffix}"
    if (-not (Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder | Out-Null }
    Write-Host "Adjust: $($images.Count) image(s)  ->  $outputFolder"
    return (Invoke-Adjust -Mode $Processing -Images $images -Adjustments $Adjustments `
        -OutputFormat $OutputFormat -JpegQuality $JpegQuality -Overwrite $false `
        -InputFolder $SourceFolder -OutputFolder $outputFolder -Quiet)
}

# ---------------------------------------------------------------------------
# Preset helpers  — one JSON file per preset, named preset_01_desc.json
# ---------------------------------------------------------------------------

function Get-PresetFolder { return (Join-Path (Get-ScriptFolder) '00_PRESETS') }

function Get-PresetFiles {
    # Returns FileInfo objects sorted by filename (so 01 before 02 etc.)
    [array]$files = @(Get-ChildItem -Path (Get-PresetFolder) -Filter 'preset_*.json' -File |
                      Sort-Object Name)
    return $files
}

function Load-SinglePreset {
    param([string]$FilePath)
    try {
        $raw = Get-Content $FilePath -Raw | ConvertFrom-Json
        return $raw
    } catch { return $null }
}

function Next-PresetNumber {
    [array]$files = @(Get-PresetFiles)
    [int]$max = 0
    foreach ($f in $files) {
        if ($f.Name -match '^preset_(\d+)_') {
            [int]$n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return $max + 1
}

function Make-PresetFilename {
    param([string]$Description, [int]$Number)
    # Sanitise description for use in a filename
    $safe = $Description -replace '[^a-zA-Z0-9 _-]','' `
                         -replace '\s+','_' `
                         -replace '_+','_'
    $safe = $safe.Trim('_').ToLower()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'preset' }
    return ('preset_{0:D2}_{1}.json' -f $Number, $safe)
}

function Show-PresetMenu {
    [array]$files = @(Get-PresetFiles)
    [int]$total   = $files.Count
    if ($total -eq 0) { return $null }

    Write-Host "`nSaved presets ($total found):" -ForegroundColor White
    Write-Host ("  {0,-4} {1,-28} {2,-28} {3}" -f '#','File','Adjustments','Output') -ForegroundColor DarkGray
    Write-Host ("  " + ('-' * 75)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $total; $i++) {
        $p = Load-SinglePreset -FilePath $files[$i].FullName
        if (-not $p) { continue }
        $adjStr = ($p.adjustments | ForEach-Object { "$($_.Type.Substring(0,1).ToUpper())=$($_.Value)" }) -join ' '
        $fmtStr = if ($p.outputFormat -eq 'jpg') { "JPG q$($p.jpegQuality)" }
                  elseif ($p.outputFormat -eq 'png') { 'PNG' }
                  else { 'original' }
        $fname  = [System.IO.Path]::GetFileNameWithoutExtension($files[$i].Name)
        Write-Host ("  [{0}] {1,-28} {2,-28} {3}" -f ($i+1), $fname, $adjStr, $fmtStr) -ForegroundColor DarkCyan
        if ($p.folderPath) {
            Write-Host ("       Folder: {0}" -f $p.folderPath) -ForegroundColor DarkGray
        }
    }
    Write-Host "  [0] Skip — enter settings manually"

    while ($true) {
        $raw = (Read-Host "`nEnter preset number (0-$total)").Trim()
        [int]$n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0 -and $n -le $total) {
            if ($n -eq 0) { return $null }
            return (Load-SinglePreset -FilePath $files[$n - 1].FullName)
        }
        Write-Host "  Please enter a number between 0 and $total." -ForegroundColor Yellow
    }
}

function Prompt-SavePreset {
    param($Adjustments, [string]$OutputFormat, [int]$JpegQuality, [string]$FolderPath)
    $ans = (Read-Host "`nSave these settings as a preset? [y/N]").Trim().ToLower()
    if ($ans -ne 'y') { return }

    $desc = ''
    while ([string]::IsNullOrWhiteSpace($desc)) {
        $desc = (Read-Host "Short description (used in filename, e.g. 'warm vivid landscapes')").Trim()
    }

    [int]$num  = Next-PresetNumber
    $filename  = Make-PresetFilename -Description $desc -Number $num
    $filepath  = Join-Path (Get-PresetFolder) $filename

    $obj = [PSCustomObject]@{
        description  = $desc
        folderPath   = $FolderPath
        adjustments  = @($Adjustments | ForEach-Object {
            [PSCustomObject]@{ Type = $_.Type; Value = $_.Value }
        })
        outputFormat = $OutputFormat
        jpegQuality  = $JpegQuality
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $filepath -Encoding UTF8
    Write-Host "  Saved as: $filename" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

function Write-Header {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "   Batch Image Adjuster  v$VERSION" -ForegroundColor White
    Write-Host "   BR / Contrast / Saturation + Format Control" -ForegroundColor Gray
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""
    $CHANGELOG -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host ""
}

function Read-FloatInRange {
    param([string]$Prompt, [float]$Min, [float]$Max, [float]$Default)
    while ($true) {
        $raw = Read-Host "$Prompt [default: $Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $parsed = 0.0
        if ([float]::TryParse($raw, [ref]$parsed)) {
            if ($parsed -ge $Min -and $parsed -le $Max) { return $parsed }
            Write-Host "  Please enter a value between $Min and $Max." -ForegroundColor Yellow
        } else {
            Write-Host "  Invalid number. Try again." -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# --- Non-interactive run for the control panel (env: PDF_RUN_*) -------------
if ($env:PDF_RUN) {
    try {
        $pp     = $env:PDF_RUN_PRESET
        $folder = $env:PDF_RUN_FOLDER
        $preset = $null
        if ($pp -and (Test-Path $pp)) { $preset = Get-Content -Raw -Path $pp | ConvertFrom-Json }
        if (-not $folder -and $preset) { $folder = $preset.folderPath }
        if (-not (Test-Path $folder -PathType Container)) { Write-Host "ERROR: folder not found: $folder"; exit 1 }

        $adjustments = @()
        if ($preset -and $preset.adjustments) {
            $adjustments = @($preset.adjustments | ForEach-Object { @{ Type = $_.Type; Value = [float]$_.Value } })
        }
        if ($adjustments.Count -eq 0) { Write-Host "ERROR: preset has no adjustments"; exit 1 }
        $outputFormat = if ($preset.outputFormat) { [string]$preset.outputFormat } else { 'original' }
        $jpegQuality  = if ($preset.jpegQuality)  { [int]$preset.jpegQuality }       else { 95 }
        $processing   = if ($preset.processing)   { [string]$preset.processing }     else { 'parallel' }
        $inputSource  = if ($preset.inputSource)  { [string]$preset.inputSource }    else { 'folder' }
        $formatSuffix = if ($outputFormat -eq 'jpg') { "jpg$jpegQuality" } elseif ($outputFormat -eq 'png') { 'png' } else { 'orig' }

        if ($inputSource -eq 'batch') {
            $subs = @(Get-ImageSubfolders $folder)
            if ($subs.Count -eq 0) { Write-Host "ERROR: no subfolders with images under $folder"; exit 1 }
            Write-Host "Batch: $($subs.Count) subfolder(s) under $folder"
            $tot = 0; $totFail = 0; $si = 0
            foreach ($sub in $subs) {
                $si++
                Write-Host "`n=== [$si/$($subs.Count)] $($sub.Name) ==="
                $r = Invoke-AdjustFolder -SourceFolder $sub.FullName -Adjustments $adjustments `
                    -OutputFormat $outputFormat -JpegQuality $jpegQuality -Processing $processing -FormatSuffix $formatSuffix
                $tot += $r.Ok; $totFail += $r.Fail
            }
            Write-Host "`nDONE (batch): $($subs.Count) folder(s) | $tot ok, $totFail failed  ->  $folder"
            if ($totFail -gt 0) { exit 1 } else { exit 0 }
        }

        $images = @(Get-AdjustImages $folder)
        if ($images.Count -eq 0) { Write-Host "ERROR: no images in $folder"; exit 1 }
        $res = Invoke-AdjustFolder -SourceFolder $folder -Adjustments $adjustments `
            -OutputFormat $outputFormat -JpegQuality $jpegQuality -Processing $processing -FormatSuffix $formatSuffix
        Write-Host "DONE: $($res.Ok) ok, $($res.Fail) failed  ->  $folder"
        if ($res.Fail -gt 0) { exit 1 } else { exit 0 }
    } catch {
        Write-Host "ERROR: $_"
        exit 1
    }
}

Write-Header

# --- Load preset? (before folder so saved path can pre-fill) ---
$preset = Show-PresetMenu

# --- Source folder ---
$defaultFolder = Get-ScriptFolder
$inputFolder   = $null

# If the preset carries a valid folder, use it on Y - no second prompt.
if ($preset -and $preset.folderPath -and (Test-Path $preset.folderPath -PathType Container)) {
    Write-Host "`nPreset has a saved folder:" -ForegroundColor White
    Write-Host "  $($preset.folderPath)" -ForegroundColor DarkCyan
    $usePF = (Read-Host "Use this folder? [Y/n]").Trim().ToLower()
    if ($usePF -ne 'n') {
        $inputFolder = $preset.folderPath
        Write-Host "Using preset folder." -ForegroundColor DarkGray
    }
}

# Only ask when there is no preset folder (or the user declined it).
if (-not $inputFolder) {
    Write-Host "`nSource folder (press Enter to use default):"
    Write-Host "  $defaultFolder" -ForegroundColor DarkGray
    $inputFolder = Read-Host "Folder path"
    if ([string]::IsNullOrWhiteSpace($inputFolder)) { $inputFolder = $defaultFolder }
}
if (-not (Test-Path $inputFolder -PathType Container)) {
    Write-Host "Folder not found: $inputFolder" -ForegroundColor Red; exit 1
}

# --- Batch mode? (each subfolder processed separately) ---
$batchMode = $false
if ($preset -and $preset.inputSource -eq 'batch') {
    $batchMode = $true
    Write-Host "`nBatch mode (from preset): each subfolder processed separately." -ForegroundColor Cyan
} elseif (-not $preset) {
    $bm = (Read-Host "`nBatch mode - process each SUBFOLDER separately? [y/N]").Trim().ToLower()
    $batchMode = ($bm -eq 'y')
}

# --- Find images (single mode only; batch discovers per-subfolder later) ---
if (-not $batchMode) {
    $images = @(Get-AdjustImages $inputFolder)
    if ($images.Count -eq 0) {
        Write-Host "`nNo image files found in: $inputFolder" -ForegroundColor Yellow; exit 0
    }
    Write-Host "`nFound $($images.Count) image(s):" -ForegroundColor Green
    $images | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor DarkGray }
} else {
    $subsPreview = @(Get-ImageSubfolders $inputFolder)
    if ($subsPreview.Count -eq 0) {
        Write-Host "`nNo subfolders with images under: $inputFolder" -ForegroundColor Yellow; exit 0
    }
    Write-Host "`nBatch: $($subsPreview.Count) subfolder(s) to process." -ForegroundColor Green
}

$adjustments  = @()
$outputFormat = 'original'
$jpegQuality  = 95
$formatSuffix = 'orig'
$processing   = 'parallel'

if ($preset) {
    # Apply loaded preset
    Write-Host "`nPreset loaded — settings applied:" -ForegroundColor Green
    $adjustments  = @($preset.adjustments | ForEach-Object { @{ Type = $_.Type; Value = [float]$_.Value } })
    $outputFormat = $preset.outputFormat
    $jpegQuality  = [int]$preset.jpegQuality
    if ($preset.processing) { $processing = [string]$preset.processing }
    $formatSuffix = if ($outputFormat -eq 'jpg') { "jpg$jpegQuality" }
                    elseif ($outputFormat -eq 'png') { 'png' }
                    else { 'orig' }
    $adjustments | ForEach-Object { Write-Host "  $($_.Type) = $($_.Value)" -ForegroundColor DarkCyan }
    Write-Host "  Output: $outputFormat$(if ($outputFormat -eq 'jpg') { " q$jpegQuality" })" -ForegroundColor DarkCyan
} else {
    # --- Manual adjustment entry ---
    Write-Host "`nWhat would you like to adjust?" -ForegroundColor White
    Write-Host "  [1] Brightness"
    Write-Host "  [2] Contrast"
    Write-Host "  [3] Saturation"
    Write-Host "  [4] All three (chain adjustments)"

    $choice = ''
    while ($choice -notin '1','2','3','4') { $choice = (Read-Host "`nEnter choice (1-4)").Trim() }

    switch ($choice) {
        '1' {
            Write-Host "`nBrightness: -1.0 = pitch black  |  0 = no change  |  +1.0 = pure white"
            $adjustments += @{ Type = 'Brightness'; Value = (Read-FloatInRange -Prompt "Brightness" -Min -1 -Max 1 -Default 0.2) }
        }
        '2' {
            Write-Host "`nContrast:   0 = flat grey  |  1 = no change  |  2+ = high contrast"
            $adjustments += @{ Type = 'Contrast'; Value = (Read-FloatInRange -Prompt "Contrast" -Min 0 -Max 4 -Default 1.2) }
        }
        '3' {
            Write-Host "`nSaturation: 0 = greyscale  |  1 = no change  |  2 = vivid"
            $adjustments += @{ Type = 'Saturation'; Value = (Read-FloatInRange -Prompt "Saturation" -Min 0 -Max 4 -Default 1.3) }
        }
        '4' {
            Write-Host "`n--- Brightness ---  -1.0 = pitch black  |  0 = no change  |  +1.0 = pure white"
            $adjustments += @{ Type = 'Brightness'; Value = (Read-FloatInRange -Prompt "Brightness" -Min -1 -Max 1 -Default 0.0) }
            Write-Host "`n--- Contrast ---    0 = flat grey  |  1 = no change  |  2+ = high contrast"
            $adjustments += @{ Type = 'Contrast';   Value = (Read-FloatInRange -Prompt "Contrast"   -Min 0 -Max 4 -Default 1.0) }
            Write-Host "`n--- Saturation ---  0 = greyscale  |  1 = no change  |  2 = vivid"
            $adjustments += @{ Type = 'Saturation'; Value = (Read-FloatInRange -Prompt "Saturation" -Min 0 -Max 4 -Default 1.0) }
        }
    }

    # --- Output format ---
    Write-Host "`nOutput format:" -ForegroundColor White
    Write-Host "  [1] Keep original format  (JPGs stay JPG, PNGs stay PNG, etc.)"
    Write-Host "  [2] Save as JPG           (lossy — you choose quality)"
    Write-Host "  [3] Save as PNG           (lossless — no quality loss)"

    $fmtChoice = ''
    while ($fmtChoice -notin '1','2','3') { $fmtChoice = (Read-Host "`nEnter choice (1-3)").Trim() }

    switch ($fmtChoice) {
        '1' { $outputFormat = 'original'; $formatSuffix = 'orig' }
        '2' {
            $outputFormat = 'jpg'
            Write-Host "`nJPEG quality: 100 = best (largest)  |  85 = good balance  |  50 = small file"
            $jpegQuality  = [int](Read-FloatInRange -Prompt "Quality (1-100)" -Min 1 -Max 100 -Default 85)
            $formatSuffix = "jpg$jpegQuality"
        }
        '3' { $outputFormat = 'png'; $formatSuffix = 'png' }
    }

    # --- Offer to save preset ---
    Prompt-SavePreset -Adjustments $adjustments -OutputFormat $outputFormat -JpegQuality $jpegQuality -FolderPath $inputFolder
}

if ($batchMode) {
    # Batch always writes each subfolder's output into its own adjusted_ folder.
    Write-Host ""
    $subs = @(Get-ImageSubfolders $inputFolder)
    $tot = 0; $totFail = 0; $si = 0
    foreach ($sub in $subs) {
        $si++
        Write-Host "`n=== [$si/$($subs.Count)] $($sub.Name) ===" -ForegroundColor Cyan
        $r = Invoke-AdjustFolder -SourceFolder $sub.FullName -Adjustments $adjustments `
            -OutputFormat $outputFormat -JpegQuality $jpegQuality -Processing $processing -FormatSuffix $formatSuffix
        $tot += $r.Ok; $totFail += $r.Fail
    }
    Write-Progress -Activity "Adjusting images" -Completed
    Write-Host "`nDone (batch)! $($subs.Count) folder(s) | $tot processed, $totFail failed." -ForegroundColor Green
} else {
    # --- Output destination (single mode) ---
    Write-Host "`nOutput destination:" -ForegroundColor White
    Write-Host "  [1] Save to new subfolder   (safe — originals untouched)"
    Write-Host "  [2] Overwrite originals     (replaces files in place)"

    $destChoice = ''
    while ($destChoice -notin '1','2') { $destChoice = (Read-Host "`nEnter choice (1-2)").Trim() }
    $overwrite = ($destChoice -eq '2')

    if (-not $overwrite) {
        $suffix = ($adjustments | ForEach-Object {
            "$($_.Type.Substring(0,1).ToLower())$($_.Value)"
        }) -join '_'
        $outputFolder = Join-Path $inputFolder "adjusted_${suffix}_${formatSuffix}"
        if (-not (Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder | Out-Null }
        Write-Host "`nOutput folder: $outputFolder" -ForegroundColor Cyan
    } else {
        $outputFolder = $inputFolder
        Write-Host "`nOverwrite mode: files will be replaced in $outputFolder" -ForegroundColor Yellow
    }

    Write-Host ""
    $res = Invoke-Adjust -Mode $processing -Images $images -Adjustments $adjustments `
        -OutputFormat $outputFormat -JpegQuality $jpegQuality -Overwrite $overwrite `
        -InputFolder $inputFolder -OutputFolder $outputFolder

    Write-Progress -Activity "Adjusting images" -Completed
    Write-Host "Done! $($res.Ok) processed, $($res.Fail) failed." -ForegroundColor Green
}
if (-not $overwrite) { Write-Host "  Output: $outputFolder" -ForegroundColor Cyan }
else { Write-Host "  Files updated in place: $inputFolder" -ForegroundColor Cyan }
Write-Host ""
