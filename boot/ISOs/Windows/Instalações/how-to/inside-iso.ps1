$Env:install_cru = ""

$script = "c:\autonomo-install.ps1"

Remove-Item "$script" -Force
Invoke-WebRequest "https://raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/ISOs/Windows/Instala%C3%A7%C3%B5es/how-to/autounattend.ps1" -OutFile "$script"

try {
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath '$script' -Raw | Invoke-Expression; "
}
catch {  
}

Remove-Item "$script" -Force