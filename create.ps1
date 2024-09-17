#################################################
# HelloID-Conn-Prov-Target-Nmbrs-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12


# Set debug logging
switch ($($actionContext.Configuration.isDebug)) {
    $true { $VerbosePreference = "Continue" }
    $false { $VerbosePreference = "SilentlyContinue" }
}
$InformationPreference = "Continue"
$WarningPreference = "Continue"

#region functions
function Resolve-NmbrsError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId
            MyCommand             = $ErrorObject.InvocationInfo.MyCommand
            RequestUri            = $ErrorObject.TargetObject.RequestUri
            ScriptStackTrace      = $ErrorObject.ScriptStackTrace
            ErrorMessage          = ""
        }
        if ($ErrorObject.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") {
            $httpErrorObj.ErrorMessage = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq "System.Net.WebException") {
            $httpErrorObj.ErrorMessage = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
        }
        Write-Output $httpErrorObj
    }
}

function Invoke-NMBRSRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [Parameter(Mandatory)]
        [string]
        $Service,

        [Parameter(Mandatory)]
        [string]
        $SoapBody
    )

    switch ($service) {
        'EmployeeService' {
            $soapHeader = "
            <emp:AuthHeaderWithDomain>
            <emp:Username>$($actionContext.Configuration.UserName)</emp:Username>
            <emp:Token>$($actionContext.Configuration.Token)</emp:Token>
            <emp:Domain>$($actionContext.Configuration.Domain)</emp:Domain>
            </emp:AuthHeaderWithDomain>"
        }
    }

    $xmlRequest = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
    <soap:Envelope xmlns:soap = `"http://www.w3.org/2003/05/soap-envelope`" xmlns:emp=`"https://api.nmbrs.nl/soap/$($actionContext.Configuration.version)/$service`">
        <soap:Header>
            $soapHeader
        </soap:Header>
        <soap:Body>
            $soapBody
        </soap:Body>
        </soap:Envelope>"

    try {
        $splatParams = @{
            Uri         = $Uri
            Method      = 'POST'
            Body        = $xmlRequest
            ContentType = 'text/xml; charset=utf-8'
        }

        if (-not  [string]::IsNullOrEmpty($actionContext.Configuration.ProxyAddress)) {
            $splatParams['Proxy'] = $actionContext.Configuration.ProxyAddress

        }        
        Invoke-RestMethod @splatParams -Verbose: $false
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-CurrentPersonalInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $EmployeeId
    )

    $splatParams = @{
        Uri      = "$($actionContext.Configuration.BaseUrl)/soap/$($actionContext.Configuration.version)/EmployeeService.asmx"
        Service  = 'EmployeeService'
        SoapBody = "<emp:PersonalInfo_GetCurrent xmlns=`"https://api.nmbrs.nl/soap/$($actionContext.Configuration.version)/EmployeeService`">
            <emp:EmployeeId>$EmployeeId</emp:EmployeeId>
            </emp:PersonalInfo_GetCurrent>"
    }
    try {
        [xml]$response = Invoke-NMBRSRestMethod @splatParams
        Write-Output $response.Envelope.Body.PersonalInfo_GetCurrentResponse.PersonalInfo_GetCurrentResult
    }
    catch {
        Throw $_
    }
}
#endregion

try {
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.accountField
        $correlationValue = $actionContext.CorrelationConfiguration.accountFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Querying account where [$($correlationField)] = [$($correlationValue)]"
        $currentAccount = Get-CurrentPersonalInfo -EmployeeID $($actionContext.Data.Id)
    }
    else {
        Throw "Configuration of correlation is mandatory."
    }

    if ($null -ne $currentAccount) {
        $action = 'CorrelateAccount'

        $correlatedAccount = @{            
            Id             = $currentAccount.Id
            EmployeeNumber = $currentAccount.EmployeeNumber
            EmailWork      = $currentAccount.EmailWork
        }
    }
    else {
        $action = 'CreateAccount'
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            Write-Information "No account found where  [$($correlationField)] = [$($correlationValue)] and no account will be created with this connector!"                
            throw "No account found where [$($correlationField)] = [$($correlationValue)] and no account will be created with this connector!"            
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Nmbrs account'

            $outputContext.Data = $correlatedAccount
            $outputContext.AccountReference = $correlatedAccount.Id
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($personContext.Person.DisplayName)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NmbrsError -ErrorObject $ex
        $auditMessage = "Could not create or correlate Nmbrs account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create or correlate Nmbrs account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}