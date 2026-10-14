$ErrorActionPreference='Stop'
$miktex=Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX\miktex\bin\x64'
$pdf=Join-Path $miktex 'pdflatex.exe'
$biber=Join-Path $miktex 'biber.exe'
if(-not (Test-Path -LiteralPath $pdf)){throw 'MiKTeX mit pdflatex und biber wird benötigt.'}
Push-Location $PSScriptRoot
try {
  New-Item -ItemType Directory -Path 'build' -Force | Out-Null
  & $pdf '-interaction=nonstopmode' '-halt-on-error' '-output-directory=build' 'main.tex'
  if($LASTEXITCODE -ne 0){throw 'Erster LaTeX-Lauf fehlgeschlagen.'}
  & $biber '--input-directory=build' '--output-directory=build' 'main'
  if($LASTEXITCODE -ne 0){throw 'Literaturverzeichnis konnte nicht erstellt werden.'}
  & $pdf '-interaction=nonstopmode' '-halt-on-error' '-output-directory=build' 'main.tex'
  if($LASTEXITCODE -ne 0){throw 'Zweiter LaTeX-Lauf fehlgeschlagen.'}
  & $pdf '-interaction=nonstopmode' '-halt-on-error' '-output-directory=build' 'main.tex'
  if($LASTEXITCODE -ne 0){throw 'Abschließender LaTeX-Lauf fehlgeschlagen.'}
  Copy-Item -LiteralPath 'build/main.pdf' -Destination 'Informationsvisualisierung.pdf' -Force
  Write-Host 'Bericht: Bericht/Informationsvisualisierung.pdf'
} finally {Pop-Location}
