$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolDir=Join-Path $root '.tools'
New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
$nodeRoot=Get-ChildItem -LiteralPath $toolDir -Directory -Filter 'node-v24*-win-x64' | Select-Object -First 1
if (-not $nodeRoot) {
    $base='https://nodejs.org/dist/latest-v24.x/'
    $checks=Invoke-WebRequest -UseBasicParsing -Uri ($base+'SHASUMS256.txt') -TimeoutSec 40
    $match=[regex]::Match($checks.Content,'(?m)^([a-f0-9]{64})\s+(node-v24[^\s]*-win-x64\.zip)\s*$')
    if(-not $match.Success){throw 'No official Windows x64 archive found'}
    $file=Join-Path $toolDir $match.Groups[2].Value
    Invoke-WebRequest -UseBasicParsing -Uri ($base+$match.Groups[2].Value) -OutFile $file -TimeoutSec 60
    if((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $match.Groups[1].Value){throw 'Node archive checksum mismatch'}
    Expand-Archive -LiteralPath $file -DestinationPath $toolDir -Force
    $nodeRoot=Get-Item -LiteralPath (Join-Path $toolDir ([IO.Path]::GetFileNameWithoutExtension($file)))
}
$env:PATH=$nodeRoot.FullName+';'+$env:PATH
$env:ELM_HOME=Join-Path $toolDir 'elm-home'
$env:PLAYWRIGHT_BROWSERS_PATH=Join-Path $toolDir 'browsers'
Push-Location (Join-Path $root 'app')
try {
    & (Join-Path $nodeRoot.FullName 'npm.cmd') install
    if($LASTEXITCODE -ne 0){throw 'npm install failed'}
    & (Join-Path $nodeRoot.FullName 'node.exe') (Join-Path (Get-Location) 'node_modules\playwright\cli.js') install chromium
    if($LASTEXITCODE -ne 0){throw 'Browser installation failed'}
    & (Join-Path $nodeRoot.FullName 'npm.cmd') run build
    if($LASTEXITCODE -ne 0){throw 'Elm build failed'}
} finally {Pop-Location}
