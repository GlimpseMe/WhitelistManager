unit functions;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

function StringIndex(const aString: string; const aCases: array of string; const aCaseSensitive: boolean = True): integer;
function getNowStr(): string;

implementation

function StringIndex(const aString: string; const aCases: array of string; const aCaseSensitive: boolean): integer;

begin
  if aCaseSensitive then
  begin
    for Result := 0 to Pred(Length(aCases)) do
      if ANSISameStr(aString, aCases[Result]) then
        EXIT;
  end
  else
  begin
    for Result := 0 to Pred(Length(aCases)) do
      if AnsiSameText(aString, aCases[Result]) then
        EXIT;
  end;
  Result := -1;
end;


function getNowStr(): string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);

end;

end.

