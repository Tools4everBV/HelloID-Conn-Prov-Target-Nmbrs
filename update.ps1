#################################################
# HelloID-Conn-Prov-Target-Nmbrs-Update
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
            $httpErrorObject = Resolve-NmbrsError -Error $ErrorObject

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
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Error "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage) [$($ex.ErrorDetails.Message)]"
                
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = "Error updating account [$($account.DisplayName) ($($actionContext.References.Account))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
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
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Error "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage) [$($ex.ErrorDetails.Message)]"
                
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                # Action  = "" # Optional
                Message = "Error updating account [$($personContext.Person.DisplayName) ($($actionContext.References.Account))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                IsError = $true
            })
        break
    }
}
#endregion

try {    
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Information 'Verifying if a Nmbrs account exists'
    $correlatedAccount = Get-CurrentPersonalInfo -EmployeeID $($actionContext.References.Account)
    
    $outputContext.PreviousData.EmailWork = $correlatedAccount.EmailWork

    # Always compare the account against the current account in target system
    if ($null -ne $correlatedAccount) {
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
        if ($propertiesChanged) {
            $action = 'UpdateAccount'
        }
        else {
            $action = 'NoChanges'
        }
    }
    else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

            # Make sure to test with special characters and if needed; add utf8 encoding.
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Nmbrs account with accountReference: [$($actionContext.References.Account)]"
                $updateAccountObject = @{                            
                    Id             = $correlatedAccount.Id             #Mandatory Field within Set-CurrentPerson
                    Number         = $correlatedAccount.Number         #Mandatory Field within Set-CurrentPerson
                    EmployeeNumber = $correlatedAccount.EmployeeNumber #Mandatory Field within Set-CurrentPerson
                    LastName       = $correlatedAccount.LastName       #Mandatory Field within Set-CurrentPerson
                    EmailWork      = $actionContext.Data.EmailWork     #Field to update
                    Birthday       = $correlatedAccount.Birthday       #Mandatory Field within Set-CurrentPerson
                }
                $body = $null

                foreach ($property in $updateAccountObject.GetEnumerator()) {
                    $body += "<emp:$($property.Name)>$($property.Value)</emp:$($property.Name)>"
                }

                Write-Verbose "Updating account [$($personContext.Person.DisplayName) ($($actionContext.References.Account))]. Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                $null = Set-CurrentPersonalInfo -EmployeeId $($actionContext.References.Account) -EmployeeBody $body

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        # Action  = "" # Optional
                        Message = "Successfully updated account [$($personContext.Person.DisplayName) ($($actionContext.References.Account))]. Updated properties: $($changedPropertiesObject | ConvertTo-Json -Depth 10)"
                        IsError = $false
                    })

            }
            else {
                Write-Information "[DryRun] Update Nmbrs account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "No changes to Nmbrs account with accountReference: [$($actionContext.References.Account)]"

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'No changes will be made to the account during enforcement'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Nmbrs account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Nmbrs account with accountReference: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                    IsError = $true
                })
            break
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NmbrsError -ErrorObject $ex
        $auditMessage = "Could not update Nmbrs account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update Nmbrs account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
