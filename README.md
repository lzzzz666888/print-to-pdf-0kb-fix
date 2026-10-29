# Microsoft Print to PDF 输出 0KB 修复

> 症状：任何程序打印到「Microsoft Print to PDF」，生成的 PDF 永远是 **0 字节**。打印机状态显示 Normal，队列里没有报错，Windows 也不弹任何提示。

本仓库针对其中一种**特定且可确诊**的原因：`C:\Windows\System32\spoolsv.exe` 被替换成非原厂版本，在处理 PDF 打印作业时因非法指令崩溃（`0xc000001d`）。

**先跑诊断脚本确认你是不是同一个问题**，不是所有 0KB 都是这个原因。

---

## 快速判断

以管理员身份运行 `diagnose-print-to-pdf.ps1`，或手动执行：

```powershell
# 1. 对比 spoolsv.exe 与系统组件库原件
Get-FileHash "$env:SystemRoot\System32\spoolsv.exe" -Algorithm SHA256
Get-ChildItem "$env:SystemRoot\WinSxS" -Directory -Filter 'amd64_microsoft-windows-printing-spooler-core_*' |
  ForEach-Object { Get-FileHash (Join-Path $_.FullName 'spoolsv.exe') -Algorithm SHA256 }
```

如果两个哈希**不一致**，就是本仓库要解决的问题。

再确认崩溃记录：

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 50 |
  Where-Object { $_.Message -match 'spoolsv' } |
  Select-Object TimeCreated, Message
```

命中本问题时，会看到：

```
出错应用程序名称： spoolsv.exe，版本： 10.0.26100.8246
出错模块名称： spoolsv.exe
异常代码： 0xc000001d          ← STATUS_ILLEGAL_INSTRUCTION
错误偏移： 0x0000000000028b44
```

---

## 修复

以管理员身份运行 `fix-print-to-pdf-0kb.ps1`（右键 → 使用 PowerShell 运行 → UAC 点「是」）。

脚本会：

1. 定位 `WinSxS` 里的原厂 `spoolsv.exe`
2. 备份当前文件到桌面时间戳目录
3. 停止 Print Spooler，用原件覆盖 `System32\spoolsv.exe`（拒绝访问时自动 `takeown` + `icacls`）
4. 启动服务，**自动打印一张测试页**，校验输出是否为合法 PDF（文件头 `%PDF-`、结尾 `%%EOF`）
5. 校验失败会自动还原备份，不会把你留在更糟的状态

修复成功的输出：

```
测试输出 : 810 字节   文件头=%PDF-   结尾=%%EOF   有效PDF=True
无新崩溃
================  修复成功  ================
```

> 810 字节是正常的——空白测试页的 PDF 就是这么小。判断成功**不能看体积**。

---

## 根因

### 为什么会是 0 字节，而不是报错

打印流程是：

1. 你点打印 → 端口监视器**先**把目标文件创建出来（此刻 0 字节）
2. spooler 渲染内容，再往文件里写
3. 渲染崩溃 → 第 1 步建的空文件留在原地

而 Windows 会在 5 秒后自动重启 Print Spooler 服务。所以打印机列表里状态永远是 `Normal`、队列 `0 个作业`，看起来一切正常，只有 PDF 是空的，全程没有任何弹窗。

### 崩溃发生在最开头

打印池目录 `C:\Windows\System32\spool\PRINTERS` 里，每次失败的作业都会留下一个临时文件，大小精确相同：

| 日期 | 临时文件 |
|---|---|
| 8/26 20:57 | 9143 字节 |
| 8/27 15:22 | 9143 字节 |
| 9/29 21:05 | 9143 字节 |
| 10/29 11:40 | 9143 字节 |

同样的字节数 = 同样的内容 = 只写了个文件头就断了，页面数据一个字节都没进来。

### 坏在哪个文件

```
System32\spoolsv.exe   SHA256 4C9FAAC3...   版本字符串 10.0.26100.9949   固定版本 8246
WinSxS 原件            SHA256 22C017CF...   版本字符串 10.0.26100.8246   固定版本 8246
```

两个文件大小都是 983040 字节，内容却不同。而且前者**版本字符串和固定版本自相矛盾**——正常的 Windows 系统文件不会这样。

崩溃模块是 `spoolsv.exe` 自己，偏移 `0x28b44` 固定不变，异常码 `0xc000001d`（非法指令）。这是代码字节被破坏或篡改的典型特征：每次执行到那段坏代码就立刻崩，所以行为完全可复现。

WER 归档里的多份崩溃报告签名哈希完全相同（`58b2548...09e7e14a`），说明是同一个持续性故障，不是偶发。

### 为什么用 SFC 修不好

`sfc /scannow` 校验的是文件与组件库的一致性，但在这个案例里，系统可能因为组件服务事务挂起（`CBS RebootPending = True`）而无法完成修复。本仓库的做法是直接从 `WinSxS` 取原件覆盖，等价于 SFC 的修复动作，但更直接。

---

## 排查过程中容易踩的坑

这些方向都被实测排除了，列出来帮你少走弯路：

| 常见猜测 | 实际情况 |
|---|---|
| 打印队列卡死 | `Remove-PrintJob` 清空后依旧 0KB |
| 缺少 `PDFRenderFilter.dll` | 补齐 ntprint4 的 9 个渲染组件后依旧 0KB |
| `DEVMODE` 配置损坏 | 删除 `Default DevMode` 让它重建后依旧 0KB |
| v4 驱动目录丢失 | 路径搞错了——v4 队列配置在 `spool\V4Dirs\<GUID>\`，不是 `spool\drivers\x64\3\<GUID>`，且目录本来就完整 |
| 磁盘空间不足 | C 盘剩 21GB，无关 |
| 32 位程序兼容性 | 64 位程序打印同样 0KB，无关 |

**关键教训**：先用 WER 崩溃报告定位「哪个进程崩了」，比猜配置快得多。

另一个坑：验证 PDF 是否成功**不能用字节数阈值**。空白测试页只有 810 字节，用 `-gt 1000` 判断会把成功误判成失败，甚至触发回滚。应该校验文件头 `%PDF-` 和结尾 `%%EOF`。

---

## 手动修复（不想跑脚本）

```powershell
# 以管理员身份运行
$dst = "$env:SystemRoot\System32\spoolsv.exe"
$src = (Get-ChildItem "$env:SystemRoot\WinSxS" -Directory -Filter 'amd64_microsoft-windows-printing-spooler-core_*' |
        ForEach-Object { Join-Path $_.FullName 'spoolsv.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1)

Copy-Item $dst "$env:USERPROFILE\Desktop\spoolsv.exe.bak" -Force
Stop-Service Spooler -Force
takeown /f $dst /a
icacls $dst /grant "*S-1-5-32-544:(F)"
Copy-Item $src $dst -Force
Start-Service Spooler
```

---

## 适用范围与风险

- 仅适用于 **x64 Windows 10 / 11**
- 仅适用于**确诊为 `spoolsv.exe` 哈希与组件库不一致**的情况；其他原因的 0KB 不在本方案范围内
- 脚本会在替换前备份，自检失败自动回滚
- 修改系统文件属于高风险操作，请自行评估。建议先创建系统还原点

### 修复可能失效的情况

Windows 更新如果重新安装了那个有问题的版本，故障可能复发。届时再跑一次脚本即可（检测到已是原厂文件会跳过替换，只做自检）。

---

## 许可

MIT
