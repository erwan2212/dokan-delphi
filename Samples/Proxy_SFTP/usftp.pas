unit usftp;



interface

uses windows,sysutils,classes,
    libssh2_sftp,libssh2,
    //blcksock,
    winsock,
    Dokan,DokanWin ;

function UNIXTimeToDateTimeFAST(UnixTime: LongWord): TDateTime;    

function _FindFiles(FileName: LPCWSTR;
  FillFindData: TDokanFillFindData;
  var DokanFileInfo: DOKAN_FILE_INFO
  ): NTSTATUS; stdcall;

function _GetFileInformation(
    FileName: LPCWSTR; var HandleFileInformation: BY_HANDLE_FILE_INFORMATION;
    var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

function _ReadFile(FileName: LPCWSTR; var Buffer;
                        BufferLength: DWORD;
                        var ReadLength: DWORD;
                        Offset: LONGLONG;
                        var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

function _WriteFile(FileName: LPCWSTR; const Buffer;
                         NumberOfBytesToWrite: DWORD;
                         var NumberOfBytesWritten: DWORD;
                         Offset: LONGLONG;
                         var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

function _MoveFile(FileName: LPCWSTR; // existing file name
               NewFileName: LPCWSTR; ReplaceIfExisting: BOOL;
               var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

procedure _CloseFile(FileName: LPCWSTR;
                          var DokanFileInfo: DOKAN_FILE_INFO); stdcall;               

procedure _Cleanup(FileName: LPCWSTR;
                        var DokanFileInfo: DOKAN_FILE_INFO); stdcall;

function _CreateFile(FileName: LPCWSTR; var SecurityContext: DOKAN_IO_SECURITY_CONTEXT;
                 DesiredAccess: ACCESS_MASK; FileAttributes: ULONG;
                 ShareAccess: ULONG; CreateDisposition: ULONG;
                 CreateOptions: ULONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

Function _DeleteFile(FileName: LPCWSTR;var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

function _DeleteDirectory(FileName: LPCWSTR;var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;

function _Mount(rootdirectory:pwidechar):boolean;stdcall;
function _unMount: ntstatus;stdcall;

implementation

var
  debug:boolean=true;
  sock:tsocket;
  session:PLIBSSH2_SESSION;
  tmp:string;
  host:string='';
  username:string='';
  password:string='';
  sftp_session:PLIBSSH2_SFTP;


const
	DOKAN_MAX_PATH = MAX_PATH;

type
  WCHAR_PATH = array [0 .. DOKAN_MAX_PATH-1] of WCHAR;

function UNIXTimeToDateTimeFAST(UnixTime: LongWord): TDateTime;
begin
Result := (UnixTime / 86400) + 25569;
end;

procedure log(msg:string;level:byte=0);
begin
  if (level=0) and (debug=false) then exit;
  {$i-}writeln(msg);{$i+}
end;

procedure DbgPrint(format: string; const args: array of const); overload;
begin
//dummy
end;

procedure DbgPrint(fmt: string); overload;
begin
//dummy
end;


function _FindFiles(FileName: LPCWSTR;
  FillFindData: TDokanFillFindData;
  var DokanFileInfo: DOKAN_FILE_INFO
  ): NTSTATUS; stdcall;
var

str_type,str_size:string;
p:pchar;
findData: WIN32_FIND_DATAW;
ws:widestring;
systime_:systemtime;
filetime_:filetime;
path:string;
//
sftp_handle:PLIBSSH2_SFTP_HANDLE=nil;
i:integer;
mem:array [0..1023] of char;
longentry:array [0..511] of char;
attrs:LIBSSH2_SFTP_ATTRIBUTES;
begin
result:=2;
//

path := WideCharToString(filename);
path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
if path='' then ;

log('***************************************');
log('_FindFiles');
log(path);

//
log('libssh2_sftp_opendir');
log('path:'+path);
    sftp_handle := libssh2_sftp_opendir(sftp_session, pchar(path));
    if sftp_handle=nil then
          begin
          log('cannot libssh2_sftp_opendir:'+path,1);
          exit;
          end;
    while 1=1 do
      begin
       fillchar(mem,sizeof(mem),0);
       FillChar (findData ,sizeof(findData ),0);
       i := libssh2_sftp_readdir_ex(sftp_handle, @mem[0], sizeof(mem),longentry, sizeof(longentry), @attrs);
       if i>0 then
         begin
         log(strpas(@mem[0])+':'+inttostr(attrs.filesize));
         if ((attrs.flags and LIBSSH2_SFTP_ATTR_SIZE)=LIBSSH2_SFTP_ATTR_SIZE) then
         begin
         if (attrs.permissions and LIBSSH2_SFTP_S_IFMT) = LIBSSH2_SFTP_S_IFDIR
         //if (attrs.filesize=4096)
            then findData.dwFileAttributes := FILE_ATTRIBUTE_DIRECTORY
            else findData.dwFileAttributes := FILE_ATTRIBUTE_NORMAL;
         {
         if findData.dwFileAttributes=FILE_ATTRIBUTE_DIRECTORY
            then DokanFileInfo.isdirectory:=true
            else DokanFileInfo.isdirectory:=false;
         }
         findData.nFileSizeHigh :=LARGE_INTEGER(attrs.filesize).HighPart;
         findData.nFileSizeLow  :=LARGE_INTEGER(attrs.filesize).LowPart;
         end;
         //
         DateTimeToSystemTime(UNIXTimeToDateTimeFAST(attrs.atime ),systime_);
         SystemTimeToFileTime(systime_ ,filetime_);
         findData.ftCreationTime :=filetime_ ;
         DateTimeToSystemTime(UNIXTimeToDateTimeFAST(attrs.atime ),systime_);
         SystemTimeToFileTime(systime_ ,filetime_);
         findData.ftLastAccessTime :=filetime_ ;
         DateTimeToSystemTime(UNIXTimeToDateTimeFAST(attrs.mtime ),systime_);
         SystemTimeToFileTime(systime_ ,filetime_);
         findData.ftLastWriteTime :=filetime_ ;
         //
         ws:=widestring(strpas(@mem[0]));
         Move(ws[1],  findData.cFileName,Length(ws)*Sizeof(Widechar));
         FillFindData(findData, DokanFileInfo);
         end
         else break;
      end; //while 1=1 do
    libssh2_sftp_closedir(sftp_handle);

Result := STATUS_SUCCESS;
end;

//invalid folder name if not implemented correctly
function _GetFileInformation(
    FileName: LPCWSTR; var HandleFileInformation: BY_HANDLE_FILE_INFORMATION;
    var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  handle: THandle;
  error: DWORD;
  find: WIN32_FIND_DATAW;
  findHandle: THandle;
  opened: Boolean;
  //
  path:string;

  systime_:systemtime;
  filetime_:filetime;

  attrs:LIBSSH2_SFTP_ATTRIBUTES;

  rc:integer;
begin
  result:=STATUS_NO_SUCH_FILE;

  path := WideCharToString(filename);
  path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
  //if path='/' then begin exit;end;

  log('***************************************');
  log('_GetFileInformation');
  log(path);

  //writeln(DokanFileInfo.IsDirectory );

    log('libssh2_sftp_stat');
    rc:= libssh2_sftp_stat(sftp_session,pchar(path),@attrs) ;
    if rc=0 then
          begin
          //if LIBSSH2_SFTP_S_ISDIR() ... macro ...
          //or flags ?
          if (attrs.permissions and LIBSSH2_SFTP_S_IFMT) = LIBSSH2_SFTP_S_IFDIR
          //if attrs.filesize =4096 //tricky ...
             then HandleFileInformation.dwFileAttributes := FILE_ATTRIBUTE_DIRECTORY
             else HandleFileInformation.dwFileAttributes := FILE_ATTRIBUTE_NORMAL ;
          if HandleFileInformation.dwFileAttributes=FILE_ATTRIBUTE_DIRECTORY
             then DokanFileInfo.isdirectory:=true
             else DokanFileInfo.isdirectory:=false;
          HandleFileInformation.nFileSizeHigh := LARGE_INTEGER(attrs.filesize ).highPart;
          HandleFileInformation.nFileSizeLow := LARGE_INTEGER(attrs.filesize).LowPart;
          DateTimeToSystemTime(UNIXTimeToDateTimeFAST(attrs.atime ),systime_);
          SystemTimeToFileTime(systime_ ,filetime_);
          HandleFileInformation.ftLastAccessTime  :=filetime_ ;
          DateTimeToSystemTime(UNIXTimeToDateTimeFAST(attrs.mtime),systime_);
          SystemTimeToFileTime(systime_ ,filetime_);
          HandleFileInformation.ftLastWriteTime :=filetime_ ;
          //
          Result := STATUS_SUCCESS;
          end;
          //else log('cannot libssh2_sftp_stat for:'+path,1);


  end;



function _ReadFile(FileName: LPCWSTR; var Buffer;
                        BufferLength: DWORD;
                        var ReadLength: DWORD;
                        Offset: LONGLONG;
                        var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  handle: THandle;
  offset_: ULONG;
  opened: Boolean;
  error: DWORD;
  distanceToMove: LARGE_INTEGER;
  //
  path:string;
  sftp_handle:PLIBSSH2_SFTP_HANDLE=nil;
  rc:integer;
  ptr:pointer;
begin
  result:=STATUS_NO_SUCH_FILE;


  path := WideCharToString(filename);
  path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
  if path='/' then begin exit;end;

  log('***************************************');
  log('_ReadFile');
  log(path);

  if DokanFileInfo.isdirectory=true then exit;

  if DokanFileInfo.Context <>0 then sftp_handle :=pointer(DokanFileInfo.Context);
  if DokanFileInfo.Context =0 then
     begin
     log('libssh2_sftp_open');
     //* Request a file via SFTP */
     sftp_handle :=libssh2_sftp_open(sftp_session, pchar(path), LIBSSH2_FXF_READ, 0);
     DokanFileInfo.Context:=integer(sftp_handle);
    end;

    if sftp_handle=nil then
          begin
          log('cannot libssh2_sftp_open:'+path,1);
          exit;
          end;

    //while 1=1 do
    //  begin
       log('libssh2_sftp_seek:'+inttostr(offset));
       libssh2_sftp_seek(sftp_handle,offset);

       log('BufferLength:'+inttostr(BufferLength));
       ReadLength :=0;
       ptr:=@buffer;
       while rc>0 do
         begin
         log('libssh2_sftp_read');
         //seems that max readlength is 30000 bytes...so lets loop
         rc := libssh2_sftp_read(sftp_handle, ptr, min(4096*4,bufferlength));
         if rc<=0 then break;
         inc(ReadLength ,rc);
         inc(nativeuint(ptr),rc);
         dec(bufferlength,rc);
         end;
       log('bytes read:'+inttostr(ReadLength));
       if ReadLength>0
          then Result := STATUS_SUCCESS
          else log('libssh2_sftp_read failed:'+path,1);

      //end; //while 1=1 do



end;

function _WriteFile(FileName: LPCWSTR; const Buffer;
                         NumberOfBytesToWrite: DWORD;
                         var NumberOfBytesWritten: DWORD;
                         Offset: LONGLONG;
                         var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  filePath: WCHAR_PATH;
  handle: THandle;
  opened: Boolean;
  error: DWORD;
  fileSize: UINT64;
  fileSizeLow: DWORD;
  fileSizeHigh: DWORD;
  z: LARGE_INTEGER;
  bytes: UINT64;
  distanceToMove: LARGE_INTEGER;
  //
  path:string;
  sftp_handle:PLIBSSH2_SFTP_HANDLE=nil;
  ptr:pointer;
  rc:integer;
begin

  log('***************************************');
  log('_WriteFile');

  result:=STATUS_NO_SUCH_FILE;

  path := WideCharToString(filename);
  path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
  if path='/' then begin exit;end;

  log(path);

  if DokanFileInfo.Context <>0 then sftp_handle :=pointer(DokanFileInfo.Context);
    if DokanFileInfo.Context =0 then
       begin
       log('libssh2_sftp_open');
       //* Request a file via SFTP */
       sftp_handle :=libssh2_sftp_open(sftp_session, pchar(path), LIBSSH2_FXF_WRITE or LIBSSH2_FXF_CREAT or LIBSSH2_FXF_TRUNC,
                          LIBSSH2_SFTP_S_IRUSR or LIBSSH2_SFTP_S_IWUSR or
                          LIBSSH2_SFTP_S_IRGRP or LIBSSH2_SFTP_S_IROTH);
       DokanFileInfo.Context:=integer(sftp_handle);
      end;

      if sftp_handle=nil then
            begin
            log('cannot libssh2_sftp_open',1);
            exit;
            end;

  log('libssh2_sftp_seek:'+inttostr(offset));
  libssh2_sftp_seek(sftp_handle,offset);

  log('NumberOfBytesToWrite:'+inttostr(NumberOfBytesToWrite));
  NumberOfBytesWritten :=0;
  //NumberOfBytesWritten := libssh2_sftp_write(sftp_handle, @buffer, NumberOfBytesToWrite);
  //windows seems to be smart enough if NumberOfBytesWritten<NumberOfBytesToWrite
  //still we could/should it properly (code below to be reviewed)

  ptr:=@buffer;
  while rc>0 do
    begin
    log('libssh2_sftp_write');
    rc := libssh2_sftp_write(sftp_handle, ptr, min(4096*4,NumberOfBytesToWrite));
    if rc<=0 then break;
    //writeln(rc);
    inc(NumberOfBytesWritten,rc);
    //writeln(NumberOfBytesWritten);
    inc(nativeuint(ptr),rc);
    dec(NumberOfBytesToWrite,rc);
    //writeln(NumberOfBytesToWrite);
    //writeln('.............');
    end;

  log('bytes written:'+inttostr(NumberOfBytesWritten));

  if NumberOfBytesWritten>0
     then Result := STATUS_SUCCESS
     else log('libssh2_sftp_write failed',1);


end;

function _MoveFile(FileName: LPCWSTR; // existing file name
               NewFileName: LPCWSTR; ReplaceIfExisting: BOOL;
               var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  old_path,new_path:string;
begin

  log('***************************************');
  log('_MoveFile');

  old_path := WideCharToString(filename);
  old_path:=stringreplace(old_path,'\','/',[rfReplaceAll, rfIgnoreCase]);
  new_path := WideCharToString(NewFileName);
  new_path:=stringreplace(new_path,'\','/',[rfReplaceAll, rfIgnoreCase]);

  log('libssh2_sftp_rename');
  if libssh2_sftp_rename (sftp_session,pchar(old_path),pchar(new_path ))=0
     then result:=STATUS_SUCCESS
     else result:=STATUS_NO_SUCH_FILE ;


end;

procedure _Cleanup(FileName: LPCWSTR;
                        var DokanFileInfo: DOKAN_FILE_INFO); stdcall;
var
   path:string;
   rc:integer;
begin
//

  log('***************************************');
  log('_Cleanup');

path := WideCharToString(filename);
 path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
 if path='/' then begin exit;end;

 log(path);

 if DokanFileInfo.DeleteOnClose=true then
   begin
   if DokanFileInfo.IsDirectory =false then
     begin
     log('libssh2_sftp_unlink');
      rc:=libssh2_sftp_unlink(sftp_session ,pchar(path));
      if rc<>0 then log('libssh2_sftp_unlink failed',1)
     end
     else
     //is a directory
     begin
     log('libssh2_sftp_rmdir');
     rc:=libssh2_sftp_rmdir(sftp_session ,pchar(path));
     if rc<>0 then log('libssh2_sftp_rmdir failed',1)
     end;//if DokanFileInfo.IsDirectory =false then
   end;//if DokanFileInfo.DeleteOnClose=true then
  end;
//

procedure _CloseFile(FileName: LPCWSTR;
                          var DokanFileInfo: DOKAN_FILE_INFO); stdcall;
var
  path:string;
begin

  path := WideCharToString(filename);
  path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);

  log('***************************************');
  log('_CloseFile');
  log(path);

 if DokanFileInfo.Context <>0 then
   begin
   log('libssh2_sftp_close');
   libssh2_sftp_close(pointer(DokanFileInfo.Context ));
   DokanFileInfo.Context := 0;
   end;

end;
//

function _CreateFile(FileName: LPCWSTR; var SecurityContext: DOKAN_IO_SECURITY_CONTEXT;
                 DesiredAccess: ACCESS_MASK; FileAttributes: ULONG;
                 ShareAccess: ULONG; CreateDisposition: ULONG;
                 CreateOptions: ULONG; var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var

  fileAttr: DWORD;
  status: NTSTATUS;
  creationDisposition: DWORD;
  fileAttributesAndFlags: DWORD;
  error: DWORD;
  genericDesiredAccess: ACCESS_MASK;
  path:string;
  rc:integer;
begin

  result := STATUS_SUCCESS;


 log('***************************************');
 log('_CreateFile');

 path := WideCharToString(filename);
 path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
 if path='/' then begin exit;end;

 log(path);

    DokanMapKernelToUserCreateFileFlags(
      DesiredAccess, FileAttributes, CreateOptions, CreateDisposition,
      @genericDesiredAccess, @fileAttributesAndFlags, @creationDisposition);

 if (creationDisposition = CREATE_NEW) then
       begin
       if DokanFileInfo.IsDirectory =true then
             begin
             log('libssh2_sftp_mkdir');
             rc:=libssh2_sftp_mkdir(sftp_session ,pchar(path),
                            LIBSSH2_SFTP_S_IRWXU or
                            LIBSSH2_SFTP_S_IRGRP or LIBSSH2_SFTP_S_IXGRP or
                            LIBSSH2_SFTP_S_IROTH or LIBSSH2_SFTP_S_IXOTH);
             if rc<>0 then log('libssh2_sftp_mkdir failed',1)
             end
             else//if DokanFileInfo.IsDirectory =true then
             begin
             log('libssh2_sftp_open');
             //DokanFileInfo.Context:=integer(...
             if libssh2_sftp_open (sftp_session,pchar(path),LIBSSH2_FXF_CREAT,
                          LIBSSH2_SFTP_S_IRUSR or LIBSSH2_SFTP_S_IWUSR or
                          LIBSSH2_SFTP_S_IRGRP or LIBSSH2_SFTP_S_IROTH) =nil then log('libssh2_sftp_open failed',1)
             end; //if DokanFileInfo.IsDirectory =true then
       end;//if (creationDisposition = CREATE_NEW) then

end;

//cleanup is called instead
Function _DeleteFile (FileName: LPCWSTR;var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  path:string;
  rc:integer;
begin
 result := STATUS_NO_SUCH_FILE;

 log('***************************************');
 log('_DeleteFile');

 path := WideCharToString(filename);
 path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
 log('libssh2_sftp_unlink');
 rc:=libssh2_sftp_unlink(sftp_session ,pchar(path));
 if rc<>0
    then log('libssh2_sftp_unlink failed',1)
    else result := STATUS_SUCCESS;
end;

//cleanup is called instead
function _DeleteDirectory(FileName: LPCWSTR;var DokanFileInfo: DOKAN_FILE_INFO): NTSTATUS; stdcall;
var
  path:string;
  rc:integer;
begin
 result := STATUS_NO_SUCH_FILE;

 log('***************************************');
 log('_DeleteDirectory');

 path := WideCharToString(filename);
 path:=stringreplace(path,'\','/',[rfReplaceAll, rfIgnoreCase]);
 log('libssh2_sftp_rmdir');
 rc:=libssh2_sftp_rmdir(sftp_session ,pchar(path));
 if rc<>0
    then log('libssh2_sftp_rmdir failed',1)
    else result := STATUS_SUCCESS;
end;

//previous version was using synapse
//lets switch to winsock2
function init_socket(var sock_:tsocket):boolean;
var
wsadata:TWSADATA;
err:longint;
hostaddr:u_long;
sin:sockaddr_in;
begin
  result:=false;
  //
  err := WSAStartup(MAKEWORD(2, 0), wsadata);
  if(err <> 0) then raise exception.Create ('WSAStartup failed with error: '+inttostr(err));
  //
  hostaddr := inet_addr(pchar(host));
  //
  sock_ := socket(AF_INET, SOCK_STREAM, 0);
  //
  sin.sin_family := AF_INET;
  sin.sin_port := htons(22);
  sin.sin_addr.s_addr := hostaddr;
  if connect(sock_, tsockaddr(sin), sizeof(sockaddr_in)) <> 0
     then raise exception.Create ('failed to connect');
  //
  result:=true;

end;


function _Mount(rootdirectory:pwidechar):boolean;stdcall;
var
i:integer;
fingerprint,userauthlist:PAnsiChar;
List: TStrings;
begin
result:=false;

//
debug:=false;
//

log ('******** proxy loaded ********',1);
log('rootdirectory:'+strpas(rootdirectory),1);

List := TStringList.Create;
ExtractStrings([':'], [], PChar(string(strpas(rootdirectory))), List);
if list.Count =3 then
      begin
      username:=list[0];
      password:=list[1];
      host:=list[2];
      end;
List.Free;

if host='' then begin log('host is empty',1);exit; end;

if init_socket(sock)=false then raise exception.Create ('sock error');

    log('libssh2_init...');
    if libssh2_init(0)<>0 then
      begin
      log('Cannot libssh2_init',1);
      exit;
      end;
    { /* Create a session instance and start it up. This will trade welcome
         * banners, exchange keys, and setup crypto, compression, and MAC layers
         */
         }
    log('libssh2_session_init...');
    session := libssh2_session_init();

    //* tell libssh2 we want it all done non-blocking */
    //libssh2_session_set_blocking(session, 0);

    log('libssh2_session_startup...');
    if libssh2_session_startup(session, sock)<>0 then
      begin
      log('Cannot establishing SSH session',1);
      exit;
      end;

    //
    {
    if libssh2_session_handshake(session, sock.socket)<>0 then
      begin
      writeln('Cannot libssh2_session_handshake');
      exit;
      end;
    }
    //
    //writeln(libssh2_trace(session,LIBSSH2_TRACE_ERROR or LIBSSH2_TRACE_CONN or LIBSSH2_TRACE_TRANS or LIBSSH2_TRACE_SOCKET));
    log('libssh2_version:'+libssh2_version(0));
    //
    {
    /* At this point we havn't authenticated. The first thing to do is check
     * the hostkey's fingerprint against our known hosts Your app may have it
     * hard coded, may go to a file, may present it to the user, that's your
     * call
     */
    }
    log('libssh2_hostkey_hash...');
    fingerprint := libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA1);
    if fingerprint=nil then begin log('no fingerpint',1);exit;end;
    log('Host fingerprint ');
    i:=0;
    //while fingerprint[i]<>#0 do
    for i:=0 to 19 do
      begin
      tmp:=tmp+inttohex(ord(fingerprint[i]),2)+':';
      //i:=i+1;
      end;
    log(tmp);
    log('Assuming known host...');
    //
    log('libssh2_userauth_list...');
    userauthlist := libssh2_userauth_list(session, pchar(username), strlen(pchar(username)));
    log(strpas(userauthlist));
    //
    log('libssh2_userauth_password...');
    if libssh2_userauth_password(session, pchar(username), pchar(password))<>0 then
      begin
      log('Authentication by password failed',1);
      exit;
      end;
    log('Authentication succeeded');

    log('libssh2_sftp_init...');
    sftp_session := libssh2_sftp_init(session);
    if sftp_session=nil then
      begin
      log('cannot libssh2_sftp_init',1);
      exit;
      end;

    //* Since we have not set non-blocking, tell libssh2 we are blocking */
     libssh2_session_set_blocking(session, 1);

     result:=true;
end;

function _unMount: ntstatus;stdcall;
begin

    libssh2_sftp_shutdown(sftp_session);

    libssh2_session_disconnect(session, 'bye');
    libssh2_session_free(session);

    closesocket(sock);

    libssh2_exit();

  result:=STATUS_SUCCESS;
end;


end.
 
