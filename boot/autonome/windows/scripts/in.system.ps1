powercfg.exe -h off

$params = @{
    Path = 'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';
};
New-Item @params -ErrorAction 'SilentlyContinue';
Set-ItemProperty @params -Name 'NoDriveAutoRun' -Type 'DWord' -Value $(
    ( 1 -shl 26 ) - 1; # 0x3FFFFFF
);
Set-ItemProperty @params -Name 'NoDriveTypeAutoRun' -Type 'DWord' -Value $(
    ( 1 -shl 8 ) - 1; # 0xFF
);

Set-MpPreference -DisableRealtimeMonitoring $true;

try {
  Set-Volume -DriveLetter C -NewFileSystemLabel "SISTEMA"
}
catch { 
  write-host "????? falha ao renomear disco do sistema"
}
