# Packaged app entry: native Castor handles first-time creation and saved-pet selection.
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
& (Join-Path $PSScriptRoot 'CastorPet.exe')
exit $LASTEXITCODE
