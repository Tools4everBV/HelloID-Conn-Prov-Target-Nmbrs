#####################################################
# HelloID-Conn-Prov-Target-Nmbrs-Create
#
# Version: 1.0.1
#####################################################
# Initialize default values
$c = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
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

# Change mapping here
$account = [PSCustomObject]@{
    Id  = $p.ExternalId
    DisplayName = $p.DisplayName
    EmailWork   = $p.Accounts.MicrosoftActiveDirectory.Mail        
}

# Define account properties as required
$requiredAccountFields = @("Id", "EmailWork")

# Define account properties to update
$updateAccountFields = @("EmailWork")

# Define account properties to store in account data
$storeAccountFields = @("Id", "EmployeeNumber", "EmailWork")

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
        throw $_
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
                Message = "Error updating account [$($account.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
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
                Message = "Error updating account [$($account.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
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

    # Get current account and verify if it should be either correlated, created or updated and correlated
    try {
        Write-Verbose "Querying account where [$($correlationProperty)] = [$($correlationValue)]"

        $currentAccount = $null
        $currentAccount = Get-CurrentPersonalInfo -EmployeeID $($account.Id)

        if ($null -eq $currentAccount) {
            if ($($c.createUser) -eq $true) {
                Write-Verbose "No account found where  [$($correlationProperty)] = [$($correlationValue)] and no account will be created with this connector!"
                $auditLogs.Add([PSCustomObject]@{
                        # Action  = "" # Optional
                        Message = "No account found where [$($correlationProperty)] = [$($correlationValue)] and no account will be created with this connector!"
                        IsError = $true
                    })
            }            
        }
        else {
            # Create previous account object to compare current data with specified account data
            $previousAccount = [PSCustomObject]@{                
                EmailWork = $currentAccount.EmailWork #Field to update                
            }

            if ($($c.updateOnCorrelate) -eq $true) {
                $action = "Update"

                # Calculate changes between current data and provided data
                $splatCompareProperties = @{
                    ReferenceObject  = @($previousAccount.PSObject.Properties)
                    DifferenceObject = @($account.PSObject.Properties | Where-Object { $_.Name -in $updateAccountFields }) # Only select the properties to update
                }
                
                $changedProperties = $null
                $changedProperties = (Compare-Object @splatCompareProperties -PassThru)
                $oldProperties = $changedProperties.Where( { $_.SideIndicator -eq "<=" })
                $newProperties = $changedProperties.Where( { $_.SideIndicator -eq "=>" })
    
                if (($changedProperties | Measure-Object).Count -ge 1) {
                    # Create custom object with old and new values
                    $changedPropertiesObject = [PSCustomObject]@{
                        OldValues = @{}
                        NewValues = @{}
                    }

                    # Add the old properties to the custom object with old and new values
                    foreach ($oldProperty in $oldProperties) {
                        $changedPropertiesObject.OldValues.$($oldProperty.Name) = $oldProperty.Value
                    }

                    # Add the new properties to the custom object with old and new values
                    foreach ($newProperty in $newProperties) {
                        $changedPropertiesObject.NewValues.$($newProperty.Name) = $newProperty.Value
                    }
                    Write-Verbose "Changed properties: $($changedPropertiesObject | ConvertTo-Json)"

                    $updateAction = 'Update'
                }
                else {
                    Write-Verbose "No changed properties"
                    
                    $updateAction = 'NoChanges'
                }
            }
            else {
                $action = 'Correlate'
            }
        }
    }
    catch {
        $ex = $PSItem
        $errorMessage = Get-ErrorMessage -ErrorObject $ex

        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage)"

        $auditLogs.Add([PSCustomObject]@{
                # Action  = "" # Optional
                Message = "Error querying account where [$($correlationProperty)] = [$($correlationValue)]. Error Message: $($errorMessage.AuditErrorMessage)"
                IsError = $true
            })

        # Skip further actions, as this is a critical error
        continue
    }

    # Either [create], [update and correlate] or just [correlate]
    switch ($action) {        
        "Update" {       
            switch ($updateAction) {
                "Update" {
                    # Update account
                    try {
                        # Create custom account object for update and set with default properties and values
                        $updateAccountObject = @{                            
                            Id             = $currentAccount.Id             #Mandatory Field within Set-CurrentPerson
                            Number         = $currentAccount.Number         #Mandatory Field within Set-CurrentPerson
                            EmployeeNumber = $currentAccount.EmployeeNumber #Mandatory Field within Set-CurrentPerson
                            LastName       = $currentAccount.LastName       #Mandatory Field within Set-CurrentPerson
                            EmailWork      = $account.EmailWork             #Field to update
                            Birthday       = $currentAccount.Birthday       #Mandatory Field within Set-CurrentPerson
                        }

                        $body = $null

                        foreach ($property in $updateAccountObject.GetEnumerator()) {
                            $body += "<emp:$($property.Name)>$($property.Value)</emp:$($property.Name)>"
                        }

                        Write-Verbose "Updating account [$($account.DisplayName) ($($currentAccount.Id))]. Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                            
                        if (-not($dryRun -eq $true)) {
                            $null = Set-CurrentPersonalInfo -EmployeeId $($account.Id) -EmployeeBody $body

                            # Set aRef object for use in futher actions
                            $aRef = [PSCustomObject]@{
                                Id = $currentAccount.Id
                            }

                            $auditLogs.Add([PSCustomObject]@{
                                    # Action  = "" # Optional
                                    Message = "Successfully updated account [$($updatedAccount.DisplayName) ($($updatedAccount.Id))]. Updated properties: $($changedPropertiesObject | ConvertTo-Json -Depth 10)"
                                    IsError = $false
                                })
                        }
                        else {
                            Write-Warning "DryRun: Would update account [$($account.DisplayName) ($($currentAccount.Id))]. Updated properties: $($changedPropertiesObject | ConvertTo-Json -Depth 10)"
                        }
                        break
                    }
                    catch {
                        $ex = $PSItem
                        $errorMessage = Get-ErrorMessage -ErrorObject $ex
                    
                        Write-Verbose "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($errorMessage.VerboseErrorMessage)"
                
                        $auditLogs.Add([PSCustomObject]@{
                                # Action  = "" # Optional
                                Message = "Error updating account [$($account.DisplayName) ($($currentAccount.Id))]. Error Message: $($errorMessage.AuditErrorMessage). Account object: $($updateAccountObject | ConvertTo-Json -Depth 10)"
                                IsError = $true
                            })
                    }

                    break
                }
                "NoChanges" {
                    Write-Verbose "No changes needed for account [$($account.DisplayName) ($($currentAccount.Id))]"

                    if (-not($dryRun -eq $true)) {
                        # Set aRef object for use in futher actions
                        $aRef = [PSCustomObject]@{
                            Id = $currentAccount.Id
                        }

                        $auditLogs.Add([PSCustomObject]@{
                                # Action  = "" # Optional
                                Message = "No changes needed for account [$($account.DisplayName) ($($currentAccount.Id))]"
                                IsError = $false
                            })
                    }
                    else {
                        Write-Warning "DryRun: No changes needed for account [$($account.DisplayName) ($($currentAccount.Id))]"
                    }                  

                    break
                }
            }

            # Define ExportData with account fields and correlation property 
            $exportData = $account.PsObject.Copy() | Select-Object $storeAccountFields
            # Add correlation property to exportdata
            $exportData | Add-Member -MemberType NoteProperty -Name $correlationProperty -Value $correlationValue -Force
            # Add aRef properties to exportdata
            foreach ($aRefProperty in $aRef.PSObject.Properties) {
                $exportData | Add-Member -MemberType NoteProperty -Name $aRefProperty.Name -Value $aRefProperty.Value -Force
            }
            # Add Nmbrs EmployeeNumber to ExportData
            $exportData.EmployeeNumber = $currentAccount.EmployeeNumber
            break
        }
        "Correlate" {
            Write-Verbose "Correlating to account [$($account.DisplayName) ($($currentAccount.Id))]"

            if (-not($dryRun -eq $true)) {
                # Set aRef object for use in futher actions
                $aRef = [PSCustomObject]@{
                    Id = $currentAccount.Id
                }

                $auditLogs.Add([PSCustomObject]@{
                        # Action  = "" # Optional
                        Message = "Successfully correlated to account [$($account.DisplayName) ($($currentAccount.Id))]"
                        IsError = $false
                    })
            }
            else {
                Write-Warning "DryRun: Would correlate to account [$($account.DisplayName) ($($currentAccount.Id))]"
            }

            # Define ExportData with account fields and correlation property 
            $exportData = $account.PsObject.Copy() | Select-Object $storeAccountFields
            # Add correlation property to exportdata
            $exportData | Add-Member -MemberType NoteProperty -Name $correlationProperty -Value $correlationValue -Force
            # Add aRef properties to exportdata
            foreach ($aRefProperty in $aRef.PSObject.Properties) {
                $exportData | Add-Member -MemberType NoteProperty -Name $aRefProperty.Name -Value $aRefProperty.Value -Force
            }
            # Add Nmbrs EmployeeNumber to ExportData
            $exportData.EmployeeNumber = $currentAccount.EmployeeNumber
            break
        }
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