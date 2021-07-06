program gmanager;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  cmem,
  {$ENDIF}
  Classes, SysUtils, DateUtils, CustApp, IniFiles, FPTimer ,IdContext, IdGlobal, IdComponent, IdCustomTCPServer, IdThreadSafe, IdSync,
  IdTCPConnection, IdTCPServer, IdSocketHandle, functions;

type

  TBanDate=class
    FReleaseDate: TDateTime;
  published
    property BanDate: TDateTime read FReleaseDate write FReleaseDate;
  end;


  TMessageDataProc = procedure(const mBuffer: String) of object;

  TMessageNotify = class(TidNotify)
    private
      fData: string;
      fProc: TMessageDataProc;
    protected
      procedure DoNotify; override;
    public
      constructor Create(const msgBuffer: String; msgProc: TMessageDataProc);
    end;

  TClientInfo = class(TObject)
  public
    LoggedIn: Boolean;
    LastDate: TDateTime;
    LoginAttempts: Integer;
  end;

  TGlimpseManager = class(TCustomApplication)
    procedure IdTCPServer1Connect(AContext: TIdContext);
    procedure IdTCPServer1Execute(AContext: TIdContext);
    procedure IdTCPServer1Disconnect(AContext: TIdContext);
    procedure ShowMessage(const msgData:String);
    procedure msgDisplay(p_sender, p_message: string);
    procedure broadcastMessage(p_message : string);
    function CheckBlockedIP(const ipaddress:String):integer;
    procedure AddBlockedIP(const ipaddress:String; const seconds:integer);
    procedure RemoveBlockedIP(const ipaddress:String);
    function GetBlockedIPList:String;
    procedure CleanBlockedIPs;
  protected
    procedure DoRun; override;
  public
    appName          : String;
    appRunning       : Boolean;
    dataPlaceholder  : String;
    checkIPS         : Boolean;
    doWhitelist      : Boolean;
    doBanlist        : Boolean;
    showDebug        : Boolean;
    bindIP           : String;
    logDir           : String;
    logFile          : String;
    doLogFile        : Boolean;
    bindPort         : Integer;
    serverPassword   : String;
    maxLoginAttempts : Integer;
    whiteListFile    : String;
    banListFile      : String;
    whiteListFormat  : String;
    banListFormat    : String;
    whiteListDelim   : String;
    banListDelim     : String;
    banTime          : Integer;
    loginTime        : Integer;
    idleTime         : Integer;
    WorkTimer        : TFPTimer;
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
    procedure ProcessSettingsFile(filename:string);
    function ProcessCLine:boolean;
    procedure WorkTimerExec( Sender : TObject );
  end;

Var
  IdTCPServer1 : TIdTCPServer;
  ipblocksCS   : TRTLCriticalSection;
  logCS        : TRTLCriticalSection;
  allowedIPS   : TStringlist;
  blockedIPS   : TStringlist;


  constructor TMessageNotify.Create(const msgBuffer: String; msgProc: TMessageDataProc);
  begin
    inherited Create;
    fData := msgBuffer;
    fProc := msgProc;
  end;

  procedure TMessageNotify.DoNotify;
  begin
    fProc(fData);
  end;


{ TGlimpseManager }

function TGlimpseManager.CheckBlockedIP(const ipaddress:String):integer;
begin
  EnterCriticalSection(ipblocksCS);
  try
      result := blockedIPS.IndexOf(ipaddress);
  finally
    LeaveCriticalSection(ipblocksCS);
  end;
end;


function TGlimpseManager.GetBlockedIPList:String;
var
  tmpStr  : String;
  idx     : integer;
begin
  tmpStr := '';
  EnterCriticalSection(ipblocksCS);
  try
      for idx := 0 to blockedIPS.Count-1 do
        begin
          tmpStr := tmpStr + blockedIPS[idx] + ':' + FormatDateTime('yyyy/mm/dd-hh:mm:ss',TBanDate(blockedIPS.Objects[idx]).BanDate);
          if(idx<blockedIPS.Count-1) then tmpStr := tmpStr + ',';
        end;
  finally
    LeaveCriticalSection(ipblocksCS);
    result := tmpStr;
  end;
end;



procedure TGlimpseManager.AddBlockedIP(const ipaddress:String; const seconds:integer);
var
  newDate : TBanDate;
begin
  EnterCriticalSection(ipblocksCS);
  try
    newDate := TBanDate.Create;
    newDate.BanDate := IncSecond(now,seconds);
    blockedIPS.AddObject(ipaddress,newDate);
  finally
    LeaveCriticalSection(ipblocksCS);
  end;
end;


procedure TGlimpseManager.RemoveBlockedIP(const ipaddress:String);
var
  idx : integer;
begin
  EnterCriticalSection(ipblocksCS);
  try
    idx := blockedIPS.IndexOf(ipaddress);
    if(idx>-1) then
      begin
        blockedIPS.Objects[idx].Free;
        blockedIPS.Delete(idx);
      end;
  finally
    LeaveCriticalSection(ipblocksCS);
  end;
end;


procedure TGlimpseManager.CleanBlockedIPs;
var
  theDate : TBanDate;
  idx : Integer;
begin
  EnterCriticalSection(ipblocksCS);
  try
     for idx := blockedIPS.Count-1 downto 0 do
     begin
       theDate := TBanDate(blockedIPS.Objects[idx]);
       if(CompareDateTime(theDate.BanDate,now) <= 0) then
         begin
           blockedIPS.Objects[idx].Free;
           blockedIPS.Delete(idx);
         end;
     end;
  finally
    LeaveCriticalSection(ipblocksCS);
  end;
end;


procedure TGlimpseManager.ShowMessage(const msgData:String);
begin
    writeln(msgData);
end;


procedure TGlimpseManager.msgDisplay(p_sender, p_message: string);
var
  sBuffer: String;
begin
  sBuffer := getNowStr() + ' [' + p_sender + '] - ' + ': ' + p_message;
  if showDebug then begin;
     TMessageNotify.Create(sBuffer, @ShowMessage).Notify();
  end;
  if (doLogFile) then
    begin
      EnterCriticalSection(logCS);
        with TStringList.create do
        try
          if fileexists(logDir + DirectorySeparator + logFile) then LoadFromFile(logDir + DirectorySeparator + logFile);
          Add(sBuffer);
          SaveToFile(logDir + DirectorySeparator + logFile);
        finally
          Free;
          LeaveCriticalSection(logCS);
        end;
    end;
end;


procedure TGlimpseManager.WorkTimerExec(Sender:TObject);
var
  tmpList      : TList;
  contexClient : TidContext;
  i            : integer;
  tSeconds     : integer;
  peerIP      : string;
  peerPort    : Integer;

begin
  CleanBlockedIPs;

  tmpList  := IdTCPServer1.Contexts.LockList;
    try
        i := 0;
        while ( i < tmpList.Count ) do begin
            contexClient := TidContext(tmpList[i]);
            tSeconds := SecondsBetween(TClientInfo(contexClient.Data).LastDate,Now);
            if(NOT TClientInfo(contexClient.Data).LoggedIn) then
              begin
                if(tSeconds>=loginTime) then
                  begin
                    peerIP    := contexClient.Binding.PeerIP;
                    peerPort  := contexClient.Binding.PeerPort;
                    TClientInfo(contexClient.Data).LastDate := now;
                    contexClient.Connection.IOHandler.WriteLn('Inactivity Timeout.');
                    msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Login Inactivity Timeout.');
                    sleep(100);
                    contexClient.Connection.Disconnect;
                  end;
              end
             else
              Begin
                if(tSeconds>=idleTime) then
                  begin
                    peerIP    := contexClient.Binding.PeerIP;
                    peerPort  := contexClient.Binding.PeerPort;
                    TClientInfo(contexClient.Data).LastDate := now;
                    contexClient.Connection.IOHandler.WriteLn('Inactivity Timeout.');
                    msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Idle Timeout.');
                    sleep(100);
                    contexClient.Connection.Disconnect;
                  end;
              end;
            i := i + 1;
        end;
    finally
        IdTCPServer1.Contexts.UnlockList;
    end;
end;

procedure TGlimpseManager.DoRun;
var
   SettingsFile : string;
begin
    SettingsFile:= ExtractFilePath(ExeName)+'gmanager.cnf';
    InitCriticalSection(ipblocksCS);
    InitCriticalSection(logCS);
    blockedIPS := TStringlist.Create;
    WorkTimer := TFPTimer.Create(nil);
    WorkTimer.enabled := false;
    WorkTimer.interval := 1000;
    WorkTimer.onTimer := @WorkTimerExec;
    logFile := FormatDateTime('yyyymmddhhmmss',now) + '.txt';
    appRunning := true;
    dataPlaceholder := '@DATA@';
    bindIP := '0.0.0.0';
    bindPort := 2400;
    serverPassword:= '';
    maxLoginAttempts:= 3;
    banTime := 300;
    loginTime := 10;
    idleTime := 10;
    showDebug := false;
    doWhitelist := true;
    doBanlist := true;
    checkIPS := false;
    doLogFile := false;
    whiteListFormat := dataPlaceholder;
    banListFormat := dataPlaceholder;
    whiteListDelim :=' ';
    banListDelim :=' ';
    logDir := '';

    if(fileexists(SettingsFile)) then
      Begin
        ProcessSettingsFile(SettingsFile);
      end
    else
    if NOT ProcessCLine then
       begin
          try
          Terminate;
          Exit;
          except
             writeln('Command line exception.');
          end;
       end;

    try
       IdTCPServer1 := TIdTCPServer.Create(self);
       IdTCPServer1.Active          := False;
       IdTCPServer1.MaxConnections  := 20;
       IdTCPServer1.OnConnect       := @IdTCPServer1Connect;
       IdTCPServer1.OnExecute       := @IdTCPServer1Execute;
       IdTCPServer1.OnDisconnect    := @IdTCPServer1Disconnect;
       IdTCPServer1.Bindings.Clear;
       with IdTCPServer1.Bindings.Add do
         begin
           IP := bindIP;
           Port := bindPort;
           IPVersion := Id_IPv4;
         end;
       IdTCPServer1.Active   := true;
       WorkTimer.enabled     := true;
       while appRunning do
        begin
          sleep(10);
          CheckSynchronize;
        end;
    except
       writeln('Error starting server.');
    end;
    WorkTimer.enabled     := true;
    if Assigned(WorkTimer) then WorkTimer.Free;
    if Assigned(allowedIPS) then allowedIPS.Free;
    if Assigned(blockedIPS) then blockedIPS.Free;
    DoneCriticalSection(ipblocksCS);
    DoneCriticalSection(logCS);
    Terminate;
    Exit;

end;

procedure TGlimpseManager.IdTCPServer1Connect(AContext: TIdContext);
var
    peerIP      : string;
    peerPort    : Integer;
begin
    peerIP    := AContext.Binding.PeerIP;
    peerPort  := AContext.Binding.PeerPort;
    if (NOT appRunning) then
     begin
       AContext.Connection.Disconnect;
       exit;
     end;
    CleanBlockedIPs;
    msgDisplay('SERVER', 'Client Connected!');
    msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Connected.');
    if(checkIPS) then
      if(allowedIPS.IndexOf(PeerIP)=-1) then
        begin
          msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] IP not allowed, disconnecing.');
          AContext.Connection.IOHandler.WriteLn( 'IP not approved, disconnecting.' );
          sleep(10);
          AContext.Connection.Disconnect;
          exit;
        end;
    if (CheckBlockedIP(PeerIP)>-1) then
      begin
        msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] IP Banned, disconnecing.');
        AContext.Connection.IOHandler.WriteLn( 'IP Banned, disconnecting.' );
        sleep(10);
        AContext.Connection.Disconnect;
        exit;
      end;
    AContext.Data := TClientInfo.Create;
    TClientInfo(AContext.Data).LoggedIn := false;
    TClientInfo(AContext.Data).LastDate := Now;
    TClientInfo(AContext.Data).LoginAttempts := 0;
    AContext.Connection.IOHandler.WriteLn( 'Please enter password:' );
end;

procedure TGlimpseManager.IdTCPServer1Execute(AContext: TIdContext);
var
  PeerPort      : Integer;
  PeerIP        : string;
  msgFromClient : string;
  UserLine      : TStringArray;
  commandLine   : TStringArray;
  tmpList       : TStringList;
  idx           : integer;
  i             : integer;
  tmpInt        : integer;
  Users         : TStringList;
begin
  peerIP   := AContext.Binding.PeerIP;
  peerPort := AContext.Binding.PeerPort;
  AContext.Connection.IOHandler.CheckForDisconnect;
  msgFromClient := AContext.Connection.IOHandler.ReadLn;
  TClientInfo(AContext.Data).LastDate := Now;
  if(TClientInfo(AContext.Data).LoggedIn = false) then
    Begin
      msgDisplay('CLIENT', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] ' + msgFromClient);
      if msgFromClient = serverPassword then
         Begin
              TClientInfo(AContext.Data).LoggedIn := true;
              AContext.Connection.IOHandler.WriteLn('Logon successful.');
              msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Logon successful.');
              AContext.Connection.IOHandler.WriteLn('*** Connected to ' + Title);
         end
         else
         Begin
              inc(TClientInfo(AContext.Data).LoginAttempts);
              msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Failed login.');
              if(TClientInfo(AContext.Data).LoginAttempts>= MaxLoginAttempts) then
                 Begin
                      AContext.Connection.IOHandler.WriteLn('Max failed logins reached, disconnecting....');
                      msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Disconnected due to max failed logins.');
                      AddBlockedIP(PeerIP, banTime);
                      AContext.Connection.Disconnect;
                 end
              else AContext.Connection.IOHandler.WriteLn('Password incorrect, please enter password ('+IntToStr(TClientInfo(AContext.Data).LoginAttempts)+'):');
         end;
    end
    else
    Begin
      msgDisplay('CLIENT', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Command Line : ' + msgFromClient);
      commandLine := msgFromClient.Split(' ');
      case StringIndex(commandLine[0], ['quit', 'shutdown', 'help', 'whitelist', 'banlist','ipban'], false) of
           0: begin // QUIT
              msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Disconnected due to quit command.');
              AContext.Connection.Disconnect;
           end;
           1: begin // SHUTDOWN
              IdTCPServer1.Stoplistening;
              broadcastMessage( Title + ' shutting down!');
              appRunning := false;
              exit;
           end;
           2: begin // Help
              AContext.Connection.IOHandler.writeln('-----------------------------------------------------------------------------');
              AContext.Connection.IOHandler.writeln(Title);
              AContext.Connection.IOHandler.writeln('-----------------------------------------------------------------------------');
              AContext.Connection.IOHandler.writeln('Verfied Client Commands');
              AContext.Connection.IOHandler.writeln('---------------------------------');
              AContext.Connection.IOHandler.writeln('whitelist list        | Lists all items in whitelist file.');
              AContext.Connection.IOHandler.writeln('whitelist add <id>    | Where <id> is username or SteamID to add.');
              AContext.Connection.IOHandler.writeln('whitelist remove <id> | Where <id> is username or SteamID to remove.');
              AContext.Connection.IOHandler.writeln('banlist list          | Lists all items in banlist file.');
              AContext.Connection.IOHandler.writeln('banlist add <id>      | Where <id> is username or SteamID to add.');
              AContext.Connection.IOHandler.writeln('banlist remove <id>   | Where <id> is username or SteamID to remove.');
              AContext.Connection.IOHandler.writeln('ipban list            | Show IPs that are banned Banned.');
              AContext.Connection.IOHandler.writeln('ipban add <ip> <time> | Where <ip> is ip address to ban, <time>(optional) is seconds to ban. Defaults to bantime setting.');
              AContext.Connection.IOHandler.writeln('ipban remove <ip>     | Where <ip> is ip address to remove.');
              AContext.Connection.IOHandler.writeln('-----------------------------------------------------------------------------');
              AContext.Connection.IOHandler.writeln('Copyright Glimpse Media LLC https://www.glimpse.me');
              AContext.Connection.IOHandler.writeln('-----------------------------------------------------------------------------');
              AContext.Connection.IOHandler.writeln('');
           end;

           3: begin // Whitelist
                if(NOT doWhitelist) then
                  Begin
                    AContext.Connection.IOHandler.WriteLn('Whitelist commands disabled.');
                    exit;
                  end;
                case StringIndex(commandLine[1], ['list', 'add', 'remove'], false) of
                  0: begin
                     msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: list');
                     Users := TStringList.Create;
                     Users.LoadFromFile(WhiteListFile);
                     if(Users.Count>0)then
                        Begin
                          AContext.Connection.IOHandler.WriteLn('Whitelisted users:');
                          for idx := 0 to Users.Count-1 do
                              AContext.Connection.IOHandler.WriteLn(Users[idx]);
                        end
                     else AContext.Connection.IOHandler.WriteLn('No users on whitelist, whitelist only mode not enabled.');
                     Users.Free;
                  end;
                  1: begin
                    msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: add');
                    try
                       Users := TStringList.Create;
                       Users.LoadFromFile(WhiteListFile);
                       idx:=-1;
                       for i := 0 to Users.Count-1 do
                           Begin
                              UserLine := Users[i].Split(whiteListDelim);
                              if(UserLine[0] = commandLine[2]) then
                                 begin
                                   AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' already in whitelist.');
                                   idx:=i;
                                   break;
                                 end;
                           end;
                       if (idx=-1) then
                          Begin
                               Users.Add(StringReplace(whiteListFormat, dataPlaceholder, commandLine[2], [rfIgnoreCase, rfReplaceAll]));
                               Users.SaveToFile(WhiteListFile);
                               Users.Free;
                               AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' added to whitelist.');
                          end;
                    except
                      AContext.Connection.IOHandler.WriteLn('Missing Params.');
                      Users.Free;
                      exit;
                    end;
                  end;
                  2: begin
                     if(NOT doBanlist) then
                       Begin
                         AContext.Connection.IOHandler.WriteLn('Banlist commands disabled.');
                         exit;
                       end;
                     msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: remove');
                     try
                        Users := TStringList.Create;
                        Users.LoadFromFile(WhiteListFile);
                        idx:=-1;
                        for i := 0 to Users.Count-1 do
                            Begin
                                 UserLine := Users[i].split(whiteListDelim);
                                 if(UserLine[0] = commandLine[2]) then
                                    begin
                                      idx := i;
                                      Users.Delete(i);
                                      Users.SaveToFile(WhiteListFile);
                                      Users.Free;
                                      AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' removed from whitelist.');
                                      break;
                                    end;
                            end;
                        if (idx=-1) then
                           Begin
                             AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' not in whitelist.');
                           end;
                     except
                       AContext.Connection.IOHandler.WriteLn('Missing Params.');
                       Users.Free;
                       exit;
                     end;
                  end;
                  else
                    AContext.Connection.IOHandler.WriteLn('Unknown Command.');
                end;
           end;

           4: begin // Banlist
                case StringIndex(commandLine[1], ['list', 'add', 'remove'], false) of
                  0: begin
                     msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: list');
                     Users := TStringList.Create;
                     Users.LoadFromFile(banListFile);
                     if(Users.Count>0)then
                        Begin
                          AContext.Connection.IOHandler.WriteLn('Banned users:');
                          for idx := 0 to Users.Count-1 do
                              AContext.Connection.IOHandler.WriteLn(Users[idx]);
                        end
                     else AContext.Connection.IOHandler.WriteLn('No users in Ban List.');
                     Users.Free;
                  end;
                  1: begin
                    msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: add');
                    try
                       Users := TStringList.Create;
                       Users.LoadFromFile(banListFile);
                       idx:=-1;
                       for i := 0 to Users.Count-1 do
                           Begin

                              UserLine := Users[i].Split(banListDelim);
                              if(UserLine[0] = commandLine[2]) then
                                 begin
                                   AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' already in ban list.');
                                   idx:=i;
                                   break;
                                 end;
                           end;
                       if (idx=-1) then
                          Begin
                               Users.Add(StringReplace(banListFormat, dataPlaceholder, commandLine[2], [rfIgnoreCase, rfReplaceAll]));
                               Users.SaveToFile(banListFile);
                               Users.Free;
                               AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' added to ban list.');
                          end;
                    except
                      AContext.Connection.IOHandler.WriteLn('Missing Params.');
                      Users.Free;
                      exit;
                    end;
                  end;
                  2: begin
                     msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] subCommand: remove');
                     try
                        Users := TStringList.Create;
                        Users.LoadFromFile(banListFile);
                        idx:=-1;
                        for i := 0 to Users.Count-1 do
                            Begin
                                 UserLine := Users[i].split(banListDelim);
                                 if(UserLine[0] = commandLine[2]) then
                                    begin
                                      idx := i;
                                      Users.Delete(i);
                                      Users.SaveToFile(banListFile);
                                      Users.Free;
                                      AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' removed from ban list.');
                                      break;
                                    end;
                            end;
                        if (idx=-1) then
                           Begin
                                AContext.Connection.IOHandler.WriteLn(commandLine[2] + ' not in ban list.');
                           end;
                     except
                       AContext.Connection.IOHandler.WriteLn('Missing Params.');
                       Users.Free;
                       exit;
                     end;
                  end;
                  else
                    AContext.Connection.IOHandler.WriteLn('Unknown Command.');
                end;
           end;

           5: begin // IP Blcoked List
              case StringIndex(commandLine[1], ['list', 'add', 'remove', 'clean'], false) of
                0: begin
                   msgDisplay('CLIENT', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] List Blocked IPs.');
                   tmpList := TStringlist.Create;
                   tmpList.CommaText := GetBlockedIPList;
                   if(tmpList.Count>0) then
                     begin
                       for idx := 0 to tmpList.Count-1 do
                         begin
                           AContext.Connection.IOHandler.WriteLn(tmpList[idx]);
                         end;
                     end
                     else AContext.Connection.IOHandler.WriteLn('No IPs in blocked list.');
                   tmpList.Free;
                end;
                1: begin
                     try
                       tmpInt := StrToInt(commandLine[3]);
                     except
                        begin
                          tmpInt := banTime;
                        end;
                     end;
                     msgDisplay('CLIENT', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Block IP: ' +commandLine[2]+ ' for ' + InttoStr(tmpInt) + ' seconds');
                     AddBlockedIP(commandLine[2],tmpInt);
                     AContext.Connection.IOHandler.WriteLn('Added IP to ban list');
                end;
                2: begin
                     msgDisplay('CLIENT', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Remove Blocked IP: ' +commandLine[2]+ '.');
                     RemoveBlockedIP(commandLine[2]);
                     AContext.Connection.IOHandler.WriteLn('Removed IP from ban list');
                end;
                3: begin
                     CleanBlockedIPs;
                     AContext.Connection.IOHandler.WriteLn('Cleaned IP ban list');
                end;
                else
                    AContext.Connection.IOHandler.WriteLn('Unknown Command.');
              end;
           end;
      else
        AContext.Connection.IOHandler.WriteLn('Unknown Command.');
      end;
    end;
end;


procedure TGlimpseManager.IdTCPServer1Disconnect(AContext: TIdContext);
var
  peerIP      : string;
  peerPort    : Integer;
begin
  peerIP    := AContext.Binding.PeerIP;
  peerPort  := AContext.Binding.PeerPort;
  AContext.Data.Free;
  AContext.Data := nil;
  msgDisplay('SERVER', '[' + PeerIP + ':' + IntToStr(PeerPort) + '] Client Disconnected!');
end;


procedure TGlimpseManager.broadcastMessage(p_message : string);
var
    tmpList      : TList;
    contexClient : TidContext;
    i            : integer;
begin
    tmpList  := IdTCPServer1.Contexts.LockList;
    try
        i := 0;
        while ( i < tmpList.Count ) do begin
            contexClient := TidContext(tmpList[i]);
            contexClient.Connection.IOHandler.WriteLn(p_message);
            i := i + 1;
        end;
    finally
        IdTCPServer1.Contexts.UnlockList;
    end;
end;


constructor TGlimpseManager.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;
end;

destructor TGlimpseManager.Destroy;
begin
  try
  inherited Destroy;
  except
  end;
end;

procedure TGlimpseManager.WriteHelp;
begin
  writeln('-----------------------------------------------------------------------------');
  writeln(Title);
  writeln('-----------------------------------------------------------------------------');
  writeln('Usage: gmanager <options>');
  writeln('Short options (single char) usage: -h "0.0.0.0"');
  writeln('Long options (multiple char) usage: --ip="0.0.0.0"');
  writeln('-----------------------------------------------------------------------------');
  writeln('-h, --help         | Display help.');
  writeln('-d, --debug        | Display debug information in console.');
  writeln('-h, --ip           | Set IP server will bind to, default is all interfaces "0.0.0.0"');
  writeln('-p, --port         | Set Port server will bind to, default is 2400');
  writeln('--password         | Set server password. If no password set, server will only bind 127.0.0.1 (localhost) - Min 3 characters');
  writeln('-w, --whitelist    | Full path to whitelist file. If path not set, or file not found whitelist functions will be disabled.');
  writeln('--whitelist-format | Format for whitelist entry. "@data@" will be replaced by username or SteamID. Default is "@data@", some games require a place holder for username eg. "@data@:Unknown"');
  writeln('-b, --banlist      | Full path to banlist file. If path not set, or file not found banlist functions will be disabled.');
  writeln('--banlist-format   | Format for banlist entry. "@data@" will be replaced by username or SteamID. Default "@data@".');
  writeln('--maxlogins        | Number of failed logins before disconnecting and banning ip for time period. Default 3.');
  writeln('--bantime          | Number of seconds ip will be banned after too many failed logins. Default 300 (5 min).');
  writeln('--logintimeout     | How long (in seconds) an unverified connection has to login before being disconnected. Default 10 seconds.');
  writeln('--idletimeout      | How long (in seconds) a verified connection has to send commands before being disconnected. Each command resets timer. Default 10 seconds.');
  writeln('--allowedips       | Comma delimited list of IP addresses that are allow to connect to server. Default is blank (All IP Addresses)');
  writeln('--logdir           | Full path to save log file. If not set, no log file will be generated.');
  writeln('-----------------------------------------------------------------------------');
  writeln('Verfied Client Commands');
  writeln('---------------------------------');
  writeln('whitelist list        | Lists all items in whitelist file.');
  writeln('whitelist add <id>    | Where <id> is username or SteamID to add.');
  writeln('whitelist remove <id> | Where <id> is username or SteamID to remove.');
  writeln('banlist list          | Lists all items in banlist file.');
  writeln('banlist add <id>      | Where <id> is username or SteamID to add.');
  writeln('banlist remove <id>   | Where <id> is username or SteamID to remove.');
  writeln('ipban list            | Show IPs that are banned Banned.');
  writeln('ipban add <ip> <time> | Where <ip> is ip address to ban, <time>(optional) is seconds to ban. Defaults to bantime setting.');
  writeln('ipban remove <ip>     | Where <ip> is ip address to remove.');
  writeln('-----------------------------------------------------------------------------');
  writeln('Copyright Glimpse Media LLC https://www.glimpse.me');
  writeln('-----------------------------------------------------------------------------');
  writeln('');
end;

procedure TGlimpseManager.ProcessSettingsFile(filename:string);
var
  Settings : TIniFile;
  tmpStr1  : String;
  aIps     : String;
begin
   Settings := TIniFile.Create(filename);
   showDebug := Settings.ReadBool('General','debug',false);
   logDir := Settings.ReadString('General','logdir','');
   if(length(logDir)>0) then
     begin
       logDir := ExtractFilePath(ExeName)+logDir;
       if not DirectoryExists(logDir) then
         begin
           logDir:='';
           doLogFile:=false;
           msgDisplay('SERVER', 'Log Dir (' + logDir + ') Not Found. Logging disabled.');
         end
       else
         begin
            doLogFile := true;
            msgDisplay('SERVER', 'Log Dir (' + logDir + ') Logging enabled.');
         end;
     end;

   bindIP := Settings.ReadString('General','ip','0.0.0.0');
   msgDisplay('SERVER', 'Listen IP: ' + bindIP);

   bindPort := Settings.ReadInteger('General','port',2400);
   msgDisplay('SERVER', 'Listen Port: ' + IntToStr(bindPort));

   serverPassword := Settings.ReadString('General','password','');
   if(length(serverPassword)<3) then
     begin
       msgDisplay('SERVER', 'Server password must be greater 3 chars.');
       serverPassword := '';
     end;

   if(length(serverPassword)<3) then
     begin
       msgDisplay('SERVER', 'Invalid password, server will bind to 127.0.0.1 only');
       bindIP := '127.0.0.1';
     end;

   whiteListFile := ExtractFilePath(ExeName)+Settings.ReadString('General','whitelist','');
   if(length(whiteListFile)>0) then
     begin
       msgDisplay('SERVER', 'Whitelist file (' + whiteListFile + ').');
       if not fileexists(whiteListFile) then
         Begin
           msgDisplay('SERVER', 'Whitelist file (' + whiteListFile + ') Not Found. Whitelist commands disabled.');
           doWhitelist := false;
         end;
     end
   else
   begin
      msgDisplay('SERVER', 'No Path to Whitelist file specified. Whitelist commands disabled.');
      doWhitelist := false;
   end;

   banListFile := ExtractFilePath(ExeName)+Settings.ReadString('General','banlist','');
   if(length(banListFile)>0) then
      begin
        msgDisplay('SERVER', 'Banlist file (' + banListFile + ').');
        if not fileexists(banListFile) then
          Begin
            msgDisplay('SERVER', 'Banlist file (' + banListFile + ') Not Found. Banlist commands disabled.');
            doBanlist := false;
          end;
      end
    else
    begin
       msgDisplay('SERVER', 'No Path to Banlist file specified. Banlist commands disabled.');
       doBanlist := false;
    end;

   whiteListFormat := Settings.ReadString('General','whitelistformat',dataPlaceholder);
   if(length(whiteListFormat)>0) then
     begin
       msgDisplay('SERVER', 'whiteListFormat: ' + whiteListFormat);
       tmpStr1:=StringReplace(whiteListFormat, dataPlaceholder, '', [rfIgnoreCase, rfReplaceAll]);
       if(length(tmpStr1)>0) then
         begin
           whiteListDelim := copy(tmpStr1, 1, 1);
           msgDisplay('SERVER', 'whiteListDelim: ' + whiteListDelim);
         end;
     end;

   banListFormat := Settings.ReadString('General','banlistformat',dataPlaceholder);
   if(length(banListFormat)>0) then
     begin
       msgDisplay('SERVER', 'banListFormat: ' + banListFormat);
       tmpStr1:=StringReplace(banListFormat, dataPlaceholder, '', [rfIgnoreCase, rfReplaceAll]);
       if(length(tmpStr1)>0) then
         begin
           banListDelim := copy(tmpStr1, 1, 1);
           msgDisplay('SERVER', 'banListDelim: ' + banListDelim);
         end;
     end;

   maxLoginAttempts := Settings.ReadInteger('General','maxlogins',3);
   msgDisplay('SERVER', 'Set Max failed logins: ' + IntToStr(maxLoginAttempts));

   banTime := Settings.ReadInteger('General','bantime',300);
   msgDisplay('SERVER', 'Set Ban Time : ' + IntToStr(banTime));

   loginTime := Settings.ReadInteger('General','logintimeout',10);
   msgDisplay('SERVER', 'Login Timeout : ' + IntToStr(banTime));

   idleTime := Settings.ReadInteger('General','ideltimeout',10);
   msgDisplay('SERVER', 'Idle Timeout : ' + IntToStr(banTime));


   aIps := Settings.ReadString('General','allowedips','');
   allowedIPS := TStringList.Create;
   if(length(aIps)>0) then
     begin
       allowedIPS.CommaText:=aIps;
       msgDisplay('SERVER', 'allowedips: ' + allowedIPS.CommaText);
       if(allowedIPS.Count>0) then checkIPS := true;
     end;

end;

function TGlimpseManager.ProcessCLine:boolean;
var
  ErrorMsg : String;
  tmpStr1  : String;
begin
  result := true;
  ErrorMsg:=CheckOptions('hi:dp:w:b:','help debug password: ip: port: whitelist: banlist: whitelist-format:  banlist-format: maxlogins: allowedips: logdir: bantime:');
  if ErrorMsg<>'' then begin
    ShowException(Exception.Create(ErrorMsg));
    result:=false;
    exit;
  end;

  if HasOption('h','help') then begin
    WriteHelp;
    result:=false;
    exit;
  end;

  if HasOption('d', 'debug') then begin
       showDebug := true;
  end;

  if HasOption('logdir') then begin
     logDir:=ExtractFilePath(ExeName)+GetOptionValue('logdir');

     if not DirectoryExists(logDir) then
       Begin
         msgDisplay('SERVER', 'Log Dir (' + logDir + ') Not Found. Logging disabled.');
         logDir:='';
         doLogFile:=false;
       end
     else
       begin
         doLogFile := true;
         msgDisplay('SERVER', 'Log Dir (' + logDir + ') Logging enabled.');
       end;
  end
  else
  begin
     msgDisplay('SERVER', 'No Path to Log file. Logging disabled.');
     logDir:='';
     doLogFile := false;
  end;

  if HasOption('i', 'ip') then begin
       bindIP:=GetOptionValue('i','ip');
       msgDisplay('SERVER', 'Listen IP: ' + bindIP);
  end;

  if HasOption('p', 'port') then begin
       try
          bindPort:=StrToInt(GetOptionValue('p','port'));
          msgDisplay('SERVER', 'Listen Port: ' + GetOptionValue('p','port'));
       except
          writeln('Invalid Port, exiting.');
          result:=false;
          exit;
       end;
  end;

  if HasOption('password') then begin
       serverPassword:=GetOptionValue('password');
       if(length(serverPassword)<3) then
          begin
            writeln('Server password must be more than 3 characters.');
            result:=false;
            exit;
          end;
  end;

  if HasOption('w', 'whitelist') then begin
     whiteListFile:=ExtractFilePath(ExeName)+GetOptionValue('w','whitelist');
     msgDisplay('SERVER', 'whiteListFile: ' + whiteListFile);
     if not fileexists(whiteListFile) then
       Begin
         msgDisplay('SERVER', 'Whitelist file (' + whiteListFile + ') Not Found. Whitelist commands disabled.');
         doWhitelist := false;
       end;
  end
  else
  begin
     msgDisplay('SERVER', 'No Path to Whitelist file specified. Whitelist commands disabled.');
     doWhitelist := false;
  end;

  if HasOption('b', 'banlist') then begin
     banListFile:=ExtractFilePath(ExeName)+GetOptionValue('b','banlist');
     msgDisplay('SERVER', 'banListFile: ' + banListFile);
     if not fileexists(BanListFile) then
       Begin
         msgDisplay('SERVER', 'Banlist file (' + banListFile + ') Not Found. Banlist commands disabled.');
         doBanlist := false;
       end;
  end
  else
  begin
     msgDisplay('SERVER', 'No Path to Banlist file specified. Banlist commands disabled.');
     doBanlist := false;
  end;



  if HasOption('whitelist-format') then begin
     whiteListFormat:=GetOptionValue('whitelist-format');
     msgDisplay('SERVER', 'whiteListFormat: ' + whiteListFormat);
     tmpStr1:=StringReplace(whiteListFormat, dataPlaceholder, '', [rfIgnoreCase, rfReplaceAll]);
     if(length(tmpStr1)>0) then
       begin
         whiteListDelim := copy(tmpStr1, 1, 1);
         msgDisplay('SERVER', 'whiteListDelim: ' + whiteListDelim);
       end;
  end;

  if HasOption('banlist-format') then begin
     whiteListFormat:=GetOptionValue('banlist-format');
     msgDisplay('SERVER', 'banListFormat: ' + banListFormat);
     tmpStr1:=StringReplace(banListFormat, dataPlaceholder, '', [rfIgnoreCase, rfReplaceAll]);
     if(length(tmpStr1)>0) then
       begin
         banListDelim := copy(tmpStr1, 1, 1);
         msgDisplay('SERVER', 'Set Ban List Delimiter: ' + banListDelim);
       end;
  end;

  if HasOption( 'maxlogins') then begin
       try
          maxLoginAttempts:=StrToInt(GetOptionValue('maxlogins'));
          msgDisplay('SERVER', 'Set Max failed logins: ' + GetOptionValue('maxlogins'));
       except
          writeln('Invalid max failed logins, reverting to default.');
       end;
  end;

  if HasOption('bantime') then begin
       try
          banTime:=StrToInt(GetOptionValue('bantime'));
          msgDisplay('SERVER', 'Set Ban Time : ' + GetOptionValue('bantime'));
       except
          writeln('Invalid Ban Time, reverting to default.');
       end;
  end;

  if HasOption('logintimeout') then begin
         try
            loginTime:=StrToInt(GetOptionValue('logintimeout'));
            msgDisplay('SERVER', 'Login Timeout : ' + GetOptionValue('logintimeout'));
         except
            writeln('Invalid Login Timeout, reverting to default.');
         end;
    end;

  if HasOption('idletimeout') then begin
         try
            idleTime:=StrToInt(GetOptionValue('idletimeout'));
            msgDisplay('SERVER', 'Idle Timeout : ' + GetOptionValue('idletimeout'));
         except
            writeln('Invalid Idle Timeout, reverting to default.');
         end;
    end;

  allowedIPS := TStringList.Create;
  if HasOption('allowedips') then begin
    allowedIPS.CommaText:=GetOptionValue('allowedips');
    if(allowedIPS.Count>0) then checkIPS := true;
    msgDisplay('SERVER', 'allowedips: ' + allowedIPS.CommaText);
  end;

  if(length(serverPassword)=0) then
  begin
     msgDisplay('SERVER', 'No password set, binding to localhost only (127.0.0.1)');
     bindIP := '127.0.0.1';
  end;

end;


var
  Application: TGlimpseManager;
  curPid: dword;
  tmpStrs : TStringlist;
  {$R *.res}

begin
  Application:=TGlimpseManager.Create(nil);
  Application.Title:='Glimpse.me Whitelist Manager';
  curPid := GetProcessID;
  tmpStrs := TStringlist.Create();
  tmpStrs.Add(IntToStr(curPid));
  tmpStrs.SaveToFile(ExtractFilePath(Application.ExeName)+'gmanager.pid');
  tmpStrs.Free;
  Application.Run;
  Application.Free;
end.

