Param(
  [string]$drive_desti
)

if ([string]::IsNullOrEmpty($line) -Or ($drive_desti -match '^\s*$')) {
  write-host "Destino não fornecido!"
  exit
}

$drive_desti = $drive_desti.trim()

if (-Not ($drive_desti -match '^[c-z]\:\?$')) {
  write-host "Destino não fornecido!"
  exit
}

if (-Not (Test-Path "$drive_desti")) {
  write-host "Destino não é um caminho existente!"
  exit
}

$source = (get-location).path
$target = "$drive_desti" 

touch $source'initial.initial'
touch $target'initial.initial'

$sourceFiles = Get-ChildItem -Path $source -Recurse
$targetFiles = Get-ChildItem -Path $target -Recurse

$syncMode = 1

try {
  $diff = Compare-Object -ReferenceObject $sourceFiles -DifferenceObject $targetFiles

  foreach ($f in $diff) {
    if ($f.SideIndicator -eq "<=") {
      $fullSourceObject = $f.InputObject.FullName
      $fullTargetObject = $f.InputObject.FullName.Replace($source, $target)

      Write-Host "Attemp to copy the following: " $fullSourceObject
      Copy-Item -Path $fullSourceObject -Destination $fullTargetObject
    }

    if ($f.SideIndicator -eq "=>" -and $syncMode -eq 2) {
      $fullSourceObject = $f.InputObject.FullName
      $fullTargetObject = $f.InputObject.FullName.Replace($target, $source)

      Write-Host "Attemp to copy the following: " $fullSourceObject
      Copy-Item -Path $fullSourceObject -Destination $fullTargetObject
    }
  }
}      
catch {
  Write-Error -Message "something bad happened!" -ErrorAction Stop
}

Remove-Item $source'initial.initial'
Remove-Item $target'initial.initial'