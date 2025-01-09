Param(
  [string]$drive_desti
)

if ([string]::IsNullOrEmpty($drive_desti) -Or ($drive_desti -match '^\s*$')) {
  write-host "Destino não fornecido!"
  exit
}

$drive_desti = $drive_desti.trim()

if (-Not ("$drive_desti" -match '^[c-z]:?$')) {
  write-host "Destino fornecido não é valido! Deve ser letra da unidade seguida por ':'. Fornecido '$drive_desti'"
  exit
}

if (-Not (Test-Path "$drive_desti")) {
  write-host "Destino não é um caminho existente!"
  exit
}

$source = (get-location).path
$target = "$drive_desti"

try {
  Robocopy "$source\" "$target\" /MIR /FFT /S /Z /XA:H /W:7 /xd [".git", "*.log"]
}
catch {
  Write-Error -Message "something bad happened!" -ErrorAction Stop
}
