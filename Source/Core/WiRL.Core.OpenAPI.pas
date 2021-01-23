{******************************************************************************}
{                                                                              }
{       WiRL: RESTful Library for Delphi                                       }
{                                                                              }
{       Copyright (c) 2015-2019 WiRL Team                                      }
{                                                                              }
{       https://github.com/delphi-blocks/WiRL                                  }
{                                                                              }
{******************************************************************************}
unit WiRL.Core.OpenAPI;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.Rtti,

  Neon.Core.Persistence.Swagger,

  WiRL.Configuration.Neon,
  WiRL.Configuration.OpenAPI,
  WiRL.Core.JSON,
  WiRL.Core.Application,
  WiRL.Core.Engine,
  WiRL.Core.Context.Server,
  WiRL.Core.Registry,
  WiRL.Core.Attributes,
  WiRL.http.Accept.MediaType,
  WiRL.Rtti.Utils,
  WiRL.http.Filters;

type
  TOpenAPIInfo = class
  private
    FTitle: string;
    FVersion: string;
    FDescription: string;
    FSchemes: TArray<string>;
    FOpenAPIResource: string;
    FApplication: TWiRLApplication;
    FHost: string;
  public
    constructor Create(AApplication: TWiRLApplication; const ASwaggerResource: string);

    procedure AddScheme(const AScheme: string);

    property Host: string read FHost write FHost;
    property Title: string read FTitle write FTitle;
    property Version: string read FVersion write FVersion;
    property Description: string read FDescription write FDescription;
    property Schemes: TArray<string> read FSchemes write FSchemes;
    property Application: TWiRLApplication read FApplication write FApplication;
    property OpenAPIResource: string read FOpenAPIResource write FOpenAPIResource;
  end;


  TOpenAPIv2Engine = class
  private
    const OPENAPI_VERSION = '2.0';
  private
    FInfo: TOpenAPIInfo;
    FApplication: TWiRLApplication;
    FConfigurationOpenAPI: TWiRLConfigurationOpenAPI;
    FConfigurationNeon: TWiRLConfigurationNeon;
    FSwaggerResource: string;

    function GetPath(ARttiObject: TRttiObject): string;
    procedure AddOperation(AJsonPath: TJSONObject; const AMethodName, ATagName: string; AResourceMethod: TRttiMethod);
    procedure AddResource(const AName: string; APaths: TJSONObject; AApplication: TWiRLApplication; LResource: TClass);
    function CreateParameter(ARttiParameter: TRttiParameter): TJSONObject;
  protected
    constructor Create(AApplication: TWiRLApplication; const ASwaggerResource: string); overload;
    constructor Create(AInfo: TOpenAPIInfo); overload;

    function Build(): TJSONObject;
  public
    destructor Destroy; override;
    class function Generate(AApplication: TWiRLApplication; const ASwaggerResource: string): TJSONObject; overload;
    class function Generate(AInfo: TOpenAPIInfo): TJSONObject; overload;
  end;


implementation

uses
  System.StrUtils, System.TypInfo,

  WiRL.Core.Utils,
  WiRL.http.Server;

procedure TOpenAPIv2Engine.AddOperation(AJsonPath: TJSONObject; const
    AMethodName, ATagName: string; AResourceMethod: TRttiMethod);

  function FindOrCreateOperation(APath: TJSONObject; const AMethodName: string) :TJSONObject;
  begin
    Result := APath.GetValue(AMethodName) as TJSONObject;
    if not Assigned(Result) then
    begin
      Result := TJSONObject.Create;
      AJsonPath.AddPair(AMethodName, Result);
    end;
  end;

var
  LOperation: TJSONObject;
  LResponses: TJSONObject;
  LParameters: TJSONArray;
  LParameter: TJSONObject;
  LProduces: TJSONArray;
  LConsumes: TJSONArray;
  LRttiParameter: TRttiParameter;
  LOkResponse: TJSONObject;
begin
  // Operation = Path + HttpMethod
  // If more object method use the same operation add info on the
  // same operation
  LOperation := FindOrCreateOperation(AJsonPath, AMethodName);

  if not Assigned(LOperation.GetValue('summary')) then
    LOperation.AddPair('summary', AResourceMethod.Name);

  if not ATagName.IsEmpty then
    LOperation.AddPair('tags', TJSONArray.Create.Add(ATagName));

  LProduces := LOperation.GetValue('produces') as TJSONArray;
  TRttiHelper.HasAttribute<ProducesAttribute>(AResourceMethod,
    procedure (AAttr: ProducesAttribute)
    begin
      if not Assigned(LProduces) then
      begin
        LProduces := TJSONArray.Create;
        LOperation.AddPair('produces', LProduces);
      end;

      // Check if the produce already exists
      if not ExistsInArray(LProduces, AAttr.Value) then
        LProduces.Add(AAttr.Value);
    end
  );

  LConsumes := LOperation.GetValue('consumes') as TJSONArray;
  TRttiHelper.HasAttribute<ConsumesAttribute>(AResourceMethod,
    procedure (AAttr: ConsumesAttribute)
    begin
      if not Assigned(LConsumes) then
      begin
        LConsumes := TJSONArray.Create;
        LOperation.AddPair('consumes', LConsumes);
      end;

      // Check if the consume already exists
      if not ExistsInArray(LConsumes, AAttr.Value) then
        LConsumes.Add(AAttr.Value);
    end
  );

  if not Assigned(LOperation.GetValue('parameters')) then
  begin
    LParameters := nil;
    for LRttiParameter in AResourceMethod.GetParameters do
    begin
      if not Assigned(LParameters) then
      begin
        LParameters := TJSONArray.Create;
        LOperation.AddPair('parameters', LParameters)
      end;
      LParameter := CreateParameter(LRttiParameter);
      if Assigned(LParameter) then
        LParameters.Add(LParameter);
    end;
  end;

  if not Assigned(LOperation.GetValue('responses')) then
  begin
    LResponses := TJSONObject.Create;
    LOperation.AddPair('responses', LResponses);
    LOkResponse := TJSONObject.Create(TJSONPair.Create('description', 'Ok'));
    LResponses.AddPair('200', LOkResponse);
    LResponses.AddPair('default', TJSONObject.Create(TJSONPair.Create('description', 'Error')));
    if Assigned(AResourceMethod.ReturnType) and (AResourceMethod.ReturnType.TypeKind <> tkUnknown) then
      LOkResponse.AddPair('schema', TNeonSchemaGenerator.TypeToJSONSchema(AResourceMethod.ReturnType, FConfigurationNeon.GetNeonConfig));
  end;
end;

procedure TOpenAPIv2Engine.AddResource(const AName: string; APaths:
    TJSONObject; AApplication: TWiRLApplication; LResource: TClass);

  function FindOrCreatePath(APaths: TJSONObject; const AResourcePath: string): TJSONObject;
  begin
    Result := APaths.GetValue(AResourcePath) as TJSONObject;
    if not Assigned(Result) then
    begin
      Result := TJSONObject.Create;
      APaths.AddPair(AResourcePath, Result);
    end;
  end;

var
  LMethodPath: string;
  LResourcePath: string;
  LResourceType: TRttiType;
  LResourceMethod: TRttiMethod;
  LMethodName: string;
  LResourceMethodPath: string;
  LJsonPath: TJSONObject;
begin
  LResourceType := TRttiHelper.Context.GetType(LResource);
  LResourcePath := GetPath(LResourceType);
  if LResourcePath <> '' then
  begin
    // Loop on every method of the current resource object
    for LResourceMethod in LResourceType.GetMethods do
    begin
      LMethodName := '';
      TRttiHelper.HasAttribute<HttpMethodAttribute>(LResourceMethod,
        procedure (AAttr: HttpMethodAttribute)
        begin
          LMethodName := AAttr.ToString.ToLower;
        end
      );
      if LMethodName <> '' then
      begin
        LResourceMethodPath := GetPath(LResourceMethod);

        LMethodPath := IncludeLeadingSlash((AApplication.Engine as TWiRLEngine).BasePath) +
          IncludeLeadingSlash(AApplication.BasePath) + IncludeLeadingSlash(LResourcePath);
        if (not LMethodPath.EndsWith('/')) and (not LResourceMethodPath.StartsWith('/')) then
          LMethodPath := LMethodPath + '/';
        LMethodPath := LMethodPath + LResourceMethodPath;
        // If the resource is already documented add the information on
        // the same json object
        LJsonPath := FindOrCreatePath(APaths, LMethodPath);
        AddOperation(LJsonPath, LMethodName, AName, LResourceMethod);
      end;
    end;
  end;
end;

function TOpenAPIv2Engine.Build(): TJSONObject;
var
  LInfo: TJSONObject;
  LTags: TJSONArray;
  LPaths: TJSONObject;
  LSchemes: TJSONArray;

  LResourceName: string;
  LResource: TClass;
begin
  // Info object
  { TODO -opaolo -c : manage the empty strings scenario 07/01/2021 16:29:30 }
  LInfo := TJSONObject.Create
    .AddPair('title', FConfigurationOpenAPI.Title)
    .AddPair('version', FConfigurationOpenAPI.Version)
    .AddPair('description', FConfigurationOpenAPI.Description);

  // Paths object
  LPaths := TJSONObject.Create;
  LTags := TJSONArray.Create;

  // Loop on every resource of the application
  for LResourceName in FApplication.Resources.Keys do
  begin
    if SameText(LResourceName.Trim(['/']), FSwaggerResource.Trim(['/'])) then
      Continue;
    LTags.Add(TJSONObject.Create.AddPair('name', LResourceName));
    LResource := FApplication.GetResourceInfo(LResourceName).TypeTClass;
    AddResource(LResourceName, LPaths, FApplication, LResource);
  end;

  LSchemes := TJSONArray.Create;
  LSchemes.Add('http');

  Result := TJSONObject.Create
    .AddPair('swagger', OPENAPI_VERSION)
    .AddPair('host', FConfigurationOpenAPI.Host)
    .AddPair('schemes', LSchemes)
    .AddPair('info', LInfo)
    .AddPair('tags', LTags)
    .AddPair('paths', LPaths)
end;

constructor TOpenAPIv2Engine.Create(AApplication: TWiRLApplication; const
    ASwaggerResource: string);
begin
  FSwaggerResource := ASwaggerResource;
  FApplication := AApplication;
  FConfigurationNeon := FApplication.GetConfiguration<TWiRLConfigurationNeon>;
  FConfigurationOpenAPI := FApplication.GetConfiguration<TWiRLConfigurationOpenAPI>;
end;

constructor TOpenAPIv2Engine.Create(AInfo: TOpenAPIInfo);
begin
  FInfo := AInfo;

  FSwaggerResource := AInfo.OpenAPIResource;
  FApplication := AInfo.Application;
  FConfigurationNeon := FApplication.GetConfiguration<TWiRLConfigurationNeon>;
  FConfigurationOpenAPI := FApplication.GetConfiguration<TWiRLConfigurationOpenAPI>;
end;

function TOpenAPIv2Engine.CreateParameter(ARttiParameter: TRttiParameter): TJSONObject;

  function GetParamPosition(ARttiParameter: TRttiParameter): string;
  begin
    if TRttiHelper.HasAttribute<PathParamAttribute>(ARttiParameter) then
      Result := 'path'
    else if TRttiHelper.HasAttribute<QueryParamAttribute>(ARttiParameter) then
      Result := 'query'
    else if TRttiHelper.HasAttribute<FormParamAttribute>(ARttiParameter) then
      Result := 'formData'
    else if TRttiHelper.HasAttribute<HeaderParamAttribute>(ARttiParameter) then
      Result := 'header'
    else if TRttiHelper.HasAttribute<BodyParamAttribute>(ARttiParameter) then
      Result := 'body'
    else
      Result := ''
  end;

  function GetParamName(ARttiParameter: TRttiParameter): string;
  var
    LParam: MethodParamAttribute;
  begin
    LParam := TRttiHelper.FindAttribute<MethodParamAttribute>(ARttiParameter);
    if Assigned(LParam) then
      Result := LParam.Value;

    if Result.IsEmpty then
      Result := ARttiParameter.Name;
  end;

var
  LParamType: string;
begin
  LParamType := GetParamPosition(ARttiParameter);
  if LParamType.IsEmpty then
    Result := nil
  else
  begin
    if LParamType <> 'body' then
      Result := TNeonSchemaGenerator.TypeToJSONSchema(ARttiParameter.ParamType, FConfigurationNeon.GetNeonConfig)
    else
    begin
      Result := TJSONObject.Create
        .AddPair('schema', TNeonSchemaGenerator.TypeToJSONSchema(ARttiParameter.ParamType, FConfigurationNeon.GetNeonConfig))
    end;

    Result.AddPair(TJSONPair.Create('name', GetParamName(ARttiParameter)));
    Result.AddPair(TJSONPair.Create('in', LParamType));

    if LParamType = 'path' then
      Result.AddPair(TJSONPair.Create('required', TJSONTrue.Create))
    else
      Result.AddPair(TJSONPair.Create('required', TJSONFalse.Create));
  end;
end;

destructor TOpenAPIv2Engine.Destroy;
begin
  FInfo.Free;
  inherited;
end;

class function TOpenAPIv2Engine.Generate(AApplication: TWiRLApplication; const
    ASwaggerResource: string): TJSONObject;
var
  LEngine: TOpenAPIv2Engine;
begin
  LEngine := TOpenAPIv2Engine.Create(AApplication, ASwaggerResource);
  try
    Result := LEngine.Build();
  finally
    LEngine.Free;
  end;
end;

class function TOpenAPIv2Engine.Generate(AInfo: TOpenAPIInfo): TJSONObject;
var
  LEngine: TOpenAPIv2Engine;
begin
  LEngine := TOpenAPIv2Engine.Create(AInfo);
  try
    Result := LEngine.Build();
  finally
    LEngine.Free;
  end;
end;

function TOpenAPIv2Engine.GetPath(ARttiObject: TRttiObject): string;
var
  LPath: string;
begin
  LPath := '';
  TRttiHelper.HasAttribute<PathAttribute>(ARttiObject,
    procedure (AAttr: PathAttribute)
    begin
      LPath := AAttr.Value;
    end
  );
  Result := LPath;
end;

{ TOpenAPIInfo }

procedure TOpenAPIInfo.AddScheme(const AScheme: string);
begin
  FSchemes := FSchemes + [AScheme];
end;

constructor TOpenAPIInfo.Create(AApplication: TWiRLApplication; const ASwaggerResource: string);
begin
  FApplication := AApplication;
  FOpenAPIResource := ASwaggerResource;
end;

end.