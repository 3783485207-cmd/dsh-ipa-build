# Windows 这边的 bootstrap。SDK 和 zsign 都在 vendor 里，解包 / 拷贝就行；
# clang 得自己装（脚本会先找一圈，找不到再问你要不要下 LLVM）。

param(
    [string]$LlmUrl = 'https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-pc-windows-msvc.tar.xz',
    [switch]$WithLlvm
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if ($env:IPA_HOME) { $tc = $env:IPA_HOME } else { $tc = Join-Path $env:USERPROFILE '.ipa-toolchain' }

New-Item -ItemType Directory -Path $tc -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tc 'bin') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tc 'sdk') -Force | Out-Null
Write-Host "装到 $tc"

# SDK：vendor 里是 tar.xz，Windows 自带的 tar（bsdtar）能吃 xz
$sdkDir = Join-Path $tc 'sdk\iPhoneOS16.5.sdk'
if (-not (Test-Path $sdkDir)) {
    $archive = Join-Path $root 'vendor\iPhoneOS16.5.sdk.tar.xz'
    if (-not (Test-Path $archive)) { Write-Host "vendor 里没有 SDK 包"; exit 1 }
    Write-Host "解包 SDK，两百多 MB，等一会儿"
    & tar.exe -xJf $archive -C (Join-Path $tc 'sdk')
    if (-not (Test-Path $sdkDir)) { Write-Host "解包失败，检查 tar.exe 在不在"; exit 1 }
}

# zsign：Windows 上没有 ldid，用这个做伪签名
$zs = Join-Path $tc 'bin\zsign.exe'
$srcZs = Join-Path $root 'vendor\zsign\zsign.exe'
if (-not (Test-Path $zs)) {
    if (Test-Path $srcZs) { Copy-Item $srcZs $zs -Force } else { Write-Host "vendor 里没有 zsign.exe" }
}

# clang：PATH 里有就用，没有的话这里只能提示，不替你硬下 936MB
$clang = Get-Command clang.exe -ErrorAction SilentlyContinue
$lld = Get-Command ld64.lld.exe -ErrorAction SilentlyContinue

if (-not $clang -or -not $lld) {
    $llvmBin = Join-Path $tc 'llvm\bin'
    if (-not (Test-Path (Join-Path $llvmBin 'clang.exe')) -and $WithLlvm) {
        $dl = Join-Path $tc 'llvm.tar.xz'
        Write-Host "下 LLVM（约 936MB），断了几次的话重跑这个脚本接着下"
        & curl.exe -L --retry 3 --retry-delay 5 -o $dl $LlmUrl
        if ($LASTEXITCODE -eq 0) {
            Write-Host "解压 LLVM"
            New-Item -ItemType Directory -Path (Join-Path $tc 'llvm_unpack') -Force | Out-Null
            & tar.exe -xJf $dl -C (Join-Path $tc 'llvm_unpack')
            $inner = Get-ChildItem (Join-Path $tc 'llvm_unpack') -Directory | Select-Object -First 1
            if ($inner) { Move-Item $inner.FullName (Join-Path $tc 'llvm') -Force }
            Remove-Item $dl -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "下载没成（这台机器上 GitHub 的 release 经常超时），改用手动装："
            Write-Host "  winget install LLVM.LLVM    或者去 llvm.org 下 Windows 版"
        }
    }
    if (Test-Path (Join-Path $llvmBin 'clang.exe')) {
        $env:PATH = "$llvmBin;$env:PATH"
        Write-Host "用 $tc\llvm 里的 clang"
    }
}

& (Join-Path $here 'ipa.ps1') doctor

Write-Host ""
if ((Get-Command clang.exe -ErrorAction SilentlyContinue) -and (Get-Command ld64.lld.exe -ErrorAction SilentlyContinue)) {
    Write-Host "源码编译这条路能走。试一下："
    Write-Host "  scripts\ipa.ps1 build examples\HelloApp --name HelloApp --bundle-id com.example.helloapp"
} else {
    Write-Host "这台机器没有 clang，源码编不了，但这两件事照做："
    Write-Host "  scripts\ipa.ps1 pack   某个.app -o out.ipa     把现成的 app 打成安装包"
    Write-Host "  scripts\ipa.ps1 resign 某个.ipa -o out.ipa     已有的包重新签"
    Write-Host "要编源码就装 LLVM（带 ld64.lld），或者 wsl --install 之后让 build 借 WSL 跑。"
}
