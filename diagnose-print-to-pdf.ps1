# ============================================================
#  诊断：Microsoft Print to PDF 输出 0KB
#
#  检查 spoolsv.exe 是否被替换、是否存在 0xc000001d 崩溃记录
#  只读操作，不修改任何文件
#
#  用法：右键本文件 -> "使用 PowerShell 运行" -> UAC 点【是】
# ============================================================

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限以读取崩溃报告，正在提权..." -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

function Line { param($t) Write-Host $t }

$hit = 0
$total = 0

Line "=============================================="
Line " Microsoft Print to PDF 0KB 诊断"
Line " 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Line "=============================================="
Line ""

# ---------- 1. 打印机状态 ----------
Line "[1/5] 打印机与队列"
$pr = Get-Printer -Name 'Microsoft Print to PDF' -ErrorAction SilentlyContinue
if ($pr) {
    $jobs = @(Get-PrintJob -PrinterName 'Microsoft Print to PDF' -ErrorAction SilentlyContinue)
    Line "  打印机存在     : 是"
    Line "  状态           : $($pr.PrinterStatus)"
    Line "  队列作业数     : $($jobs.Count)"
    if ($jobs.Count -gt 0) {
        foreach ($j in $jobs) { Line "    - #$($j.Id) $($j.DocumentName) [$($j.JobStatus)]" }
    }
} else {
    Line "  打印机不存在！请先在「启用或关闭 Windows 功能」中启用 Microsoft Print to PDF" -ForegroundColor Red
}
Line ""

# ---------- 2. spoolsv.exe 哈希比对 ----------
Line "[2/5] spoolsv.exe 完整性（关键）"
$dst = "$env:SystemRoot\System32\spoolsv.exe"
if (-not (Test-Path $dst)) {
    Line "  找不到 $dst" -ForegroundColor Red
} else {
    $hDst = (Get-FileHash $dst -Algorithm SHA256).Hash
    $vi = (Get-Item $dst).VersionInfo
    Line "  System32 哈希  : $hDst"
    Line "  文件版本字符串 : $($vi.FileVersion)"
    Line "  固定版本       : $($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
    Line ""

    $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
    $orig = Get-ChildItem "$env:SystemRoot\WinSxS" -Directory -Filter "${arch}_microsoft-windows-printing-spooler-core_*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'spoolsv.exe' } |
            Where-Object { Test-Path $_ } |
            ForEach-Object { Get-Item $_ } |
            Sort-Object Length -Descending

    if (-not $orig) {
        Line "  未在 WinSxS 找到原件，无法比对" -ForegroundColor Yellow
    } else {
        $matched = $false
        foreach ($o in $orig) {
            $ho = (Get-FileHash $o.FullName -Algorithm SHA256).Hash
            $same = ($ho -eq $hDst)
            if ($same) { $matched = $true }
            Line ("  组件库原件     : " + $ho + $(if ($same) { "  [一致]" } else { "  [不一致]" }))
            Line ("    路径: " + $o.FullName)
        }
        Line ""
        $total++
        if ($matched) {
            Line "  >> spoolsv.exe 与组件库一致，不是本问题" -ForegroundColor Green
        } else {
            $hit++
            Line "  >> spoolsv.exe 与组件库不一致 —— 命中本问题！" -ForegroundColor Red
        }
    }
}
Line ""

# ---------- 3. 崩溃记录 ----------
Line "[3/5] spoolsv.exe 崩溃记录"
$crashes = @()
try {
    $crashes = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 500 -ErrorAction Stop |
                 Where-Object { $_.Message -match 'spoolsv' })
} catch {
    Line "  读取事件日志失败: $($_.Exception.Message)" -ForegroundColor Yellow
}
if ($crashes.Count -eq 0) {
    Line "  未发现 spoolsv.exe 崩溃记录"
} else {
    Line "  发现 $($crashes.Count) 条崩溃记录"
    $illegal = 0
    foreach ($c in $crashes | Select-Object -First 5) {
        $code = if ($c.Message -match '异常代码[：:]\s*(\S+)') { $Matches[1] } else { '?' }
        $off  = if ($c.Message -match '错误偏移[：:]\s*(\S+)') { $Matches[1] } else { '?' }
        $ver  = if ($c.Message -match '版本[：:]\s*(\S+)') { $Matches[1] } else { '?' }
        if ($code -eq '0xc000001d') { $illegal++ }
        Line "    $($c.TimeCreated)  代码=$code  偏移=$off  版本=$ver"
    }
    foreach ($c in $crashes) {
        if ($c.Message -match '0xc000001d') { $illegal++ }
    }
    Line ""
    if ($illegal -gt 0) {
        $hit++
        Line "  >> 存在 0xc000001d（非法指令）崩溃 —— 符合本问题特征" -ForegroundColor Red
    } else {
        Line "  >> 崩溃原因不是非法指令，可能属于其他故障"
    }
}
Line ""

# ---------- 4. WER 崩溃报告 ----------
Line "[4/5] WER 崩溃报告归档"
$werDirs = @()
foreach ($r in @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) {
    if (Test-Path $r) {
        $werDirs += @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'spoolsv' })
    }
}
if ($werDirs.Count -eq 0) {
    Line "  未找到 spoolsv 的崩溃报告"
} else {
    Line "  找到 $($werDirs.Count) 份报告："
    foreach ($d in $werDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 5) {
        Line "    $($d.LastWriteTime)  $($d.Name)"
    }
}
Line ""

# ---------- 5. 打印池残留 ----------
Line "[5/5] 打印池残留文件"
$spool = "$env:SystemRoot\System32\spool\PRINTERS"
$files = @(Get-ChildItem $spool -Force -ErrorAction SilentlyContinue)
Line "  文件数: $($files.Count)"
$tmpSizes = @($files | Where-Object { $_.Name -like 'PP*.TMP' -and $_.Length -gt 0 } | Select-Object -ExpandProperty Length -Unique)
if ($tmpSizes.Count -gt 0) {
    Line "  非零临时文件大小: $($tmpSizes -join ', ') 字节"
    if ($tmpSizes.Count -eq 1 -and $tmpSizes[0] -lt 20000) {
        Line "  >> 多次失败留下完全相同的小文件 —— 符合「作业刚开头就中断」的特征" -ForegroundColor Yellow
    }
}
Line ""

# ---------- 结论 ----------
Line "=============================================="
if ($hit -ge 2) {
    Line " 结论：命中本问题" -ForegroundColor Red
    Line ""
    Line " spoolsv.exe 被替换成了非原厂版本，打印到 PDF 时崩溃。"
    Line " 请运行 fix-print-to-pdf-0kb.ps1 修复。"
} elseif ($hit -eq 1) {
    Line " 结论：部分符合" -ForegroundColor Yellow
    Line ""
    Line " 有异常迹象但证据不完整。请把本窗口内容反馈给作者。"
} else {
    Line " 结论：未命中本问题" -ForegroundColor Green
    Line ""
    Line " spoolsv.exe 完整、无非法指令崩溃。你的 0KB 问题另有原因，"
    Line " 本仓库的方案对你不适用。可尝试改用 PDF24 等其他虚拟打印机。"
}
Line "=============================================="
Line ""
Read-Host "按回车键关闭窗口"
