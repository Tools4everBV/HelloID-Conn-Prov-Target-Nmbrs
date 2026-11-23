#################################################
# HelloID-Conn-Prov-Target-Nmbrs-Import
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
# Employee types that are retrieved from Nmbrs (same list as the Nmbrs source connector)
$script:ImportEmployeeTypes = 'applicant,newHire,payroll,formerPayroll,external,formerExternal,rejectedApplicant'
# Employee types that are reported as disabled
$script:DisabledEmployeeTypes = @('formerPayroll', 'formerExternal', 'rejectedApplicant')
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

function Invoke-NmbrsRestMethodWithRetry {
    # Retries a request when Nmbrs returns 429 (Too Many Requests) or a 5xx error
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [int]
        $MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        try {
            return Invoke-NmbrsRestMethod -Uri $Uri -Method 'GET'
        }
        catch {
            $statusCode = 0
            if ($null -ne $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $attempt++
            if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -le $MaxRetries) {
                $waitSeconds = [Math]::Min(60, 5 * $attempt)
                Write-Verbose "Request [$Uri] returned [$statusCode]. Retry $attempt of $MaxRetries in $waitSeconds seconds"
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            throw
        }
    }
}

function Get-NmbrsPagedList {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [int]
        $PageSize = 100
    )
    $separator = '?'
    if ($Uri.Contains('?')) {
        $separator = '&'
    }
    $pageNumber = 1
    do {
        $response = Invoke-NmbrsRestMethodWithRetry -Uri "$Uri$($separator)pageNumber=$pageNumber&pageSize=$PageSize"
        $totalPages = [int]$response.pagination.totalPages
        if ($totalPages -gt 10000) {
            throw 'Total pages is greater than 10000, stopping to avoid an infinite loop'
        }
        foreach ($item in @($response.data)) {
            if ($null -ne $item) {
                Write-Output $item
            }
        }
        $pageNumber++
    } while ($pageNumber -le $totalPages -and @($response.data).Count -gt 0)
}
#endregion

try {
    Write-Information 'Starting Nmbrs account entitlement import'

    $script:apiToken = Get-NmbrsAccessToken

    # Determine the companies to import
    Write-Information 'Retrieving Nmbrs companies'
    $companies = @(Get-NmbrsPagedList -Uri "$($actionContext.Configuration.BaseUrl)/companies")
    if (-not [string]::IsNullOrWhiteSpace($actionContext.Configuration.CompanyName)) {
        $companyNames = @($actionContext.Configuration.CompanyName.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($companyName in $companyNames) {
            if (-not ($companies | Where-Object { $_.name -eq $companyName })) {
                throw "Company [$companyName] not found in Nmbrs"
            }
        }
        $companies = @($companies | Where-Object { $companyNames -contains $_.name })
    }
    Write-Information "Importing employees of [$($companies.Count)] company(s): $(($companies.name) -join ', ')"

    $importedEmployeeIds = [System.Collections.Generic.HashSet[string]]::new()
    $importedCount = 0
    foreach ($company in $companies) {
        $employeeList = @(Get-NmbrsPagedList -Uri "$($actionContext.Configuration.BaseUrl)/companies/$($company.companyId)/employees?employeeType=$($script:ImportEmployeeTypes)")
        Write-Verbose "Company [$($company.name)]: [$($employeeList.Count)] employees found"

        foreach ($employeeListItem in $employeeList) {
            $employeeId = "$($employeeListItem.employeeId)"
            if ([string]::IsNullOrEmpty($employeeId) -or -not $importedEmployeeIds.Add($employeeId)) {
                continue
            }

            $response = Invoke-NmbrsRestMethodWithRetry -Uri "$($actionContext.Configuration.BaseUrl)/employees/$employeeId"
            $employee = $response
            if ($null -ne $response.data) {
                $employee = @($response.data)[0]
            }
            if ($null -eq $employee) {
                continue
            }

            $personalInfo = $employee.personalInfo
            $businessEmail = "$($personalInfo.contactInfo.businessEmail)"

            # An employee is an account in this target system when the business email address is filled
            if ([string]::IsNullOrWhiteSpace($businessEmail)) {
                continue
            }

            $importedAccount = [PSCustomObject]@{
                Id             = $employeeId
                EmailWork      = $businessEmail
                EmployeeNumber = $personalInfo.basicInfo.employeeNumber
                EmployeeType   = $personalInfo.basicInfo.employeeType
                CompanyName    = $company.name
            }

            $data = @{}
            foreach ($field in $actionContext.ImportFields) {
                $data[$field] = $importedAccount."$field"
            }

            $displayName = (@($personalInfo.basicInfo.firstName, $personalInfo.basicInfo.prefix, $personalInfo.basicInfo.lastName) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $employeeId
            }

            # Former and rejected employees are reported as disabled
            $enabled = $script:DisabledEmployeeTypes -notcontains "$($personalInfo.basicInfo.employeeType)"

            Write-Output @{
                AccountReference = $employeeId
                DisplayName      = $displayName
                UserName         = $businessEmail
                Enabled          = $enabled
                Data             = $data
            }
            $importedCount++
        }
    }

    Write-Information "Nmbrs account entitlement import completed. [$importedCount] account(s) imported"
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NmbrsError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Nmbrs account entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Nmbrs account entitlements. Error: $($ex.Exception.Message)"
    }
}
