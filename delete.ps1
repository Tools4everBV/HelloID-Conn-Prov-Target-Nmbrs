#################################################
# HelloID-Conn-Prov-Target-Nmbrs-Delete
# PowerShell V2
# Nmbrs REST API (OAuth 2.0)
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($actionContext.Configuration.isDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}
$InformationPreference = 'Continue'
$WarningPreference = 'Continue'

#region settings
# Nmbrs REST endpoint (relative to BaseUrl) used to update the personal info of an employee. {0} = employeeId
$script:UpdatePersonalInfoPath = 'employees/{0}/personalInfo'
# Properties returned by GET /employees/{employeeId} that must not be sent in the update body
$script:ReadOnlyPersonalInfoProperties = @('personalInfoId', 'createdAt')
#endregion settings

#region functions
function ConvertFrom-ProtectedString {
    param (
        [string]
        $ProtectedString
    )
    if ([string]::IsNullOrEmpty($ProtectedString)) {
        return $null
    }
    $secureString = ConvertTo-SecureString -String $ProtectedString
    Write-Output (New-Object System.Net.NetworkCredential('', $secureString)).Password
}

function ConvertTo-ProtectedString {
    param (
        [string]
        $PlainString
    )
    $secureString = ConvertTo-SecureString -String $PlainString -AsPlainText -Force
    Write-Output (ConvertFrom-SecureString -SecureString $secureString)
}

function Invoke-NmbrsTokenRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $RefreshToken
    )
    $config = $actionContext.Configuration
    $splatParams = @{
        Uri         = $config.TokenUrl
        Method      = 'POST'
        Body        = "refresh_token=$([System.Uri]::EscapeDataString($RefreshToken))&grant_type=refresh_token"
        ContentType = 'application/x-www-form-urlencoded'
        Headers     = @{
            'Authorization' = 'Basic ' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($config.Client_id):$($config.Client_secret)"))
            'Host'          = "$($config.TokenHost)"
        }
    }
    if (-not [string]::IsNullOrEmpty($config.ProxyAddress)) {
        $splatParams['Proxy'] = $config.ProxyAddress
    }
    Invoke-RestMethod @splatParams -Verbose:$false
}

function Get-NmbrsAccessToken {
    # Nmbrs rotates the refresh token on every use. Target actions can run in parallel on the agent,
    # so the token file is guarded by a named mutex and a still-valid access token is reused.
    [CmdletBinding()]
    param ()

    $config = $actionContext.Configuration
    if ([string]::IsNullOrEmpty($config.RefreshTokenSaveFile)) {
        throw 'The configuration setting [RefreshTokenSaveFile] is empty'
    }

    $mutex = New-Object System.Threading.Mutex($false, 'HelloID-Conn-Prov-Target-Nmbrs-TokenFile')
    $lockAcquired = $false
    try {
        try {
            $lockAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds(120))
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            throw 'Timeout while waiting for the lock on the Nmbrs token file'
        }

        # Read the token cache
        $cache = $null
        if ([System.IO.File]::Exists($config.RefreshTokenSaveFile)) {
            $rawContent = (Get-Content -Path $config.RefreshTokenSaveFile -Raw).Trim()
            try {
                if ($rawContent.StartsWith('{')) {
                    $fileObject = $rawContent | ConvertFrom-Json
                    $cache = [PSCustomObject]@{
                        RefreshToken      = ConvertFrom-ProtectedString $fileObject.refreshToken
                        AccessToken       = ConvertFrom-ProtectedString $fileObject.accessToken
                        TokenType         = $fileObject.tokenType
                        ExpiresAtUtcTicks = [long]$fileObject.expiresAtUtcTicks
                    }
                }
                else {
                    # File only contains an encrypted refresh token
                    $cache = [PSCustomObject]@{
                        RefreshToken      = ConvertFrom-ProtectedString $rawContent
                        AccessToken       = $null
                        TokenType         = $null
                        ExpiresAtUtcTicks = 0
                    }
                }
            }
            catch {
                throw 'The saved token file could not be decrypted. Make sure the HelloID agent runs under the Windows account that saved it, or remove the file and provide a new refresh token in the configuration.'
            }
        }

        # Reuse the cached access token when it is valid for at least 2 more minutes
        if ($null -ne $cache -and -not [string]::IsNullOrEmpty($cache.AccessToken) -and
            $cache.ExpiresAtUtcTicks -gt [DateTime]::UtcNow.AddMinutes(2).Ticks) {
            Write-Verbose 'Using cached Nmbrs access token'
            return [PSCustomObject]@{
                token_type   = $cache.TokenType
                access_token = $cache.AccessToken
            }
        }

        # Refresh the access token. First the saved refresh token, then the one from the configuration
        $candidateTokens = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $cache -and -not [string]::IsNullOrEmpty($cache.RefreshToken)) {
            $candidateTokens.Add($cache.RefreshToken)
        }
        if (-not [string]::IsNullOrEmpty($config.RefreshToken) -and -not $candidateTokens.Contains($config.RefreshToken)) {
            $candidateTokens.Add($config.RefreshToken)
        }
        if ($candidateTokens.Count -eq 0) {
            throw 'No refresh token available. Provide an initial refresh token in the configuration.'
        }

        $tokenResponse = $null
        $lastError = $null
        foreach ($candidate in $candidateTokens) {
            try {
                $tokenResponse = Invoke-NmbrsTokenRequest -RefreshToken $candidate
                break
            }
            catch {
                $lastError = $_
                Write-Verbose "Refreshing the Nmbrs access token failed with one of the available refresh tokens. Error: $($_.Exception.Message)"
            }
        }
        if ($null -eq $tokenResponse) {
            throw "Could not obtain a Nmbrs access token. Generate a new refresh token with GetRefreshTokenFromAuthorisationCode.ps1. Error: $($lastError.Exception.Message) $($lastError.ErrorDetails.Message)"
        }

        # Save the new tokens
        $expiresIn = 3600
        if ($null -ne $tokenResponse.expires_in) {
            $expiresIn = [int]$tokenResponse.expires_in
        }
        $fileObject = [PSCustomObject]@{
            refreshToken      = ConvertTo-ProtectedString $tokenResponse.refresh_token
            accessToken       = ConvertTo-ProtectedString $tokenResponse.access_token
            tokenType         = $tokenResponse.token_type
            expiresAtUtcTicks = [DateTime]::UtcNow.AddSeconds($expiresIn).Ticks
        }
        $fileObject | ConvertTo-Json | Set-Content -Path $config.RefreshTokenSaveFile -Encoding ASCII -NoNewline

        Write-Output $tokenResponse
    }
    finally {
        if ($lockAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Invoke-NmbrsRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [Parameter(Mandatory)]
        [string]
        $Method,

        [object]
        $Body
    )
    try {
        $splatParams = @{
            Uri         = $Uri
            Method      = $Method
            ContentType = 'application/json; charset=utf-8'
            Headers     = @{
                'Authorization'      = "$($script:apiToken.token_type) $($script:apiToken.access_token)"
                'X-Subscription-Key' = "$($actionContext.Configuration.SubscriptionKey)"
                'Accept'             = 'application/json'
            }
        }
        if ($null -ne $Body) {
            $splatParams['Body'] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))
        }
        if (-not [string]::IsNullOrEmpty($actionContext.Configuration.ProxyAddress)) {
            $splatParams['Proxy'] = $actionContext.Configuration.ProxyAddress
        }
        Invoke-RestMethod @splatParams -Verbose:$false
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-NmbrsEmployee {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $EmployeeId
    )
    try {
        $response = Invoke-NmbrsRestMethod -Uri "$($actionContext.Configuration.BaseUrl)/employees/$EmployeeId" -Method 'GET'
    }
    catch {
        if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
    if ($null -ne $response.data) {
        if (@($response.data).Count -eq 0) {
            return $null
        }
        return @($response.data)[0]
    }
    Write-Output $response
}

function Resolve-NmbrsError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException' -and $null -ne $ErrorObject.Exception.Response) {
            try {
                $httpErrorObj.ErrorDetails = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
            }
            catch {
                Write-Verbose 'Could not read the error response stream'
            }
        }
        try {
            $errorDetailsObject = $httpErrorObj.ErrorDetails | ConvertFrom-Json -ErrorAction Stop
            $messages = @($errorDetailsObject.message, $errorDetailsObject.title, $errorDetailsObject.detail, $errorDetailsObject.error_description, $errorDetailsObject.error) |
                Where-Object { -not [string]::IsNullOrEmpty($_) }
            if ($errorDetailsObject.errors) {
                $messages += ($errorDetailsObject.errors | ConvertTo-Json -Depth 5 -Compress)
            }
            if ($messages) {
                $httpErrorObj.FriendlyMessage = $messages -join ' '
            }
        }
        catch {
            if (-not [string]::IsNullOrEmpty($httpErrorObj.ErrorDetails)) {
                $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            }
        }
        Write-Output $httpErrorObj
    }
}

function Set-NmbrsBusinessEmail {
    # Sends the current personal info of the employee back to Nmbrs with only contactInfo.businessEmail changed,
    # so no other personal info is overwritten with empty values.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $EmployeeId,

        [Parameter(Mandatory)]
        [object]
        $CurrentEmployee,

        [AllowEmptyString()]
        [AllowNull()]
        [string]
        $BusinessEmail
    )

    # Deep copy of the current personal info
    $personalInfo = $CurrentEmployee.personalInfo | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if ($null -eq $personalInfo) {
        throw "The personal info of Nmbrs employee [$EmployeeId] could not be read"
    }
    foreach ($propertyName in $script:ReadOnlyPersonalInfoProperties) {
        $personalInfo.PSObject.Properties.Remove($propertyName)
    }
    if ($null -eq $personalInfo.contactInfo) {
        $personalInfo | Add-Member -NotePropertyName 'contactInfo' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $personalInfo.contactInfo | Add-Member -NotePropertyName 'businessEmail' -NotePropertyValue $BusinessEmail -Force

    $uri = "$($actionContext.Configuration.BaseUrl)/$($script:UpdatePersonalInfoPath -f $EmployeeId)"
    Write-Verbose "PUT $uri Body: $($personalInfo | ConvertTo-Json -Depth 10)"
    Invoke-NmbrsRestMethod -Uri $uri -Method 'PUT' -Body $personalInfo
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $script:apiToken = Get-NmbrsAccessToken

    Write-Information 'Verifying if a Nmbrs account exists'
    $correlatedAccount = Get-NmbrsEmployee -EmployeeId $actionContext.References.Account

    if ($null -ne $correlatedAccount) {
        $currentEmailWork = "$($correlatedAccount.personalInfo.contactInfo.businessEmail)"
        # The field mapping sets EmailWork to an empty value for the Delete action
        $newEmailWork = "$($actionContext.Data.EmailWork)"

        if ($currentEmailWork -ne $newEmailWork) {
            $action = 'DeleteAccount'
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
        'DeleteAccount' {
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Clearing EmailWork of Nmbrs account with accountReference: [$($actionContext.References.Account)]"
                $null = Set-NmbrsBusinessEmail -EmployeeId $actionContext.References.Account -CurrentEmployee $correlatedAccount -BusinessEmail $newEmailWork
            }
            else {
                Write-Information "[DryRun] Would update Nmbrs account with accountReference: [$($actionContext.References.Account)], current EmailWork [$currentEmailWork] new EmailWork [$newEmailWork]"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'DeleteAccount'
                    Message = "Delete account was successful (EmailWork cleared), previous EmailWork [$currentEmailWork] new EmailWork [$newEmailWork]"
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "EmailWork of Nmbrs account [$($actionContext.References.Account)] already has the required value"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'DeleteAccount'
                    Message = 'Delete account was successful, no changes required'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Nmbrs account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'DeleteAccount'
                    Message = "Nmbrs account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                    IsError = $false
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
        $auditMessage = "Could not delete Nmbrs account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not delete Nmbrs account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = 'DeleteAccount'
            Message = $auditMessage
            IsError = $true
        })
}
