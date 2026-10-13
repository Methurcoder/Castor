# Packaged with the Windows app. Select a Mac-made pet without command line arguments.
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$pet = Join-Path $PSScriptRoot 'CastorPet.json'
if (-not (Test-Path -LiteralPath $pet)) { $pet = Join-Path $PSScriptRoot 'PomegranatePet.json' }
if (-not (Test-Path -LiteralPath $pet)) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select a pet built with Arils on a Mac'
    $dialog.Filter = 'Arils pet (*.json;*.arils)|*.json;*.arils'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $pet = $dialog.FileName
    $dialog.Dispose()
}
& (Join-Path $PSScriptRoot 'CastorPet.exe') $pet
exit $LASTEXITCODE
