[Setup]
AppName=Fula
AppVersion=1.4
AppPublisher=Functionland
AppPublisherURL=https://fx.land
AppSupportURL=https://t.me/functionlanders
AppUpdatesURL=https://t.me/functionland
DefaultDirName={userdocs}\Fula
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=FulaSetup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
LicenseFile=license.txt
VersionInfoVersion=1.1
VersionInfoCompany=Functionland
VersionInfoDescription=Fula Setup
VersionInfoCopyright=2023 Functionland

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\fxsupport\linux\.env.cluster"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\fxsupport\linux\.env.gofula"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\fxsupport\linux\kubo\*"; DestDir: "{app}\kubo"; Flags: recursesubdirs ignoreversion
Source: "..\fxsupport\linux\ipfs-cluster\*"; DestDir: "{app}\ipfs-cluster"; Flags: recursesubdirs ignoreversion
Source: "docker-compose.yml"; DestDir: "{app}"; Flags: recursesubdirs
Source: "install_docker.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "setup.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "start_node_server.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "start.ico"; DestDir: "{app}"; Flags: recursesubdirs
Source: "start.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "status.ico"; DestDir: "{app}"; Flags: recursesubdirs
Source: "status.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "stop.ico"; DestDir: "{app}"; Flags: recursesubdirs
Source: "stop.ps1"; DestDir: "{app}"; Flags: recursesubdirs
Source: "trayicon.ico"; DestDir: "{app}"; Flags: recursesubdirs
Source: "trayicon.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "mark_installation_complete.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "server\out\fula-webui-win32-x64\*"; DestDir: "{app}\server\fula-webui-win32-x64"; Flags: ignoreversion
Source: "server\out\make\*"; DestDir: "{app}\server\make"; Flags: recursesubdirs

[Icons]
Name: "{group}\Fula Status"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\status.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\status.ico"
Name: "{group}\Fula Start"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\start.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\start.ico"
Name: "{group}\Fula Stop"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\stop.ico"

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install_docker.ps1"""; Flags: runhidden runascurrentuser; Check: IsSilentInstall
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"" -InstallationPath ""{app}"" -ExternalDrive ""{code:GetExternalDrive}"""; Flags: runhidden; Check: IsSilentInstall
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\trayicon.ps1"""; Flags: shellexec runhidden; Check: IsSilentInstall
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\mark_installation_complete.ps1"""; Flags: runhidden waituntilterminated; Check: IsSilentInstall

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -InstallationPath ""{app}"""; StatusMsg: "Removing Docker containers and volumes..."; Flags: runhidden; RunOnceId: "RemoveDocker"

[Code]
type
  WPARAM = UINT_PTR;
  LPARAM = UINT_PTR;
  LRESULT = UINT_PTR;

  TMsg = record
    hwnd: HWND;
    message: UINT;
    wParam: WPARAM;
    lParam: LPARAM;
    time: DWORD;
    pt: TPoint;
  end;
  
const
  DRIVE_UNKNOWN = 0;
  DRIVE_NO_ROOT_DIR = 1;
  DRIVE_REMOVABLE = 2;
  DRIVE_FIXED = 3;
  DRIVE_REMOTE = 4;
  DRIVE_CDROM = 5;
  DRIVE_RAMDISK = 6;
  PM_REMOVE = 1;

var
  DiskPage: TWizardPage;
  DiskComboBox: TComboBox;
  externalDrive: string;

function GetDriveType(lpRootPathName: string): UINT;
  external 'GetDriveTypeA@kernel32.dll stdcall';
function GetLogicalDriveStrings(nBufferLength: DWORD; lpBuffer: PAnsiChar): DWORD;
  external 'GetLogicalDriveStringsA@kernel32.dll stdcall';

function IsSilentInstall: Boolean;
begin
  Result := (Pos('/VERYSILENT', UpperCase(GetCmdTail)) > 0) or (Pos('/SILENT', UpperCase(GetCmdTail)) > 0);
end;

function GetExternalDrive(Param: string): string;
begin
  if IsSilentInstall then
    Result := 'C:'
  else
    Result := externalDrive;
end;

function IsInstallationComplete: Boolean;
begin
  Result := FileExists(GetTempDir + '\fula_installation_complete.flag');
end;

function PeekMessage(var lpMsg: TMsg; hWnd: HWND; wMsgFilterMin, wMsgFilterMax, wRemoveMsg: UINT): BOOL;
  external 'PeekMessageA@user32.dll stdcall';
function TranslateMessage(const lpMsg: TMsg): BOOL;
  external 'TranslateMessage@user32.dll stdcall';
function DispatchMessage(const lpMsg: TMsg): Longint;
  external 'DispatchMessageA@user32.dll stdcall';
  
procedure ProcessMessages;
var
  Msg: TMsg;
begin
  while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
end;

procedure DeleteInstallationCompleteFlag;
var
  FilePath: string;
  Retries: Integer;
begin
  FilePath := ExpandConstant(GetTempDir + '\fula_installation_complete.flag');
  Log('Deleting file: ' + FilePath);
  Retries := 0;
  while not DeleteFile(FilePath) and (Retries < 3) do
  begin
    Log('Failed to delete the installation complete flag file. Retrying...');
    Sleep(1000); // Wait for 1 second before retrying
    Inc(Retries);
  end;
  if Retries >= 3 then
  begin
    Log('Failed to delete the installation complete flag file after multiple attempts: ' + FilePath);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if not IsSilentInstall then
  begin
    Log('CurPageChanged: CurPageID = ' + IntToStr(CurPageID));
    if (CurPageID = DiskPage.ID) or (CurPageID = 10) then
    begin
      if DiskComboBox.ItemIndex <> -1 then
      begin
        externalDrive := DiskComboBox.Text;
        Log('CurPageChanged: DiskComboBox.Text = ' + DiskComboBox.Text);
        Log('CurPageChanged: externalDrive = ' + externalDrive);
      end
      else
      begin
        externalDrive := 'C:'; // Default to C: if not set
        Log('CurPageChanged: externalDrive defaulted to C:');
      end;
    end;
  end;
end;


procedure InitializeWizard;
var
  I: Integer;
  DriveBuffer: AnsiString;
  Drive: string;
  P, BufLen: Integer;
begin

  if not IsSilentInstall then
  begin
    DiskPage := CreateCustomPage(wpSelectDir, 'Select External Storage Drive', 'Please select an external storage drive from the list below.');
    DiskComboBox := TComboBox.Create(WizardForm);
    DiskComboBox.Parent := DiskPage.Surface;
    DiskComboBox.Left := ScaleX(10);
    DiskComboBox.Top := ScaleY(10);
    DiskComboBox.Width := ScaleX(300);

    SetLength(DriveBuffer, 255);
    BufLen := GetLogicalDriveStrings(255, PAnsiChar(DriveBuffer));

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
      MsgBox('No external drives found.', mbInformation, MB_OK);
  end
  else
  begin
    externalDrive := 'C:';
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
  SafeReplaceString: string;
begin
  if LoadStringFromFile(FileName, FileContent) then
  begin
    // Escape backslashes in the replacement string
    SafeReplaceString := StringReplace(ReplaceString, '\', '\\');
    FileContent := StringReplace(FileContent, SearchString, SafeReplaceString);
    SaveStringToFile(FileName, FileContent, False);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UnixStylePath, UnixStyleExternalDrive: string;
  WaitCount: Integer;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // Convert the installation path to Unix-style path
    UnixStylePath := StringReplace(ExpandConstant('{app}'), '\', '/');
    UnixStyleExternalDrive := StringReplace(externalDrive, '\', '/');

    // Ensure single forward slashes
    UnixStylePath := StringReplace(UnixStylePath, '//', '/');
    UnixStyleExternalDrive := StringReplace(UnixStyleExternalDrive, '/', '');

    // Perform the replacements in docker-compose.yml
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:InstallationPath}', UnixStylePath);
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:envDir}', UnixStylePath);
    ReplaceInFile(ExpandConstant('{app}\docker-compose.yml'), '${env:ExternalDrive}', UnixStyleExternalDrive);
    
    if IsSilentInstall then
    begin
      // Run the mark_installation_complete.ps1 script asynchronously
      Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
           '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\mark_installation_complete.ps1') + '"',
           '', SW_HIDE, ewNoWait, ResultCode);

      // Wait for a maximum of 5 minutes (300 seconds)
      WaitCount := 0;
      while (not IsInstallationComplete) and (WaitCount < 300) do
      begin
        Sleep(1000);
        Inc(WaitCount);
        // Process Windows messages to keep the installer responsive
        ProcessMessages;
      end;
      
      DeleteInstallationCompleteFlag;

      if not IsInstallationComplete then
      begin
        Log('Silent installation did not complete within 5 minutes.');
        Abort;
        // Optionally, you can show a message to the user or take other actions
      end;
      
    end;
  end;
end;

procedure BeforeInstall;
var
  ResultCode: Integer;
  SourcePath, DestPath: string;
begin
  // Run npm install, build, and make commands
  Exec(ExpandConstant('{cmd}'), '/C npm install', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/C npm run build', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/C npm run make', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);

  // Copy files after npm commands
  SourcePath := ExpandConstant('{src}\server\out\fula-webui-win32-x64\*');
  DestPath := ExpandConstant('{app}\server\fula-webui-win32-x64');
  Exec(ExpandConstant('{cmd}'), Format('/C xcopy "%s" "%s" /E /I /Y', [SourcePath, DestPath]), '', SW_SHOW, ewWaitUntilTerminated, ResultCode);

  SourcePath := ExpandConstant('{src}\server\out\make\*');
  DestPath := ExpandConstant('{app}\server\make');
  Exec(ExpandConstant('{cmd}'), Format('/C xcopy "%s" "%s" /E /I /Y', [SourcePath, DestPath]), '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
end;
