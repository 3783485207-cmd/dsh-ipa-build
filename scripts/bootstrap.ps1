# Windows 这边的一次性安装。跑完就有编译器和签名器，不需要你再手动装任何东西。
# SDK 和 zsign 都在 vendor 里，直接从插件里拿；编译器没有的话脚本自己去搞。

param(
    # 只从 GitHub 官方 release 下。第三方加速代理能改文件内容，不在这里留位置；
    # 慢就自己挂代理，别换源
    [string[]]$LlvmUrl = @(
        'https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-pc-windows-msvc.tar.xz'
    ),
    # 上面那份 18.1.8 的 sha256，实测校验过（936MB，下完 tar -tJf 能完整列出）
    # 注意：这个值写死就等于“只认这一个包”，如果上游换了 18.1.8 的构建产物，安装会被一直拒绝。
    # 换机或换网络重下时若报对不上，先核对 size 981666720 与 tar 列表，再确认是不是上游换了包，别直接改这个数。
    # 待办：在一台干净 Windows 机上完整跑一次 bootstrap.ps1 复核这个锚点。
    # 换 URL 的话这个哈希也要跟着换，不然会被判成"文件不对"
    [string]$LlvmSha = '22c5907db053026cc2a8ff96d21c0f642a90d24d66c23c6d28ee7b1d572b82e8'
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

# 只改当前会话和工具链自己的 env.ps1，不动用户的持久 PATH：
# 永久把某个 LLVM 前置到 PATH 会盖掉用户原来装的 clang，卸载插件也还原不回来
function Use-Path($bin) {
    $env:PATH = "$bin;$env:PATH"
    $envFile = Join-Path $tc 'env.ps1'
    $line = '$env:PATH = "' + $bin + ';" + $env:PATH'
    [IO.File]::WriteAllText($envFile, $line + [Environment]::NewLine)
    Write-Host "要常驻的话自己加：$line"
}

function Get-FileSha256($path) { (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower() }

# 校验一个已有的归档：tar 能完整列出内容才算真的下全了。
# 只看 "> 300MB" 会把半截文件也当成好的，续传拼错的文件更是过不了这一步
function Test-Archive($path) {
    if (-not (Test-Path $path)) { return $false }
    & tar.exe -tJf $path *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-LlvmArchive($dest) {
    $hashFile = Join-Path $tc 'llvm.sha256'
    $expect = if ($LlvmSha) { $LlvmSha.Trim().ToLower() }
              elseif (Test-Path $hashFile) { (Get-Content $hashFile -Raw).Trim() }
              else { $null }
    foreach ($u in $LlvmUrl) {
        Write-Host "下载编译器：$u"
        # 不带 --continue-at：不支持 Range 的源会把文件拼坏，重下整份更稳
        & curl.exe -L --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 15 -o ($dest + '.part') $u
        if ($LASTEXITCODE -ne 0) { Write-Host "下载没成功，换下一个源"; continue }
        Move-Item ($dest + '.part') $dest -Force
        if (-not (Test-Archive $dest)) { Write-Host "下下来的包解不开，当没下成（多半是没下全或者被换过）"; Remove-Item $dest -Force; continue }
        $sha = Get-FileSha256 $dest
        Write-Host "sha256 $sha"
        # 上游只发 GPG 签名、没有官方 sha256，所以这里用实测过的固定哈希做锚点：
        # 只要不是这个值就直接拒绝，第一次下载也不会盲信
        if ($expect -and $sha -ne $expect) { Write-Host "sha256 对不上（应为 $expect，实际 $sha），文件被换过或没下全，丢掉重试"; Remove-Item $dest -Force; continue }
        if (-not $expect) { Set-Content -Path $hashFile -Value $sha -Encoding utf8 }
        return $true
    }
    return $false
}

# SDK：vendor 里的包已经把 .tbd 软链展开成真文件了，Windows 解包不会再出空文件
$sdkDir = Join-Path $tc 'sdk/iPhoneOS16.5.sdk'
$SdkSha = '1d55ed9e66a37c0e6813c5be29df6f64f1ce448f58911a6cb87db07d5f6b8c58'
$ZsignSha = 'abc1087da5a410c42fdbb8e90049802c2cc6c03fcd0ebb6d5c315b17f6d26a87'
function Assert-Sha($path, $want, $what) {
    if (-not (Test-Path $path)) { return }
    $got = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { Write-Host "$what 的 sha256 对不上（$got，应为 $want），文件被换过或没下全"; exit 1 }
}

if (-not (Test-Path $sdkDir)) {
    $archive = Join-Path $root 'vendor/iPhoneOS16.5.sdk.tar.xz'
    if (-not (Test-Path $archive)) { Write-Host "vendor 里没有 SDK 包，插件不完整"; exit 1 }
    Assert-Sha $archive $SdkSha 'vendor/iPhoneOS16.5.sdk.tar.xz' 
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
    if (Test-Path $srcZs) { Assert-Sha $srcZs $ZsignSha 'vendor/zsign/zsign.exe'; Copy-Item $srcZs $zs -Force }
    else { Write-Host "vendor 里没有 zsign.exe，签不了名" }
}

# 编译器：找得到就用，找不到就装上
$bin = Find-Llvm
if ($bin) {
    Write-Host "编译器在 $bin"
    Use-Path $bin
} else {
    $dl = Join-Path $tc 'llvm.tar.xz'
    $ok = $false
    if (Test-Archive $dl) { $ok = $true }
    if (-not $ok) { $ok = Get-LlvmArchive $dl }

    if (-not $ok) {
        # 官方源和镜像都不通时，试试 winget；装完位置不固定，再找一圈
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host "下载不通，用 winget 装"
            & winget install --id LLVM.LLVM -e --silent --accept-package-agreements --accept-source-agreements
            $bin = Find-Llvm
            if ($bin -and (Test-Path (Join-Path $bin 'clang.exe'))) {
                $ver = & (Join-Path $bin 'clang.exe') --version 2>$null | Select-Object -First 1
                Write-Host "winget 装的编译器：$ver"
                if ($ver -notmatch 'version 1[0-9]|version 2[0-9]') { Write-Host "版本跟预期差得远，编 iOS 可能出怪问题" }
            }
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
