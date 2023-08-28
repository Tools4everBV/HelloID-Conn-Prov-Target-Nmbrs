#####################################################
# HelloID-Conn-Prov-Target-Nmbrs-Delete
#
# Version: 1.0.0
#####################################################
# Initialize default values
$c = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $accountReference | ConvertFrom-Json
$success = $false # Set to false at start, at the end, only when no error occurs it is set to true
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($c.isDebug)) {
    $true { $VerbosePreference = "Continue" }
    $false { $VerbosePreference = "SilentlyContinue" }
}
$InformationPreference = "Continue"
$WarningPreference = "Continue"

# Define configuration properties as required
$requiredConfigurationFields = @("BaseUrl", "UserName", "Token", "Domain", "version")

# Correlation values
$correlationProperty = "Id" # Has to match the name of the unique identifier
$correlationValue = $p.externalId # Has to match the value of the unique identifier

# Change mapping here - Empty as we delete the account
$account = [PSCustomObject]@{
    Id  = $p.ExternalId
    EmailWork = "" #$p.Contact.Personal.Email
}

# Define account properties as required - Empty as we delete the account
$requiredAccountFields = @("Id")

# Define account properties to update - Empty as we delete the account
#$updateAccountFields = @()

# Define account properties to store in account data - Empty as we delete the account
#$storeAccountFields = @()

#region functions
function Resolve-HTTPError {
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

function Get-ErrorMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $errorMessage = [PSCustomObject]@{
            VerboseErrorMessage = $null
            AuditErrorMessage   = $null
        }

        if ( $($ErrorObject.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or $($ErrorObject.Exception.GetType().FullName -eq "System.Net.WebException")) {
            $httpErrorObject = Resolve-HTTPError -Error $ErrorObject

            $errorMessage.VerboseErrorMessage = $httpErrorObject.ErrorMessage

            $errorMessage.AuditErrorMessage = $httpErrorObject.ErrorMessage
        }

        # If error message empty, fall back on $ex.Exception.Message
        if ([String]::IsNullOrEmpty($errorMessage.VerboseErrorMessage)) {
            $errorMessage.VerboseErrorMessage = $ErrorObject.Exception.Message
        }
        if ([String]::IsNullOrEmpty($errorMessage.AuditErrorMessage)) {
            $errorMessage.AuditErrorMessage = $ErrorObject.Exception.Message
        }

        Write-Output $errorMessage
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
                <emp:Username>$($c.UserName)</emp:Username>
                <emp:Token>$($c.Token)</emp:Token>
                <emp:Domain>$($c.Domain)</emp:Domain>
            </emp:AuthHeaderWithDomain>"
        }
    }

    $xmlRequest = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
        <soap:Envelope xmlns:soap= `"http://www.w3.org/2003/05/soap-envelope`" xmlns:emp=`"https://api.nmbrs.nl/soap/$($c.version)/$service`">
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

        if (-not  [string]::IsNullOrEmpty($c.ProxyAddress)) {
            $splatParams['Proxy'] = $c.ProxyAddress

        }
        #Invoke-WebRequest @splatParams
        Invoke-RestMethod @splatParams -Verbose:$false
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
        Uri      = "$($c.BaseUrl)/soap/$($c.version)/EmployeeService.asmx"
        Service  = 'EmployeeService'
        SoapBody = "<emp:PersonalInfo_GetCurrent xmlns=`"https://api.nmbrs.nl/soap/$($c.version)/EmployeeService`">
            <emp:EmployeeId>$EmployeeId</emp:EmployeeId>
            </emp:PersonalInfo_GetCurrent>"
    }
    try {
        [xml]$response = Invoke-NMBRSRestMethod @splatParams
        Write-Output $response.Envelope.Body.PersonalInfo_GetCurrentResponse.PersonalInfo_GetCurrentResult
    }
    catch {
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage) [$($ex.ErrorDetails.Message)]"
                
        $auditLogs.Add([PSCustomObject]@{
                # Action  = "" # Optional
                Message = "Error updating account [$($p.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                IsError = $true
            })
        break
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
        Uri      = "$($c.BaseUrl)/soap/$($c.version)/EmployeeService.asmx"
        Service  = 'EmployeeService'
        SoapBody = "<emp:PersonalInfo_UpdateCurrent xmlns=`"https://api.nmbrs.nl/soap/$($c.version)/EmployeeService`">
            <emp:EmployeeId>$EmployeeId</emp:EmployeeId>
            <emp:PersonalInfo>$EmployeeBody</emp:PersonalInfo>
            </emp:PersonalInfo_UpdateCurrent>"
    }

    try {
        [xml]$response = Invoke-NMBRSRestMethod @splatParams
        Write-Output $response.Envelope.Body.PersonalInfo_UpdateCurrentResponse
    }
    catch {
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage) [$($ex.ErrorDetails.Message)]"
                
        $auditLogs.Add([PSCustomObject]@{
                # Action  = "" # Optional
                Message = "Error updating account [$($p.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                IsError = $true
            })
        break
    }
}
#endregion functions

try {
    # Check if required fields are available in configuration object
    $incompleteConfiguration = $false
    foreach ($requiredConfigurationField in $requiredConfigurationFields) {
        if ($requiredConfigurationField -notin $c.PsObject.Properties.Name) {
            $incompleteConfiguration = $true
            Write-Warning "Required configuration object field [$requiredConfigurationField] is missing"
        }
        elseif ([String]::IsNullOrEmpty($c.$requiredConfigurationField)) {
            $incompleteConfiguration = $true
            Write-Warning "Required configuration object field [$requiredConfigurationField] has a null or empty value"
        }
    }

    if ($incompleteConfiguration -eq $true) {
        throw "Configuration object incomplete, cannot continue."
    }

    # Check if required fields are available for correlation
    $incompleteCorrelationValues = $false
    if ([String]::IsNullOrEmpty($correlationProperty)) {
        $incompleteCorrelationValues = $true
        Write-Warning "Required correlation field [$correlationProperty] has a null or empty value"
    }
    if ([String]::IsNullOrEmpty($correlationValue)) {
        $incompleteCorrelationValues = $true
        Write-Warning "Required correlation field [$correlationValue] has a null or empty value"
    }
    
    if ($incompleteCorrelationValues -eq $true) {
        throw "Correlation values incomplete, cannot continue. CorrelationProperty = [$correlationProperty], CorrelationValue = [$correlationValue]"
    }

    # Check if required fields are available in account object
    $incompleteAccount = $false
    foreach ($requiredAccountField in $requiredAccountFields) {
        if ($requiredAccountField -notin $account.PsObject.Properties.Name) {
            $incompleteAccount = $true
            Write-Warning "Required account object field [$requiredAccountField] is missing"
        }
        elseif ([String]::IsNullOrEmpty($account.$requiredAccountField)) {
            $incompleteAccount = $true
            Write-Warning "Required account object field [$requiredAccountField] has a null or empty value"
        }
    }

    if ($incompleteAccount -eq $true) {
        throw "Account object incomplete, cannot continue."
    }

    
    # Get current account to fill mandatory fields
    try {
        Write-Verbose "Querying account where [$($correlationProperty)] = [$($correlationValue)]"

        $currentAccount = $null
        $currentAccount = Get-CurrentPersonalInfo -EmployeeID $($account.Id)

        if ($null -eq $currentAccount) {
            if ($($c.createUser) -eq $true) {
                Write-Verbose "No account found where  [$($correlationProperty)] = [$($correlationValue)]. Creating new account"
                $auditLogs.Add([PSCustomObject]@{
                        # Action  = "" # Optional
                        Message = "No account found where [$($correlationProperty)] = [$($correlationValue)] and no account will be created with this connector!"
                        IsError = $true
                    })
            }  
        }
    }
    catch {
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage)"

        if ($errorMessage.AuditErrorMessage -Like "No account found where [$($correlationProperty)] = [$($correlationValue)]") {
            $auditLogs.Add([PSCustomObject]@{
                    # Action  = "" # Optional
                    Message = "No account found where [$($correlationProperty)] = [$($correlationValue)]. Possibly already deleted, skipped action."
                    IsError = $false
                })
        }
        else {
            $auditLogs.Add([PSCustomObject]@{
                    # Action  = "" # Optional
                    Message = "Error querying account where [$($correlationProperty)] = [$($correlationValue)]. Error Message: $($errorMessage.AuditErrorMessage)"
                    IsError = $true
                })
        }

        # Skip further actions, as this is a critical error
        continue
    }

    # Delete account
    try {
        $deleteAccountObject = @{                            
            Id             = $currentAccount.Id             #Mandatory Field within Set-CurrentPerson
            Number         = $currentAccount.Number         #Mandatory Field within Set-CurrentPerson
            EmployeeNumber = $currentAccount.EmployeeNumber #Mandatory Field within Set-CurrentPerson
            LastName       = $currentAccount.LastName       #Mandatory Field within Set-CurrentPerson
            EmailWork      = $account.EmailWork                             #Field to clear
            Birthday       = $currentAccount.Birthday       #Mandatory Field within Set-CurrentPerson
        }

        $body = $null

        foreach ($property in $deleteAccountObject.GetEnumerator()) {
            $body += "<emp:$($property.Name)>$($property.Value)</emp:$($property.Name)>"
        }

        Write-Verbose "Deleting account [$($p.DisplayName) ($($currentAccount.Id))]"
                        
        if (-not($dryRun -eq $true)) {
            $null = Set-CurrentPersonalInfo -EmployeeId $($currentAccount.Id) -EmployeeBody $body

            $auditLogs.Add([PSCustomObject]@{
                    # Action  = "" # Optional
                    Message = "Successfully deleted account [$($p.DisplayName) ($($currentAccount.Id))]"
                    IsError = $false
                })
        }
        else {
            Write-Warning "DryRun: Would delete account [$($p.DisplayName) ($($currentAccount.Id))]"
        }

        break
    }
    catch {
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex
                
        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage)"
            
        $auditLogs.Add([PSCustomObject]@{
                # Action  = "" # Optional
                Message = "Error deleting account [$($p.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage)"
                IsError = $true
            })
    }
}
finally {
    # Check if auditLogs contains errors, if no errors are found, set success to true
    if (-NOT($auditLogs.IsError -contains $true)) {
        $success = $true
    }
    
    # Send results
    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $aRef
        AuditLogs        = $auditLogs
        PreviousAccount  = $previousAccount
        Account          = $account
    
        # Optionally return data for use in other systems
        ExportData       = $exportData
    }
    
    Write-Output ($result | ConvertTo-Json -Depth 10)  
}
