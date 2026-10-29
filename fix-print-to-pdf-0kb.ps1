# ============================================================
#  修复：Microsoft Print to PDF 输出 0KB
#
#  根因：C:\Windows\System32\spoolsv.exe 被替换成非原厂版本，
#        处理 PDF 打印作业时执行非法指令（0xc000001d）崩溃，
#        输出文件保持 0 字节。
#
#  做法：从 WinSxS 取原厂 spoolsv.exe 覆盖 → 重启打印服务 → 自检
#        自检失败自动回滚
#
#  用法：右键本文件 -> "使用 PowerShell 运行" -> UAC 点【是】
#  建议：先运行 diagnose-print-to-pdf.ps1 确认命中本问题
# ============================================================

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限，正在提权，请点【是】..." -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

$backup = Join-Path ([Environment]::GetFolderPath('Desktop')) ("PrintToPDF_fix_backup_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$log = Join-Path $backup 'fix.log'

function W($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

$dst = "$env:SystemRoot\System32\spoolsv.exe"
$bak = Join-Path $backup 'spoolsv.exe.original.bak'

W "=== Microsoft Print to PDF 0KB 修复 ==="
W "备份目录: $backup"
W ""

# ---------- 1. 定位原厂文件 ----------
$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
$srcItem = Get-ChildItem "$env:SystemRoot\WinSxS" -Directory -Filter "${arch}_microsoft-windows-printing-spooler-core_*" -ErrorAction SilentlyContinue |
           ForEach-Object { Join-Path $_.FullName 'spoolsv.exe' } |
           Where-Object { Test-Path $_ } |
           ForEach-Object { Get-Item $_ } |
           Sort-Object Length -Descending |
           Select-Object -First 1

if (-not $srcItem) {
    W "错误：在 WinSxS 中找不到原厂 spoolsv.exe"
    W "请尝试以管理员身份运行: sfc /scannow"
    Read-Host "按回车键关闭窗口"
    exit
}

$src  = $srcItem.FullName
$hSrc = (Get-FileHash $src -Algorithm SHA256).Hash
$hDst = (Get-FileHash $dst -Algorithm SHA256).Hash

W "原厂文件: $src"
W "  版本  : $($srcItem.VersionInfo.FileVersion)"
W "  哈希  : $hSrc"
W "当前文件: $dst"
W "  哈希  : $hDst"
W ""

if ($hSrc -eq $hDst) {
    W "当前已是原厂文件，无需替换。直接进入自检。"
    $replaced = $false
} else {
    W "哈希不一致，确认需要替换。"
    Copy-Item -LiteralPath $dst -Destination $bak -Force
    W "已备份当前文件: $bak"
    W ""

    W "停止 Print Spooler..."
    Stop-Service Spooler -Force
    Start-Sleep -Seconds 3

    $replaced = $false
    try {
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $replaced = $true
        W "直接覆盖成功"
    } catch {
        W "直接覆盖失败: $($_.Exception.Message)"
        W "尝试接管文件所有权后重试..."
        & takeown.exe /f "$dst" /a | Out-Null
        & icacls.exe "$dst" /grant "*S-1-5-32-544:(F)" | Out-Null
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            $replaced = $true
            W "接管所有权后覆盖成功"
        } catch {
            W "仍然失败: $($_.Exception.Message)"
            W "请以管理员身份手动执行 README 中的「手动修复」步骤。"
        }
    }

    if ($replaced) {
        $hNew = (Get-FileHash $dst -Algorithm SHA256).Hash
        W "替换后哈希: $hNew"
        W "与原件一致: $($hNew -eq $hSrc)"
    }

    W "启动 Print Spooler..."
    Start-Service Spooler
    Start-Sleep -Seconds 4
}
W ""

# ---------- 2. 自检打印 ----------
function Test-PdfPrint {
    $out = Join-Path $backup ("selftest_" + (Get-Date -Format 'HHmmss') + ".pdf")
    if (Test-Path $out) { Remove-Item $out -Force }
    try {
        Add-Type -AssemblyName System.Drawing
        $doc = New-Object System.Drawing.Printing.PrintDocument
        $doc.PrinterSettings.PrinterName  = 'Microsoft Print to PDF'
        $doc.PrinterSettings.PrintToFile   = $true
        $doc.PrinterSettings.PrintFileName = $out
        $doc.DocumentName = 'pdf_selftest'
        $doc.PrintController = New-Object System.Drawing.Printing.StandardPrintController
        $doc.Print()
        $doc.Dispose()
        Start-Sleep -Seconds 5

        if (-not (Test-Path $out)) { W "测试输出: 文件未生成"; return $false }
        $len = (Get-Item $out).Length
        if ($len -lt 100) { W "测试输出: 仅 $len 字节，判定失败"; return $false }

        $bytes = [System.IO.File]::ReadAllBytes($out)
        $head  = [System.Text.Encoding]::ASCII.GetString($bytes[0..4])
        $tail  = [System.Text.Encoding]::ASCII.GetString($bytes[($bytes.Length - 6)..($bytes.Length - 1)])
        $ok = ($head -eq '%PDF-') -and ($tail -match 'EOF')
        W "测试输出: $len 字节   文件头=$head   结尾=$($tail.Trim())   有效PDF=$ok"
        W "测试文件: $out"
        return $ok
    } catch {
        W "测试打印异常: $($_.Exception.Message)"
        return $false
    }
}

W "开始自检打印..."
$okPdf = Test-PdfPrint

$crashed = $false
$c = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=(Get-Date).AddSeconds(-40)} -ErrorAction SilentlyContinue |
       Where-Object { $_.Message -match 'spoolsv' })
if ($c.Count -gt 0) {
    $crashed = $true
    W "spoolsv 崩溃: $($c[0].TimeCreated)"
} else {
    W "无新崩溃"
}
W ""

# ---------- 3. 结果 ----------
if ($okPdf -and -not $crashed) {
    Write-Host "================  修复成功  ================" -ForegroundColor Green
    Write-Host "PDF 已能正常生成，spoolsv 不再崩溃。" -ForegroundColor Green
    Write-Host "现在可以正常打印到 Microsoft Print to PDF 了。" -ForegroundColor Cyan
} else {
    Write-Host "================  修复失败  ================" -ForegroundColor Red
    if ($replaced) {
        Write-Host "替换后依旧失败，正在还原备份..." -ForegroundColor Yellow
        try {
            Stop-Service Spooler -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Copy-Item -LiteralPath $bak -Destination $dst -Force -ErrorAction Stop
            Start-Service Spooler -ErrorAction SilentlyContinue
            Write-Host "已还原。" -ForegroundColor Yellow
        } catch {
            Write-Host "还原失败，请手动复制: $bak -> $dst" -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "你的 0KB 问题可能不是 spoolsv.exe 导致。建议改用 PDF24 等第三方虚拟打印机。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "备份与日志: $backup" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键关闭窗口"
