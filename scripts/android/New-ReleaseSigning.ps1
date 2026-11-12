<#
.SYNOPSIS
在仓库外创建Nicholasx专用签名，并以Windows当前用户加密口令。
.DESCRIPTION
不会覆盖现有证书或配置。凭据XML绑定当前Windows用户与机器，禁止提交或公开分享。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KeyDirectory,
    [string]$JavaHome=$env:JAVA_HOME
)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw '此入口使用Windows凭据加密，请在Windows运行。' }
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$keyRoot=[IO.Path]::GetFullPath($KeyDirectory).TrimEnd('\','/')
if ($keyRoot.Equals($repositoryRoot,[StringComparison]::OrdinalIgnoreCase) -or
    $keyRoot.StartsWith($repositoryRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw '密钥目录必须位于源码仓库之外。'
}
$keytool=Join-Path $JavaHome 'bin/keytool.exe'
if (-not (Test-Path -LiteralPath $keytool)) { throw '未找到JDK的keytool。' }
$config=Join-Path $repositoryRoot 'android/keystore.properties'
if (Test-Path -LiteralPath $config) { throw '已有签名配置，拒绝覆盖。' }
if (Test-Path -LiteralPath $keyRoot) { throw '密钥目录已存在，拒绝覆盖或重复生成。' }
New-Item -ItemType Directory -Path $keyRoot | Out-Null
# 限制新目录访问，不更改任何已有目录的权限。
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$acl=Get-Acl -LiteralPath $keyRoot
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @($identity.User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',
        'ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $keyRoot -AclObject $acl
$keyPath=Join-Path $keyRoot 'nicholasx-release.jks'
$credentialPath=Join-Path $keyRoot 'signing-credential.xml'
$certPath=Join-Path $keyRoot 'nicholasx-release.cer'
$passwordBytes=New-Object byte[] 32
$random=[Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($passwordBytes)
$random.Dispose()
$password=[BitConverter]::ToString($passwordBytes).Replace('-','')
$credential=[PSCredential]::new('nicholasx',(ConvertTo-SecureString $password -AsPlainText -Force))
$credential | Export-Clixml -LiteralPath $credentialPath
$previous=[Environment]::GetEnvironmentVariable('NICHOLASX_KEYTOOL_PASSWORD','Process')
try {
    $env:NICHOLASX_KEYTOOL_PASSWORD=$password
    & $keytool -genkeypair -keystore $keyPath -storetype JKS -alias nicholasx `
        -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 `
        -dname 'CN=Nicholasx, OU=Android Release, O=Nicholasx' `
        -storepass:env NICHOLASX_KEYTOOL_PASSWORD -keypass:env NICHOLASX_KEYTOOL_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw '证书创建失败；保留目录供检查，不自动清理或重建。' }
    & $keytool -exportcert -keystore $keyPath -alias nicholasx -file $certPath `
        -storepass:env NICHOLASX_KEYTOOL_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw '公钥证书导出失败。' }
    # properties中只有路径和别名；口令仅在构建进程环境中短暂存在。
    $storePath=$keyPath.Replace('\','/')
    $configLines=@('# 本机签名配置，不提交。密码由Build-Android.ps1临时注入。',
        "storeFile=$storePath",'keyAlias=nicholasx')
    [IO.File]::WriteAllLines($config,$configLines,[Text.UTF8Encoding]::new($false))
    [ordered]@{key_file=$keyPath;credential_file=$credentialPath;certificate_file=$certPath;
        certificate_sha256=(Get-FileHash -LiteralPath $certPath -Algorithm SHA256).Hash.ToLowerInvariant();
        alias='nicholasx';algorithm='RSA-3072';configuration=$config} | ConvertTo-Json
} finally {
    [Environment]::SetEnvironmentVariable('NICHOLASX_KEYTOOL_PASSWORD',$previous,'Process')
    $password=$null
    $credential=$null
    [Array]::Clear($passwordBytes,0,$passwordBytes.Length)
}
