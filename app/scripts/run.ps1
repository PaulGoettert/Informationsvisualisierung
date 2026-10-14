param([ValidateSet('build','dev','test:browser','test:year','test:profiles','test:comparison','test:usecases','format','format:check')][string]$Task='dev')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolDir=Join-Path $root '.tools'
$nodeRoot=Get-ChildItem -LiteralPath $toolDir -Directory -Filter 'node-v24*-win-x64' | Select-Object -First 1
if(-not $nodeRoot){throw 'Run scripts/setup.ps1 first, or use your own Node/Elm installation.'}
$env:PATH=$nodeRoot.FullName+';'+$env:PATH
$env:ELM_HOME=Join-Path $toolDir 'elm-home'
$env:PLAYWRIGHT_BROWSERS_PATH=Join-Path $toolDir 'browsers'
Push-Location (Join-Path $root 'app')
try { & (Join-Path $nodeRoot.FullName 'npm.cmd') run $Task; if($LASTEXITCODE -ne 0){throw ('Task failed: '+$Task)} } finally {Pop-Location}
