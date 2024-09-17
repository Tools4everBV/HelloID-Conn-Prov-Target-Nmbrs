##################################################
# HelloID-Conn-Prov-Target-Nmbrs-Delete
# PowerShell V2
##################################################

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

function Set-CurrentPersonalInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $EmployeeId,

        [Parameter(Mandatory)]
        [string]
        $EmployeeBody
    )

    $splatParams = @{
        Uri      = "$($actionContext.Configuration.BaseUrl)/soap/$($actionContext.Configuration.version)/EmployeeService.asmx"
        Service  = 'EmployeeService'
        SoapBody = "<emp:PersonalInfo_UpdateCurrent xmlns=`"https://api.nmbrs.nl/soap/$($actionContext.Configuration.version)/EmployeeService`">
            <emp:EmployeeId>$EmployeeId</emp:EmployeeId>
            <emp:PersonalInfo>$EmployeeBody</emp:PersonalInfo>
            </emp:PersonalInfo_UpdateCurrent>"
    }

    try {
        [xml]$response = Invoke-NMBRSRestMethod @splatParams
        Write-Output $response.Envelope.Body.PersonalInfo_UpdateCurrentResponse
    }
    catch {
        Throw $_
    }
}
#endregion

try {    
    #$actionContext.References.Account = "495786"
    # Verify if [aRef] has a value    
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Information 'Verifying if a Nmbrs account exists'
    $correlatedAccount = Get-CurrentPersonalInfo -EmployeeID $($actionContext.References.Account)
    
    if ($null -ne $correlatedAccount) {
        $action = 'DeleteAccount'
    }
    else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'DeleteAccount' {            
            if (-Not($actionContext.DryRun -eq $true)) {
                Write-Information "Deleting Nmbrs account with accountReference: [$($actionContext.References.Account)]"
                $deleteAccountObject = @{                            
                    Id             = $correlatedAccount.Id             #Mandatory Field within Set-CurrentPerson
                    Number         = $correlatedAccount.Number         #Mandatory Field within Set-CurrentPerson
                    EmployeeNumber = $correlatedAccount.EmployeeNumber #Mandatory Field within Set-CurrentPerson
                    LastName       = $correlatedAccount.LastName       #Mandatory Field within Set-CurrentPerson
                    EmailWork      = $actionContext.Data.EmailWork     #Field to clear
                    Birthday       = $correlatedAccount.Birthday       #Mandatory Field within Set-CurrentPerson
                }
        
                $body = $null
        
                foreach ($property in $deleteAccountObject.GetEnumerator()) {
                    $body += "<emp:$($property.Name)>$($property.Value)</emp:$($property.Name)>"
                }
        
                Write-Information "Deleting account [$($personContext.Person.DisplayName) ($($correlatedAccount.Id))]"
                $null = Set-CurrentPersonalInfo -EmployeeId $($correlatedAccount.Id) -EmployeeBody $body
            }
            else {
                Write-Information "[DryRun] Would update Nmbrs account with accountReference: [$($actionContext.References.Account)], current EmailWork [$($correlatedAccount.EmailWork)] new EmailWork [$($actionContext.Data.EmailWork)]"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successfull, current EmailWork [$($correlatedAccount.EmailWork)] new EmailWork [$($actionContext.Data.EmailWork)]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Nmbrs account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Nmbrs account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NmbrsError -ErrorObject $ex
        $auditMessage = "Could not delete Nmbrs account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not delete Nmbrs account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}