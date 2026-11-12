<#
.SYNOPSIS
跨机器Android构建入口，使用仓库Gradle Wrapper，不写用户级配置。
.EXAMPLE
./scripts/android/Build-Android.ps1 -Target Check
.EXAMPLE
./scripts/android/Build-Android.ps1 -Target Test -Abi x86_64 -Isolated
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Debug','Test','DeviceTestApk','Release')][string]$Target='Check',
    [ValidateSet('arm64-v8a','x86_64')][string]$Abi='arm64-v8a',
    [string]$JavaHome=$env:JAVA_HOME,
    [string]$SdkRoot=$env:ANDROID_HOME,
    [string]$GradleHome=$env:GRADLE_USER_HOME,
    [string]$SigningCredentialPath,
    [switch]$Isolated,
    [switch]$Offline,
    [switch]$RequireReleaseKey
)
$ErrorActionPreference='Stop'
# 正式构建默认要求专用证书；兼容既有调用中的显式开关。
if ($Target -eq 'Release') { $RequireReleaseKey=$true }
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$gradleRoot=Join-Path $repositoryRoot 'android/src/android'
if (-not $SdkRoot) { $SdkRoot=$env:ANDROID_SDK_ROOT }
if (-not $JavaHome) { throw '请设置JAVA_HOME或传入-JavaHome，使用JDK21。' }
if (-not $SdkRoot) { throw '请设置ANDROID_HOME或传入-SdkRoot。' }
$java=Join-Path $JavaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $java)) { $java=Join-Path $JavaHome 'bin/java' }
if (-not (Test-Path -LiteralPath $java)) { throw '指定目录不存在Java可执行文件。' }
$required=@(
    'LICENSE',
    'android/src/android/gradle/wrapper/gradle-wrapper.jar',
    'android/src/android/app/src/main/cpp/cppjieba/include/cppjieba/Jieba.hpp',
    'android/src/android/app/src/main/assets/nanomuse/providers.json',
    'android/src/android/app/src/main/assets/jieba/jieba.dict.utf8',
    'android/src/android/app/libs/rclone.aar'
)
if ($Abi -eq 'arm64-v8a') {
    $required+='android/src/android/app/src/main/assets/proot-aarch64'
    # RootfsManager同时支持压缩包和未压缩tar，匹配运行时的真实输入。
    $rootfsBase='android/src/android/app/src/main/assets/alpine-minirootfs.tar'
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $rootfsBase))) {
        $required+="$rootfsBase.gz"
    }
}
$missing=@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repositoryRoot $_)) })
$sdkMissing=@('platforms/android-36/android.jar','ndk/27.2.12479018','cmake/3.22.1') |
    Where-Object { -not (Test-Path -LiteralPath (Join-Path $SdkRoot $_)) }
if ($missing.Count -or $sdkMissing.Count) {
    $missing | ForEach-Object { Write-Host "缺少项目输入：$_" }
    $sdkMissing | ForEach-Object { Write-Host "缺少SDK组件：$_" }
    throw '构建前检查未通过。参见docs/android-development.md；原生依赖需先用Linux/WSL构建。'
}
if ($Target -eq 'Release' -and $Abi -ne 'arm64-v8a') { throw '此入口只交付arm64正式包；x86_64用于隔离测试。' }
if ($RequireReleaseKey -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'android/keystore.properties'))) {
    throw '缺少正式签名配置，拒绝以Debug密钥发布。'
}
Write-Host '构建输入检查通过。'
& $java -version
if ($LASTEXITCODE -ne 0) { throw 'Java验证失败。' }
if ($Target -eq 'Check') { return }
$previous=@{}
@('JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','GRADLE_USER_HOME','NICHOLASX_STORE_PASSWORD','NICHOLASX_KEY_PASSWORD') | ForEach-Object {
    $previous[$_]=[Environment]::GetEnvironmentVariable($_,'Process')
}
Push-Location -LiteralPath $gradleRoot
try {
    if ($SigningCredentialPath) {
        $credential=Import-Clixml -LiteralPath $SigningCredentialPath
        if ($credential -isnot [PSCredential]) { throw '签名凭据格式错误。' }
        $env:NICHOLASX_STORE_PASSWORD=$credential.GetNetworkCredential().Password
        $env:NICHOLASX_KEY_PASSWORD=$env:NICHOLASX_STORE_PASSWORD
    }
    $env:JAVA_HOME=$JavaHome
    $env:ANDROID_HOME=$SdkRoot
    $env:ANDROID_SDK_ROOT=$SdkRoot
    if ($GradleHome) { $env:GRADLE_USER_HOME=$GradleHome }
    $arguments=@('--no-daemon','--console=plain','--max-workers=2',"-Pnm.abi=$Abi")
    if ($Offline) { $arguments+='--offline' }
    if ($RequireReleaseKey) { $arguments+='-Pnm.requireReleaseKey=true' }
    if ($Isolated) { $arguments+='-Pnm.uiTest=true' }
    switch ($Target) {
        Debug { $arguments+=':app:assembleDebug' }
        DeviceTestApk { $arguments+=@(':app:assembleDebug',':app:assembleDebugAndroidTest') }
        Release { $arguments+=':app:assembleRelease' }
        Test { $arguments+=@(':app:testDebugUnitTest','--tests','io.github.nanomuse.*',
            '--tests','com.openminis.app.provider.*','--tests','com.openminis.app.sandbox.*',
            '--tests','com.openminis.app.ui.chat.*','--tests','com.openminis.app.ui.sessions.*') }
    }
    & $java -classpath 'gradle/wrapper/gradle-wrapper.jar' org.gradle.wrapper.GradleWrapperMain @arguments
    if ($LASTEXITCODE -ne 0) { throw "Gradle构建失败：$LASTEXITCODE" }
    Write-Host "构建完成。产物目录：$(Join-Path $gradleRoot 'app/build/outputs')"
} finally {
    Pop-Location
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
}
