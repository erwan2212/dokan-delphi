Create your own filesystem and mount it as either a logical drive or folder.
Dokan (https://github.com/dokan-dev/dokany) <br/>


Dokan is built against VC 2017 (you need the VC2017 runtime - see installation.txt).<br/>

Below a simple command line to mount a zip archive on X:<br/>
mount.exe /r test.zip /l x /x proxy_7zip.dll <br/>

Mount.exe is a generic code/binary independant of the filesystem you wish to create. <br/>
The filesystem is implemented in a proxy/dll. <br/>

7zip proxy example is here : https://github.com/erwan2212/dokan-delphi/tree/master/Samples/Proxy_7zip . <br/>
NFS proxy example is here : https://github.com/erwan2212/dokan-delphi/tree/master/Samples/Proxy_NFS . <br/> 
Libzip proxy example is here : https://github.com/erwan2212/dokan-delphi/tree/master/Samples/Proxy_LibZip . <br/>
SFTP proxy example is here : https://github.com/erwan2212/dokan-delphi/tree/master/Samples/Proxy_SFTP . <br/>

![Screenshot](screenshot.png)


