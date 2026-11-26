# Windows 这边的一次性安装。跑完就有编译器和签名器，不需要你再手动装任何东西。
# SDK 和 zsign 都在 vendor 里，直接从插件里拿；编译器没有的话脚本自己去搞。

param(
    [string[]]$LlvmUrl = @(
        'https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-pc-windows-msvc.tar.xz',
        'https://ghfast.top/https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-pc-windows-msvc.tar.xz',
        'https://gh-proxy.com/https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-pc-windows-msvc.tar.xz'
    )
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if ($env:IPA_HOME) { $tc = $env:IPA_HOME }
elseif ($env:USERPROFILE) { $tc = Join-Path $env:USERPROFILE '.ipa-toolchain' }
else { $tc = Join-Path $HOME '.ipa-toolchain' }

foreach ($d in @($tc, (Join-Path $tc 'bin'), (Join-Path $tc 'sdk'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
Write-Host "装到 $tc"

function Test-Llvm($bin) { (Test-Path (Join-Path $bin 'clang.exe')) -and (Test-Path (Join-Path $bin 'ld64.lld.exe')) }

# 已有的 LLVM 先认出来，不重复下。PATH 里没有但装过的情况很常见，winget 装完就这样。
function Find-Llvm {
    $c = Get-Command clang.exe -ErrorAction SilentlyContinue
    $l = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue
    if ($c -and $l) { return (Split-Path -Parent $c.Source) }
    $cand = @(
        (Join-Path $tc 'llvm/bin'),
        'C:\Program Files\LLVM\bin',
        'C:\Program Files (x86)\LLVM\bin',
        (Join-Path $env:LOCALAPPDATA 'Programs/LLVM/bin')
    )
    foreach ($p in $cand) { if ($p -and (Test-Llvm $p)) { return $p } }
    return $null
}

function Use-Path($bin) {
    $env:PATH = "$bin;$env:PATH"
    $old = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($old -and -not $old.Contains($bin)) {
        [Environment]::SetEnvironmentVariable('Path', "$bin;$old", 'User')
    }
}

function Get-LlvmArchive($dest) {
    foreach ($u in $LlvmUrl) {
        Write-Host "下载编译器：$u"
        # --continue-at - 让断掉的下载接着走，重跑脚本不用从头再来
        & curl.exe -L --retry 5 --retry-delay 5 --retry-all-errors --continue-at - --connect-timeout 15 -o $dest $u
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dest) -and ((Get-Item $dest).Length -gt 300MB)) { return $true }
        Write-Host "这个源没成，换下一个"
    }
    return $false
}

# SDK：vendor 里的包已经把 .tbd 软链展开成真文件了，Windows 解包不会再出空文件
$sdkDir = Join-Path $tc 'sdk/iPhoneOS16.5.sdk'
if (-not (Test-Path $sdkDir)) {
    $archive = Join-Path $root 'vendor/iPhoneOS16.5.sdk.tar.xz'
    if (-not (Test-Path $archive)) { Write-Host "vendor 里没有 SDK 包，插件不完整"; exit 1 }
    Write-Host "解包 SDK"
    & tar.exe -xJf $archive -C (Join-Path $tc 'sdk')
    if (-not (Test-Path $sdkDir)) { Write-Host "SDK 解包失败，看看 tar.exe 能不能用"; exit 1 }
}

# 万一以后换了旧包，这里扫一遍：.tbd 小得像一行文件名，说明是没展开的软链，按名字补成真文件
$tbds = Get-ChildItem $sdkDir -Recurse -Filter '*.tbd' -File -ErrorAction SilentlyContinue
$fixed = 0
foreach ($t in $tbds) {
    if ($t.Length -gt 300) { continue }
    $txt = (Get-Content $t.FullName -Raw -ErrorAction SilentlyContinue)
    if ($txt -eq $null) { continue }
    $txt = $txt.Trim()
    if ($txt -match '^[\w\.\+\-]+\.tbd$') {
        $target = Join-Path $t.DirectoryName $txt
        if ((Test-Path $target) -and ((Get-Item $target).Length -gt $t.Length)) {
            Copy-Item $target $t.FullName -Force
            $fixed++
        }
    }
}
if ($fixed -gt 0) { Write-Host "补了 $fixed 个没展开的 .tbd" }

# zsign：Windows 上没有 ldid，签名全靠它
$zs = Join-Path $tc 'bin/zsign.exe'
if (-not (Test-Path $zs)) {
    $srcZs = Join-Path $root 'vendor/zsign/zsign.exe'
    if (Test-Path $srcZs) { Copy-Item $srcZs $zs -Force } else { Write-Host "vendor 里没有 zsign.exe，签不了名" }
}

# 编译器：找得到就用，找不到就装上
$bin = Find-Llvm
if ($bin) {
    Write-Host "编译器在 $bin"
    Use-Path $bin
} else {
    $dl = Join-Path $tc 'llvm.tar.xz'
    $ok = $false
    if ((Test-Path $dl) -and ((Get-Item $dl).Length -gt 300MB)) { $ok = $true }
    if (-not $ok) { $ok = Get-LlvmArchive $dl }

    if (-not $ok) {
        # 官方源和镜像都不通时，试试 winget；装完位置不固定，再找一圈
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host "下载不通，用 winget 装"
            & winget install --id LLVM.LLVM -e --silent --accept-package-agreements --accept-source-agreements
            $bin = Find-Llvm
        }
    } elseif ($ok) {
        Write-Host "解压编译器"
        $unpack = Join-Path $tc 'llvm_unpack'
        if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
        New-Item -ItemType Directory -Path $unpack -Force | Out-Null
        & tar.exe -xJf $dl -C $unpack
        $inner = Get-ChildItem $unpack -Directory | Select-Object -First 1
        if ($inner) {
            if (Test-Path (Join-Path $tc 'llvm')) { Remove-Item (Join-Path $tc 'llvm') -Recurse -Force }
            Move-Item $inner.FullName (Join-Path $tc 'llvm') -Force
        }
        Remove-Item $unpack -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $dl -Force -ErrorAction SilentlyContinue
        $bin = Find-Llvm
    }

    if ($bin) { Use-Path $bin; Write-Host "编译器好了：$bin" }
    else { Write-Host "编译器没装上，网络问题，重跑一次 scripts\bootstrap.ps1 会接着下。pack / resign 不用编译器，现在就能用。" }
}

& (Join-Path $here 'ipa.ps1') doctor
