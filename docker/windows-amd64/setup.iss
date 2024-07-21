[Setup]
AppName=Fula
AppVersion=1.0
DefaultDirName={userdocs}\Fula
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=FulaSetup
Compression=lzma
SolidCompression=yes

[Files]
Source: "..\fxsupport\linux\.env.cluster"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\fxsupport\linux\.env.gofula"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\fxsupport\linux\kubo\*"; DestDir: "{app}\kubo"; Flags: recursesubdirs ignoreversion
Source: "..\fxsupport\linux\ipfs-cluster\*"; DestDir: "{app}\ipfs-cluster"; Flags: recursesubdirs ignoreversion
Source: "*"; DestDir: "{app}"; Flags: recursesubdirs
Source: "trayicon.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "start_node_server.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Fula Status"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\status.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\status.ico"
Name: "{group}\Fula Start"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\start.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\start.ico"
Name: "{group}\Fula Stop"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\stop.ico"

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install_docker.ps1"""; StatusMsg: "Installing Docker..."; Flags: runhidden
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"" -InstallationPath ""{app}"" -ExternalDrive ""{code:GetExternalDrive}"""; StatusMsg: "Setting up Fula..."; Flags: runhidden
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\trayicon.ps1"""; StatusMsg: "Setting up tray icon..."; Flags: shellexec runhidden

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -InstallationPath ""{app}"""; StatusMsg: "Removing Docker containers and volumes..."; Flags: runhidden

[Code]
const
  DRIVE_UNKNOWN = 0;
  DRIVE_NO_ROOT_DIR = 1;
  DRIVE_REMOVABLE = 2;
  DRIVE_FIXED = 3;
  DRIVE_REMOTE = 4;
  DRIVE_CDROM = 5;
  DRIVE_RAMDISK = 6;

var
  DiskPage: TWizardPage;
  DiskComboBox: TComboBox;
  externalDrive: string;

function GetDriveType(lpRootPathName: string): UINT;
  external 'GetDriveTypeA@kernel32.dll stdcall';
function GetLogicalDriveStrings(nBufferLength: DWORD; lpBuffer: PAnsiChar): DWORD;
  external 'GetLogicalDriveStringsA@kernel32.dll stdcall';

procedure InitializeWizard;
var
  I: Integer;
  DriveBuffer: AnsiString;
  Drive: string;
  P, BufLen: Integer;
begin
  // Create the custom page
  DiskPage := CreateCustomPage(wpSelectDir, 'Select External Storage Drive', 'Please select an external storage drive from the list below.');
  DiskComboBox := TComboBox.Create(WizardForm);
  DiskComboBox.Parent := DiskPage.Surface;
  DiskComboBox.Left := ScaleX(10);
  DiskComboBox.Top := ScaleY(10);
  DiskComboBox.Width := ScaleX(300);

  // Initialize DriveBuffer
  SetLength(DriveBuffer, 255);

  // Get logical drive strings
  BufLen := GetLogicalDriveStrings(255, PAnsiChar(DriveBuffer));
  if BufLen = 0 then
  begin
    MsgBox('Error retrieving drive information.', mbError, IDOK);
    // Handle the error (e.g., continue without external drive selection)
  end;

  if BufLen > 0 then
  begin
    P := 1;
    while P <= BufLen do
    begin
      Drive := Copy(DriveBuffer, P, 3);
      if GetDriveType(PAnsiChar(Drive)) <> DRIVE_REMOTE then
      begin
        DiskComboBox.Items.Add(Drive);
      end;
      P := P + 4;
    end;
  end;

  if DiskComboBox.Items.Count > 0 then
    DiskComboBox.ItemIndex := 0
  else
    // Handle empty drive list (optional: display message)
    MsgBox('No external drives found.', mbInformation, MB_OK);
end;

function GetExternalDrive(Param: string): string;
begin
  Result := externalDrive;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = DiskPage.ID then
  begin
    externalDrive := DiskComboBox.Text;
  end;
end;

function StringReplace(const S, OldPattern, NewPattern: string): string;
var
  ResultString: string;
  PosResult: Integer;
begin
  ResultString := S;
  PosResult := Pos(OldPattern, ResultString);
  while PosResult <> 0 do
  begin
    Delete(ResultString, PosResult, Length(OldPattern));
    Insert(NewPattern, ResultString, PosResult);
    PosResult := Pos(OldPattern, ResultString);
  end;
  Result := ResultString;
end;

procedure ReplaceInFile(const FileName, SearchString, ReplaceString: string);
var
  FileContent: AnsiString;
begin
  if LoadStringFromFile(FileName, FileContent) then
  begin
    FileContent := StringReplace(FileContent, SearchString, ReplaceString);
    SaveStringToFile(FileName, FileContent, False);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UnixStylePath, UnixStyleExternalDrive: string;
begin
  if CurStep = ssPostInstall then
  begin
    // Convert the installation path to Unix-style path
    UnixStylePath := StringReplace(ExpandConstant('{app}'), '\', '/');
    UnixStyleExternalDrive := StringReplace(externalDrive, '\', '/');
    
    // Perform the replacements in docker-compose.yml
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:InstallationPath}', UnixStylePath);
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:envDir}', UnixStylePath);
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:ExternalDrive}', StringReplace(UnixStyleExternalDrive, '/', ''));
  end;
end;
