// Release 1.2.0.1000
// source: dokany/samples/dokan_mirror/mirror.c
// commit: f6de99b914b8f858acf940073ae8836eb476de7f

(*
  Dokan : user-mode file system library for Windows

  Copyright (C) 2015 - 2018 Adrien J. <liryna.stark@gmail.com> and Maxime C. <maxime@islog.com>
  Copyright (C) 2007 - 2011 Hiroki Asakawa <info@dokan-dev.net>

  https://dokan-dev.github.io/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*)

program mount;

{
dir listing OK
dir browsing OK
create dir ok
rename dir ok
create file ok
rename file ok
read file ok (except vlc? but videos still read fine in chrome...) - handle is kept in between read operations.
write file ok (we truncate on the first write) - handle is kept in between write operations.
copy/paste file OK
delete file ok
delete dir ok
}

{$ifdef FPC}
  {$mode delphi}
{$endif FPC}

{$align 8}
{$minenumsize 4}
{$apptype console}

uses
  Windows,
  SysUtils,
  classes,
  Math,
  Dokan in '..\..\Dokan.pas',
  DokanWin in '..\..\DokanWin.pas';


const


  EXIT_SUCCESS = 0;
  EXIT_FAILURE = 1;

  CSTR_EQUAL = 2;
  LOCALE_NAME_SYSTEM_DEFAULT  = '!x-sys-default-locale';

type
  LPVOID = Pointer;
  size_t = NativeUInt;

  _TOKEN_USER = record
    User : TSIDAndAttributes;
  end;
  TOKEN_USER = _TOKEN_USER;
  PTOKEN_USER = ^_TOKEN_USER;

  STREAM_INFO_LEVELS = (FindStreamInfoStandard = 0);

  FILE_INFO_BY_HANDLE_CLASS = (FileRenameInfo = 3, FileDispositionInfo = 4);

  _FILE_RENAME_INFO = record
    ReplaceIfExists: ByteBool;
    RootDirectory: THandle;
    FileNameLength: DWORD;
    FileName: array [0 .. 0] of WCHAR;
  end;
  FILE_RENAME_INFO = _FILE_RENAME_INFO;
  PFILE_RENAME_INFO = ^_FILE_RENAME_INFO;

  _FILE_DISPOSITION_INFO = record
    DeleteFile: ByteBool;
  end;
  FILE_DISPOSITION_INFO = _FILE_DISPOSITION_INFO;
  PFILE_DISPOSITION_INFO = ^_FILE_DISPOSITION_INFO;

function GetFileSizeEx(hFile: THandle;
  var lpFileSize: LARGE_INTEGER): BOOL; stdcall; external kernel32;

function SetFilePointerEx(hFile: THandle; liDistanceToMove: LARGE_INTEGER;
  lpNewFilePointer: PLargeInteger; dwMoveMethod: DWORD): BOOL; stdcall; external kernel32;

function FindFirstStreamW(lpFileName: LPCWSTR; InfoLevel: STREAM_INFO_LEVELS;
  lpFindStreamData: LPVOID; dwFlags: DWORD): THandle; stdcall; external kernel32;

function FindNextStreamW(hFindStream: THandle;
  lpFindStreamData: LPVOID): BOOL; stdcall; external kernel32;

function CompareStringEx(lpLocaleName: LPCWSTR; dwCmpFlags: DWORD;
  lpString1: LPCWSTR; cchCount1: Integer;
  lpString2: LPCWSTR; cchCount2: Integer;
  lpVersionInformation: Pointer; lpReserved: LPVOID;
  lParam: LPARAM): Integer; stdcall; external kernel32;

function SetFileInformationByHandle(hFile: THandle;
  FileInformationClass: FILE_INFO_BY_HANDLE_CLASS; lpFileInformation: LPVOID;
  dwBufferSize: DWORD): BOOL; stdcall; external kernel32;

procedure wcsncat_s(dst: PWCHAR; dst_len: size_t; src: PWCHAR; src_len: size_t);
begin
  while (dst^ <> #0) and (dst_len > 1) do begin
    Inc(dst);
    Dec(dst_len);
  end;
  while (dst_len > 1) and (src^ <> #0) and (src_len > 0) do begin
    dst^ := src^;
    Inc(dst);
    Dec(dst_len);
    Inc(src);
    Dec(src_len);
  end;
  if (dst_len > 0) then
    dst^ := #0
end;

function _wcsnicmp(str1, str2: PWCHAR; len: Integer): Integer;
begin
  Result := CompareStringEx(
    LOCALE_NAME_SYSTEM_DEFAULT,
    NORM_IGNORECASE,
    str1, Math.Min(lstrlenW(str1), len),
    str2, Math.Min(lstrlenW(str2), len),
    nil, nil, 0
  ) - CSTR_EQUAL;
end;

function escape_replace(const esc: string): string;
var
  i, j, len: Integer;
begin
  i := 1;
  j := 1;
  len:=Length(esc);
  SetLength(Result, len);
  while (i <= len) do begin
    if (esc[i] = '\') then begin
      Inc(i);
      case (esc[i]) of
        't': Result[j] := #09;
        'n': Result[j] := #10;
      else
        Result[j] := esc[i];
      end;
    end else
      Result[j] := esc[i];
    Inc(i);
    Inc(j);
  end;
  if (i <> j) then
    SetLength(Result, j - 1);
end;

//{$define WIN10_ENABLE_LONG_PATH}
{$ifdef WIN10_ENABLE_LONG_PATH}
//dirty but should be enough
const
	DOKAN_MAX_PATH = 32768;
{$else}
const
	DOKAN_MAX_PATH = MAX_PATH;
{$endif} // DEBUG

type
  WCHAR_PATH = array [0 .. DOKAN_MAX_PATH-1] of WCHAR;

var
  g_UseStdErr: Boolean;
  g_DebugMode: Boolean;
  g_HasSeSecurityPrivilege: Boolean;
  g_ImpersonateCallerUser: Boolean;
  //
  RootDirectory: WCHAR_PATH;
  MountPoint: WCHAR_PATH;
  UNCName: WCHAR_PATH;
  Proxy: WCHAR_PATH;
  fLibHandle:thandle=thandle(-1);
  _createfile:TDokanZwCreateFile=nil;
  _readfile:TDokanReadFile=nil;
  _writefile:TDokanWriteFile=nil;
  _GetFileInformation:TDokanGetFileInformation=nil;
  _FindFiles:TDokanFindFiles=nil;
  _Cleanup:TDokanCleanup;
  _CloseFile:TDokanCloseFile;
  _MoveFile:TDokanMoveFile=nil;
  _DeleteFile:TDokanDeleteFile=nil;
  _DeleteDirectory:TDokanDeleteDirectory=nil;
  _unmount:function():NTSTATUS ; stdcall=nil;
  _mount:function(param:pwidechar):boolean;stdcall=nil;

procedure DbgPrint(format: string; const args: array of const); overload;
var
  outputString: string;
begin
  if (g_DebugMode) then begin
    outputString := SysUtils.Format(escape_replace(format), args);
    if (g_UseStdErr) then begin
      Write(ErrOutput, outputString);
      Flush(ErrOutput);
    end else
      OutputDebugString(PChar(outputString));
  end;
end;

procedure DbgPrint(fmt: string); overload;
begin
  DbgPrint(fmt, []);
end;

  {
procedure GetFilePath(filePath: PWCHAR; numberOfElements: ULONG;
                      const FileName: LPCWSTR);
var
  unclen: size_t;
begin
  lstrcpynW(filePath, RootDirectory, numberOfElements);
  unclen := lstrlenW(UNCName);
  if (unclen > 0) and (_wcsnicmp(FileName, UNCName, unclen) = 0) then begin
    if (_wcsnicmp(FileName + unclen, '.', 1) <> 0) then begin
      wcsncat_s(filePath, numberOfElements, FileName + unclen,
                size_t(lstrlenW(FileName)) - unclen);
    end;
  end else begin
    wcsncat_s(filePath, numberOfElements, FileName, lstrlenW(FileName));
  end;
end;
}

procedure PrintUserName(var DokanFileInfo: DOKAN_FILE_INFO);
var
  handle: THandle;
  buffer: array [0 .. 1023] of UCHAR;
  returnLength: DWORD;
  accountName: array [0 .. 255] of WCHAR;
  domainName: array [0 .. 255] of WCHAR;
  accountLength: DWORD;
  domainLength: DWORD;
  tokenUser_: PTOKEN_USER;
  snu: SID_NAME_USE;
begin
  accountLength := SizeOf(accountName) div SizeOf(WCHAR);
  domainLength := SizeOf(domainName) div SizeOf(WCHAR);

  if (not g_DebugMode) then begin
    Exit;
  end;

  handle := DokanOpenRequestorToken(DokanFileInfo);
  if (handle = INVALID_HANDLE_VALUE) then begin
    DbgPrint('  DokanOpenRequestorToken failed\n');
    Exit;
  end;

  if (not GetTokenInformation(handle, TokenUser, @buffer, SizeOf(buffer),
                           returnLength)) then begin
    DbgPrint('  GetTokenInformaiton failed: %d\n', [GetLastError()]);
    CloseHandle(handle);
    Exit;
  end;

  CloseHandle(handle);

  tokenUser_ := PTOKEN_USER(@buffer);
  if (not LookupAccountSidW(nil, tokenUser_^.User.Sid, accountName, accountLength,
                        domainName, domainLength, snu)) then begin
    DbgPrint('  LookupAccountSid failed: %d\n', [GetLastError()]);
    Exit;
  end;

  DbgPrint('  AccountName: %s, DomainName: %s\n', [accountName, domainName]);
end;

function AddSeSecurityNamePrivilege(): Boolean;
var
  token: THandle;
  err: DWORD;
  luid: TLargeInteger;
  attr: LUID_AND_ATTRIBUTES;
  priv: TOKEN_PRIVILEGES;
  oldPriv: TOKEN_PRIVILEGES;
  retSize: DWORD;
  privAlreadyPresent: Boolean;
  i: Integer;
begin
  token := 0;
  DbgPrint(
      '## Attempting to add SE_SECURITY_NAME privilege to process token ##\n');
  if (not LookupPrivilegeValueW(nil, 'SeSecurityPrivilege', luid)) then begin
    err := GetLastError();
    if (err <> ERROR_SUCCESS) then begin
      DbgPrint('  failed: Unable to lookup privilege value. error = %u\n',
               [err]);
      Result := False; Exit;
    end;
  end;

  attr.Attributes := SE_PRIVILEGE_ENABLED;
  attr.Luid := luid;

  priv.PrivilegeCount := 1;
  priv.Privileges[0] := attr;

  if (not OpenProcessToken(GetCurrentProcess(),
                        TOKEN_ADJUST_PRIVILEGES or TOKEN_QUERY, token)) then begin
    err := GetLastError();
    if (err <> ERROR_SUCCESS) then begin
      DbgPrint('  failed: Unable obtain process token. error = %u\n', [err]);
      Result := False; Exit;
    end;
  end;

  AdjustTokenPrivileges(token, False, priv, SizeOf(TOKEN_PRIVILEGES), oldPriv,
                        retSize);
  err := GetLastError();
  if (err <> ERROR_SUCCESS) then begin
    DbgPrint('  failed: Unable to adjust token privileges: %u\n', [err]);
    CloseHandle(token);
    Result := False; Exit;
  end;

  privAlreadyPresent := False;
  for i := 0 to oldPriv.PrivilegeCount - 1 do begin
    if (oldPriv.Privileges[i].Luid = luid) then begin
      privAlreadyPresent := True;
      Break;
    end;
  end;
  if (privAlreadyPresent) then
    DbgPrint('  success: privilege already present\n')
  else
    DbgPrint('  success: privilege added\n');
  if (token <> 0) then
    CloseHandle(token);
  Result := True; Exit;
end;

procedure CheckFlag(const val: DWORD; const flag: DWORD; const flagname: string);
begin
  if (val and flag <> 0) then
    DbgPrint('\t%s\n', [flagname]);
end;

function onCreateFile(FileName: LPCWSTR; var SecurityContext: DOKAN_IO_SECURITY_CONTEXT;
                 DesiredAccess: ACCESS_MASK; FileAttributes: ULONG;
                 ShareAccess: ULONG; CreateDisposition: ULONG;
                 CreateOptions: ULONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
dummy:string;
begin
//
DbgPrint('CreateFile:'+FileName);
if assigned(_CreateFile) then
result:=_CreateFile(FileName,  SecurityContext,DesiredAccess, FileAttributes,
                 ShareAccess, CreateDisposition, CreateOptions,  DokanFileInfo);
end;

procedure onCloseFile(FileName: LPCWSTR;
                          var DokanFileInfo: DOKAN_FILE_INFO); stdcall;
begin

DbgPrint('CloseFile:'+FileName);
try
if assigned (_CloseFile)
   then _CloseFile(FileName ,DokanFileInfo );
except
on e:exception do writeln('_CloseFile:'+e.message);
end;
end;

procedure onCleanup(FileName: LPCWSTR;
                        var DokanFileInfo: DOKAN_FILE_INFO); stdcall;
var
   path:string;
begin
//
DbgPrint('Cleanup: '+FileName);
try
if assigned(_Cleanup)
   then _Cleanup(FileName,DokanFileInfo);
except
on e:exception do writeln('_Cleanup:'+e.message);
end;
end;

function onReadFile(FileName: LPCWSTR; var Buffer;
                        BufferLength: DWORD;
                        var ReadLength: DWORD;
                        Offset: LONGLONG;
                        var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  dummy:string;

begin
//
DbgPrint('ReadFile:'+FileName+' '+inttostr(BufferLength)+'@'+inttostr(offset)+ ' '+inttostr(DokanFileInfo.Context ));
//
//Result := STATUS_SUCCESS;
if assigned(_readfile) then
  result:=_ReadFile(filename,Buffer,BufferLength,ReadLength,Offset,DokanFileInfo);
  
end;

function onWriteFile(FileName: LPCWSTR; const Buffer;
                         NumberOfBytesToWrite: DWORD;
                         var NumberOfBytesWritten: DWORD;
                         Offset: LONGLONG;
                         var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  dummy:string;
begin
  DbgPrint('WriteFile : %s, offset %d, length %d\n', [FileName, Offset,
           NumberOfBytesToWrite]);
if assigned(_WriteFile) then
  result:=_WriteFile(FileName,Buffer,NumberOfBytesToWrite,NumberOfBytesWritten,Offset,DokanFileInfo);

end;

function onFlushFileBuffers(FileName: LPCWSTR; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  error: DWORD;
begin
  Result := STATUS_SUCCESS;
end;



function onGetFileInformation(
    FileName: LPCWSTR; var HandleFileInformation: BY_HANDLE_FILE_INFORMATION;
    var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  error: DWORD;
  find: WIN32_FIND_DATAW;
  findHandle: THandle;
  opened: Boolean;
begin
//
DbgPrint('GetFileInformation:'+FileName);
//
//Result := STATUS_SUCCESS;
if assigned(_GetFileInformation) then
   result:=_GetFileInformation(FileName ,HandleFileInformation,DokanFileInfo);
end;

function onFindFiles(FileName: LPCWSTR;
                FillFindData: TDokanFillFindData; // function pointer
                var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  fileLen: size_t;
  hFind: THandle;
  findData: WIN32_FIND_DATAW;
  error: DWORD;
  count: Integer;
  rootFolder: Boolean;
begin
//
DbgPrint('FindFiles:'+FileName);
//
try
if assigned(_FindFiles) then
  result:=_FindFiles(FileName,FillFindData,DokanFileInfo);
except
on e:exception do writeln('_FindFiles:'+e.message);
end;

end;

{
https://dokan-dev.github.io/dokany-doc/html/struct_d_o_k_a_n___o_p_e_r_a_t_i_o_n_s.html
Check if it is possible to delete a file.
DeleteFile will also be called with DOKAN_FILE_INFO.DeleteOnClose set to FALSE to notify the driver when
the file is no longer requested to be deleted.
The file in DeleteFile should not be deleted, but instead the file must be checked as to whether
or not it can be deleted, and STATUS_SUCCESS should be returned (when it can be deleted)
or appropriate error codes, such as STATUS_ACCESS_DENIED or STATUS_OBJECT_NAME_NOT_FOUND,
should be returned.
}

function onDeleteFile(FileName: LPCWSTR; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  dwAttrib: DWORD;
  fdi: FILE_DISPOSITION_INFO;
  path:string;
begin
//
DbgPrint('DeleteFile:'+FileName);
//writeln('DeleteFile:'+FileName);
try
if assigned(_DeleteFile)
   then result := _DeleteFile(filename,DokanFileInfo);
except
on e:exception do writeln('_DeleteFile:'+e.message);
end;

end;

{
When STATUS_SUCCESS is returned, a Cleanup call is received afterwards with DOKAN_FILE_INFO.DeleteOnClose set to TRUE. Only then must the closing file be deleted.
}
function onDeleteDirectory(FileName: LPCWSTR; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  hFind: THandle;
  findData: WIN32_FIND_DATAW;
  fileLen: size_t;
  error: DWORD;
  //
  path:string;
begin
//
DbgPrint('DeleteDirectory:'+FileName);
try
if assigned(_DeleteDirectory)
   then result := _DeleteDirectory(FileName,DokanFileInfo);
except
on e:exception do writeln('_DeleteDirectory:'+e.message);
end;

end;

function onMoveFile(FileName: LPCWSTR; // existing file name
               NewFileName: LPCWSTR; ReplaceIfExisting: BOOL;
               var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  newFilePath: WCHAR_PATH;
  handle: THandle;
  bufferSize: DWORD;
  result_: Boolean;
  newFilePathLen: size_t;
  renameInfo: PFILE_RENAME_INFO;
  error: DWORD;
  old_path,new_path:string;
begin
DbgPrint('MoveFile %s -> %s\n\n', [FileName, NewFileName]);
//
try
if assigned(_MoveFile)
   then result := _MoveFile(filename,newfilename,ReplaceIfExisting,DokanFileInfo);
except
on e:exception do writeln('_MoveFile:'+e.message);
end;

end;

function onLockFile(FileName: LPCWSTR;
                        ByteOffset: LONGLONG;
                        Length: LONGLONG;
                        var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  offset: LARGE_INTEGER;
  length_: LARGE_INTEGER;
  error: DWORD;
begin
//
DbgPrint('LockFile:'+FileName);
Result := STATUS_SUCCESS;
end;

function onSetEndOfFile(
    FileName: LPCWSTR; ByteOffset: LONGLONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  offset: LARGE_INTEGER;
  error: DWORD;
begin
//if you actually use this function you should do something about it...
DbgPrint('SetEndOfFile %s, %d\n', [FileName, ByteOffset]);
//writeln('SetEndOfFile:'+ FileName);
Result := STATUS_SUCCESS;
end;

function onSetAllocationSize(
    FileName: LPCWSTR; AllocSize: LONGLONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  fileSize: LARGE_INTEGER;
  error: DWORD;
begin
//if you actually use this function you should do something about it...
  DbgPrint('SetAllocationSize %s, %d\n', [FileName, AllocSize]);
  Result := STATUS_SUCCESS;
end;

function onSetFileAttributes(
    FileName: LPCWSTR; FileAttributes: DWORD; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  error: DWORD;
begin
//if you actually use this function you should do something about it...
  DbgPrint('SetFileAttributes %s 0x%x\n', [FileName, FileAttributes]);
  Result := STATUS_SUCCESS;
end;

function onSetFileTime(FileName: LPCWSTR; var CreationTime: FILETIME;
                  var LastAccessTime: FILETIME; var LastWriteTime: FILETIME;
                  var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  error: DWORD;
begin
//if you actually use this function you should do something about it...
  DbgPrint('SetFileTime %s\n', [FileName]);
  Result := STATUS_SUCCESS;
end;

function onUnlockFile(FileName: LPCWSTR; ByteOffset: LONGLONG; Length: LONGLONG;
                 var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  length_: LARGE_INTEGER;
  offset: LARGE_INTEGER;
  error: DWORD;
begin
//
DbgPrint('UnlockFile:'+FileName);
Result := STATUS_SUCCESS;
end;

function onGetFileSecurity(
    FileName: LPCWSTR; var SecurityInformation: SECURITY_INFORMATION;
    SecurityDescriptor: PSECURITY_DESCRIPTOR; BufferLength: ULONG;
    var LengthNeeded: ULONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  requestingSaclInfo: Boolean;
  handle: THandle;
  DesiredAccess: DWORD;
  error: DWORD;
  securityDescriptorLength: DWORD;
begin
//absolutely needed on win10?
//will get "msdos fonction not valid" if not returning success
DbgPrint('onGetFileSecurity:'+FileName);
SecurityInformation := SecurityInformation and not SACL_SECURITY_INFORMATION;
SecurityInformation := SecurityInformation and not BACKUP_SECURITY_INFORMATION;
Result := STATUS_SUCCESS;
end;

function onSetFileSecurity(
    FileName: LPCWSTR; var SecurityInformation: SECURITY_INFORMATION;
    SecurityDescriptor: PSECURITY_DESCRIPTOR; SecurityDescriptorLength: ULONG;
    var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  handle: THandle;
  filePath: WCHAR_PATH;
  error: DWORD;
begin
//if you actually use this function you should do something about it...

  DbgPrint('SetFileSecurity %s\n', [FileName]);
  Result := STATUS_SUCCESS;
end;

function onGetVolumeInformation(
    VolumeNameBuffer: LPWSTR; VolumeNameSize: DWORD; var VolumeSerialNumber: DWORD;
    var MaximumComponentLength: DWORD; var FileSystemFlags: DWORD;
    FileSystemNameBuffer: LPWSTR; FileSystemNameSize: DWORD;
    var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
begin
//fake it baby ...

 lstrcpynW(VolumeNameBuffer, 'DOKAN', VolumeNameSize);
 if (@VolumeSerialNumber <> nil) then VolumeSerialNumber := $19831116;
 if (@MaximumComponentLength <> nil) then MaximumComponentLength := 255;
 if (@FileSystemFlags <> nil) then
    FileSystemFlags := FILE_CASE_SENSITIVE_SEARCH or FILE_CASE_PRESERVED_NAMES or
                     FILE_SUPPORTS_REMOTE_STORAGE or FILE_UNICODE_ON_DISK or
                     FILE_PERSISTENT_ACLS or FILE_NAMED_STREAMS;
 lstrcpynW(FileSystemNameBuffer, 'NTFS', FileSystemNameSize);

  Result := STATUS_SUCCESS;
  Exit;


end;

(*
//Uncomment for personalize disk space
function DokanGetDiskFreeSpace(
    var FreeBytesAvailable: ULONGLONG; var TotalNumberOfBytes: ULONGLONG;
    var TotalNumberOfFreeBytes: ULONGLONG; var DokanFileInfo: DOKAN_FILE_INFO
  ): NTSTATUS; stdcall;
begin
  FreeBytesAvailable := (512 * 1024 * 1024);
  TotalNumberOfBytes := 9223372036854775807;
  TotalNumberOfFreeBytes := 9223372036854775807;

  Result := STATUS_SUCCESS; Exit;
end;
*)

(**
 * Avoid #include <winternl.h> which as conflict with FILE_INFORMATION_CLASS
 * definition.
 * This only for FindStreams. Link with ntdll.lib still required.
 *
 * Not needed if you're not using NtQueryInformationFile!
 *
 * BEGIN
 */
typedef struct _IO_STATUS_BLOCK {
  union {
    NTSTATUS Status;
    PVOID Pointer;
  } DUMMYUNIONNAME;

  ULONG_PTR Information;
} IO_STATUS_BLOCK, *PIO_STATUS_BLOCK;

NTSYSCALLAPI NTSTATUS NTAPI NtQueryInformationFile(
    _In_ HANDLE FileHandle, _Out_ PIO_STATUS_BLOCK IoStatusBlock,
    _Out_writes_bytes_(Length) PVOID FileInformation, _In_ ULONG Length,
    _In_ FILE_INFORMATION_CLASS FileInformationClass);
/**
 * END
 *)

function onFindStreams(FileName: LPCWSTR; FillFindStreamData: TDokanFillFindStreamData;
                  var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  hFind: THandle;
  findData: WIN32_FIND_STREAM_DATA;
  error: DWORD;
  count: Integer;
begin
DbgPrint('FindStreams :%s\n', [FileName]);
Result := STATUS_SUCCESS;
//
  
end;

function onMounted(var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
begin
  DbgPrint('Mounted\n');
  Result := STATUS_SUCCESS;
end;

function onUnmounted(var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
begin
  DbgPrint('Unmounted\n');
  //Result := STATUS_SUCCESS;
  if assigned(_unmount) then
    begin
    write('Unmounting...');
    result:=_unmount();
    if result=status_success then write('Done.') else writeln('Failed.');
    end;
  //
  FreeLibrary(fLibHandle);
  //free filesystem
end;

function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case (dwCtrlType) of
    CTRL_C_EVENT,
    CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT,
    CTRL_SHUTDOWN_EVENT: begin
      SetConsoleCtrlHandler(@CtrlHandler, False);
      DokanRemoveMountPoint(MountPoint);
      Result := True;
    end;
  else
    Result := False;
  end;
end;

procedure ShowUsage();
begin
    Write(ErrOutput, escape_replace('progam.exe\n' +
    '  /x proxy (ex. /x myproxy.dll.\n' +
    '  /r resource to be mounted (ex. /r nfs://server/export/)\t\t NFS export to map.\n' +
    '  /l MountPoint (ex. /l m)\t\t\t Mount point. Can be M:\\ (drive letter) or empty NTFS folder C:\\mount\\dokan .\n' +
    '  /t ThreadCount (ex. /t 5)\t\t\t Number of threads to be used internally by Dokan library.\n\t\t\t\t\t\t More threads will handle more event at the same time.\n' +
    '  /d (enable debug output)\t\t\t Enable debug output to an attached debugger.\n' +
    '  /s (use stderr for output)\t\t\t Enable debug output to stderr.\n' +
    '  /n (use network drive)\t\t\t Show device as network device.\n' +
    '  /m (use removable drive)\t\t\t Show device as removable media.\n' +
    '  /w (write-protect drive)\t\t\t Read only filesystem.\n' +
    '  /o (use mount manager)\t\t\t Register device to Windows mount manager.\n\t\t\t\t\t\t This enables advanced Windows features like recycle bin and more...\n' +
    '  /c (mount for current session only)\t\t Device only visible for current user session.\n' +
    '  /u (UNC provider name ex. \\localhost\\myfs)\t UNC name used for network volume.\n' +
    //'  /p (Impersonate Caller User)\t\t\t Impersonate Caller User when getting the handle in CreateFile for operations.\n\t\t\t\t\t\t This option requires administrator right to work properly.\n' +
    '  /a Allocation unit size (ex. /a 512)\t\t Allocation Unit Size of the volume. This will behave on the disk file size.\n' +
    '  /k Sector size (ex. /k 512)\t\t\t Sector Size of the volume. This will behave on the disk file size.\n' +
    '  /f User mode Lock\t\t\t\t Enable Lockfile/Unlockfile operations. Otherwise Dokan will take care of it.\n' +
    '  /i (Timeout in Milliseconds ex. /i 30000)\t Timeout until a running operation is aborted and the device is unmounted.\n\n' +
    'Examples:\n' +
    //'\tprogram.exe /discover\n' +
    '\tprogram.exe /r test.zip /l x /x proxy_7zip.dll\n' +
    'Unmount the drive with CTRL + C in the console or alternatively via ''dokanctl /u MountPoint''.\n'));
end;

function wmain(argc: ULONG; argv: array of string): Integer;
var
  status: Integer;
  command: ULONG;
  dokanOperations: PDOKAN_OPERATIONS;
  dokanOptions: PDOKAN_OPTIONS;
  servers:tstrings;
  i:byte;
begin


//
  New(dokanOperations);
  if (dokanOperations = nil) then begin
    Result := EXIT_FAILURE; Exit;
  end;
  New(dokanOptions);
  if (dokanOptions = nil) then begin
    Dispose(dokanOperations);
    Result := EXIT_FAILURE; Exit;
  end;

  if (argc < 3) then begin
    ShowUsage();
    Dispose(dokanOperations);
    Dispose(dokanOptions);
    Result := EXIT_FAILURE; Exit;
  end;

  g_DebugMode := false;
  g_UseStdErr := False;

  ZeroMemory(dokanOptions, SizeOf(DOKAN_OPTIONS));
  dokanOptions^.Version := DOKAN_VERSION;
  dokanOptions^.ThreadCount := 1; // use default

  command := 1;
  while (command < argc) do begin
    case (UpCase(argv[command][2])) of
      'X': begin
        Inc(command);
        lstrcpynW(proxy, PWideChar(WideString(argv[command])), DOKAN_MAX_PATH);
        DbgPrint('proxy: %s\n', [proxy]);
      end;
      'R': begin
        Inc(command);
        lstrcpynW(@RootDirectory[0], PWideChar(WideString(argv[command])), DOKAN_MAX_PATH);
        DbgPrint('RootDirectory: %s\n', [RootDirectory]);
      end;
      'L': begin
        Inc(command);
        lstrcpynW(MountPoint, PWideChar(WideString(argv[command])), DOKAN_MAX_PATH);
        dokanOptions^.MountPoint := MountPoint;
      end;
      'T': begin
        Inc(command);
        dokanOptions^.ThreadCount := StrToInt(argv[command]);
      end;
      'D': begin
        g_DebugMode := True;
      end;
      'S': begin
        g_UseStdErr := True;
      end;
      'N': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_NETWORK;
      end;
      'M': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_REMOVABLE;
      end;
      'W': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_WRITE_PROTECT;
      end;
      'O': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_MOUNT_MANAGER;
      end;
      'C': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_CURRENT_SESSION;
      end;
      'F': begin
        dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_FILELOCK_USER_MODE;
      end;
      'U': begin
        Inc(command);
        lstrcpynW(UNCName, PWideChar(WideString(argv[command])), DOKAN_MAX_PATH);
        dokanOptions^.UNCName := UNCName;
        DbgPrint('UNC Name: %s\n', [UNCName]);
      end;
      'P': begin
        g_ImpersonateCallerUser := True;
      end;
      'I': begin
        Inc(command);
        dokanOptions^.Timeout := StrToInt(argv[command]);
      end;
      'A': begin
        Inc(command);
        dokanOptions^.AllocationUnitSize := StrToInt(argv[command]);
      end;
      'K': begin
        Inc(command);
        dokanOptions^.SectorSize := StrToInt(argv[command]);
      end;
    else
      Writeln(ErrOutput, 'unknown command: ', argv[command]);
      Dispose(dokanOperations);
      Dispose(dokanOptions);
      Result := EXIT_FAILURE; Exit;
    end;
    Inc(command);
  end;

  if (UNCName <> '') and
      (dokanOptions^.Options and DOKAN_OPTION_NETWORK = 0) then begin
    Writeln(
        ErrOutput,
        '  Warning: UNC provider name should be set on network drive only.');
  end;

  if (dokanOptions^.Options and DOKAN_OPTION_NETWORK <> 0) and
     (dokanOptions^.Options and DOKAN_OPTION_MOUNT_MANAGER <> 0) then begin
    Writeln(ErrOutput, 'Mount manager cannot be used on network drive.');
    Dispose(dokanOperations);
    Dispose(dokanOptions);
    Result := EXIT_FAILURE; Exit;
  end;

  if (dokanOptions^.Options and DOKAN_OPTION_MOUNT_MANAGER = 0) and
     (MountPoint = '') then begin
    Writeln(ErrOutput, 'Mount Point required.');
    Dispose(dokanOperations);
    Dispose(dokanOptions);
    Result := EXIT_FAILURE; Exit;
  end;

  if (dokanOptions^.Options and DOKAN_OPTION_MOUNT_MANAGER <> 0) and
     (dokanOptions^.Options and DOKAN_OPTION_CURRENT_SESSION <> 0) then begin
    Writeln(ErrOutput,
             'Mount Manager always mount the drive for all user sessions.');
    Dispose(dokanOperations);
    Dispose(dokanOptions);
    Result := EXIT_FAILURE; Exit;
  end;

  if (not SetConsoleCtrlHandler(@CtrlHandler, True)) then begin
    Writeln(ErrOutput, 'Control Handler is not set.');
  end;

  // Add security name privilege. Required here to handle GetFileSecurity
  // properly.
  g_HasSeSecurityPrivilege := AddSeSecurityNamePrivilege();
  if (not g_HasSeSecurityPrivilege) then begin
    Writeln(ErrOutput, 'Failed to add security privilege to process');
    Writeln(ErrOutput,
             #09'=> GetFileSecurity/SetFileSecurity may not work properly');
    Writeln(ErrOutput, #09'=> Please restart program sample with administrator ' +
                     'rights to fix it');
  end;

  if (g_ImpersonateCallerUser and not g_HasSeSecurityPrivilege) then begin
    Writeln(ErrOutput, 'Impersonate Caller User requires administrator right to ' +
                     'work properly\n');
    Writeln(ErrOutput, #09'=> Other users may not use the drive properly\n');
    Writeln(ErrOutput, #09'=> Please restart program sample with administrator ' +
                     'rights to fix it\n');
  end;

  if (g_DebugMode) then begin
    dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_DEBUG;
  end;
  if (g_UseStdErr) then begin
    dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_STDERR;
  end;

  dokanOptions^.Options := dokanOptions^.Options or DOKAN_OPTION_ALT_STREAM;

  writeln('DokanVersion:'+inttostr(DokanVersion));
  writeln('DokanDriverVersion:'+inttostr(DokanDriverVersion));

  if proxy<>'' then
    begin
    writeln('checking proxy; in progress');
    fLibHandle:=thandle(-1);
    fLibHandle:=LoadLibraryw(proxy);
    if fLibHandle <=0 then
      begin
      writeln('LoadLibrary failed');
      exit;
      end;
    //getprocadress is f...ing CASE SENSITIVE !!!!!!
    @_createfile:=GetProcAddress(fLibHandle,'_CreateFile');
    if not assigned(_createfile) then writeln('_createfile not ok');
    @_readfile:=GetProcAddress(fLibHandle,'_ReadFile');
    if not assigned(_readfile) then writeln('_readfile not ok');
    @_writefile:=GetProcAddress(fLibHandle,'_WriteFile');
    if not assigned(_writefile) then writeln('_writefile not ok');
    @_findfiles:=GetProcAddress(fLibHandle,'_FindFiles');
    if not assigned(_findfiles) then writeln('_findfiles not ok');
    @_GetFileInformation:=GetProcAddress(fLibHandle,'_GetFileInformation');
    if not assigned(_GetFileInformation) then writeln('_GetFileInformation not ok');
    @_unmount:=GetProcAddress(fLibHandle,'_unMount');
    if not assigned(_unmount) then writeln('_unmount not ok');
    @_mount:=GetProcAddress(fLibHandle,'_Mount');
    if not assigned(_mount) then writeln('_mount not ok');
    @_Cleanup:=GetProcAddress(fLibHandle,'_Cleanup');
    if not assigned(_Cleanup) then writeln('_Cleanup not ok');
    @_CloseFile:=GetProcAddress(fLibHandle,'_CloseFile');
    if not assigned(_CloseFile) then writeln('_CloseFile not ok');
    @_MoveFile:=GetProcAddress(fLibHandle,'_MoveFile');
    if not assigned(_MoveFile) then writeln('_MoveFile not ok');
    @_DeleteFile:=GetProcAddress(fLibHandle,'_DeleteFile');
    if not assigned(_DeleteFile) then writeln('_DeleteFile not ok');
    @_DeleteDirectory:=GetProcAddress(fLibHandle,'_DeleteDirectory');
    if not assigned(_DeleteDirectory) then writeln('_DeleteDirectory not ok');
    writeln('checking proxy: done');
    end
    else
    begin
    Dispose(dokanOptions);
    writeln('no proxy defined.');
    exit;
    end;

  ZeroMemory(dokanOperations, SizeOf(DOKAN_OPERATIONS));
  dokanOperations^.ZwCreateFile := onCreateFile;
  dokanOperations^.Cleanup := onCleanup;
  dokanOperations^.CloseFile := onCloseFile;
  dokanOperations^.ReadFile := onReadFile;
  dokanOperations^.WriteFile := onWriteFile;
  dokanOperations^.FlushFileBuffers := onFlushFileBuffers; ////only return success
  dokanOperations^.GetFileInformation := onGetFileInformation;
  dokanOperations^.FindFiles := onFindFiles;
  dokanOperations^.FindFilesWithPattern := nil;
  //dokanOperations^.SetFileAttributes := onSetFileAttributes;
  //dokanOperations^.SetFileTime := onSetFileTime;
  dokanOperations^.DeleteFile := onDeleteFile;
  dokanOperations^.DeleteDirectory := onDeleteDirectory;
  dokanOperations^.MoveFile := onMoveFile;
  //dokanOperations^.SetEndOfFile := onSetEndOfFile;
  //dokanOperations^.SetAllocationSize := onSetAllocationSize;
  dokanOperations^.LockFile := onLockFile;  //only return success
  dokanOperations^.UnlockFile := onUnlockFile; //only return success
  //dokanOperations^.GetFileSecurity := onGetFileSecurity;
  //dokanOperations^.SetFileSecurity := onSetFileSecurity;
  dokanOperations^.GetDiskFreeSpace := nil; // onDokanGetDiskFreeSpace;
  dokanOperations^.GetVolumeInformation := onGetVolumeInformation;
  dokanOperations^.Unmounted := onUnmounted;
  //dokanOperations^.FindStreams := onFindStreams;
  dokanOperations^.Mounted := onMounted;

  //create filesyste ressources
  writeln('Mounting...');
  writeln('RootDirectory:'+WideCharToString(@RootDirectory[0]));
  if _mount((@RootDirectory[0]))=false then
    begin
    Dispose(dokanOptions);
    Dispose(dokanOperations);
    Result := EXIT_FAILURE ;
    writeln('failed.');
    Exit;
    end
    else writeln('done.');

  status := DokanMain(dokanOptions^, dokanOperations^);
  case (status) of
    DOKAN_SUCCESS:
      Writeln(ErrOutput, 'Success');
    DOKAN_ERROR:
      Writeln(ErrOutput, 'Error');
    DOKAN_DRIVE_LETTER_ERROR:
      Writeln(ErrOutput, 'Bad Drive letter');
    DOKAN_DRIVER_INSTALL_ERROR:
      Writeln(ErrOutput, 'Can''t install driver');
    DOKAN_START_ERROR:
      Writeln(ErrOutput, 'Driver something wrong');
    DOKAN_MOUNT_ERROR:
      Writeln(ErrOutput, 'Can''t assign a drive letter');
    DOKAN_MOUNT_POINT_ERROR:
      Writeln(ErrOutput, 'Mount point error');
    DOKAN_VERSION_ERROR:
      Writeln(ErrOutput, 'Version error');
  else
    Writeln(ErrOutput, 'Unknown error: ', status);
  end;

  Dispose(dokanOptions);
  Dispose(dokanOperations);
  Result := EXIT_SUCCESS; Exit;
end;

var
  i: Integer;
  argc: ULONG;
  argv: array of string;

begin
{
writeln(extractfilepath('\folder'));
writeln(extractfiledir('\folder'));
writeln(extractfilepath('\folder\filename'));
writeln(extractfiledir('\folder\filename'));
writeln(extractfilename('\folder\filename'));
}
{
writeln(extractfilepath('\'));
writeln(extractfiledir('\'));
writeln(extractfilepath('\filename'));
writeln(extractfiledir('\filename'));
writeln(extractfilename('\filename'));
}
  IsMultiThread := True;

  {
  lstrcpyW(RootDirectory, 'nfs://192.168.1.248/volume2/public/');
  lstrcpyW(MountPoint, 'X:\');
  lstrcpyW(UNCName, '');
  }
  
  argc := 1 + ParamCount();
  SetLength(argv, argc);
  for i := 0 to argc - 1 do
    argv[i] := ParamStr(i);

  try
    ExitCode := wmain(argc, argv);
  except
    ExitCode := EXIT_FAILURE;
  end;
end.

