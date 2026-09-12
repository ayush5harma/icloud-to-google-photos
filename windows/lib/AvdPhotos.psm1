# The Windows port's one module. Every part is a .ps1 beside this file,
# dot-sourced into ONE module scope so a test can mock a function the others
# call (Invoke-AvdAdb above all) with a single -ModuleName. Core first: the
# other parts call it at load time and at run time.
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot 'Core.ps1')
Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' |
    Where-Object { $_.Name -ne 'Core.ps1' } |
    Sort-Object -Property Name -Culture ([cultureinfo]::InvariantCulture) |
    ForEach-Object { . $_.FullName }

Export-ModuleMember -Function '*'
