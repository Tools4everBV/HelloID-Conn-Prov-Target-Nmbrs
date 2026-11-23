#################################################
# HelloID-Conn-Prov-Target-Nmbrs-Create
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
    }
    else {
        throw 'Configuration of correlation is mandatory.'
    }

    $script:apiToken = Get-NmbrsAccessToken

    # Determine if a user needs to be [created] or [correlated]
    Write-Information "Querying Nmbrs employee where [$($correlationField)] = [$($correlationValue)]"
    $currentAccount = Get-NmbrsEmployee -EmployeeId $correlationValue

    if ($null -ne $currentAccount) {
        $action = 'CorrelateAccount'
    }
    else {
        $action = 'CreateAccount'
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            throw "No Nmbrs employee found where [$($correlationField)] = [$($correlationValue)]. Accounts are not created with this connector."
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Nmbrs account'

            $outputContext.Data = [PSCustomObject]@{
                Id        = $correlationValue
                EmailWork = $currentAccount.personalInfo.contactInfo.businessEmail
            }
            $outputContext.AccountReference = $correlationValue
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($personContext.Person.DisplayName)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.Success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NmbrsError -ErrorObject $ex
        $auditMessage = "Could not correlate Nmbrs account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not correlate Nmbrs account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = 'CreateAccount'
            Message = $auditMessage
            IsError = $true
        })
}
