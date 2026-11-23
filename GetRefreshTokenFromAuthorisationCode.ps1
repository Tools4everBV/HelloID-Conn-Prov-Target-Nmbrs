#################################################
# HelloID-Conn-Prov-Target-Nmbrs
# Helper script to obtain the initial refresh token
#################################################
# 1. Fill in the Client_id, Client_secret and RedirectUri (must match the app definition in the Nmbrs partner portal).
# 2. Run the first part of the script and open the printed URL in a browser.
# 3. Log in with a Nmbrs account that is allowed to change employee personal info and give consent.
# 4. You are redirected to the RedirectUri. This shows a "not found" page, but the address bar contains ?code=...
#    Copy the value of the code parameter into $AuthorizationCode below and run the second part of the script.
#    The authorization code is valid for a short time only and can be used once.
# 5. Copy the refresh token from the result file into the "Initial RefreshToken" setting of the HelloID connector
#    and remove the result file afterwards.
#
# Note: the connector writes data to Nmbrs, so the write scope employee.info is requested.

Add-Type -AssemblyName System.Web

$config = @{
    TokenUrl               = 'https://identityservice.nmbrs.com/connect/token'
    TokenHost              = 'identityservice.nmbrs.com'
    AuthorizeUrl           = 'https://identityservice.nmbrs.com/connect/authorize'
    State                  = [guid]::NewGuid().ToString()
    RedirectUri            = 'http://localhost:8080'
    Scope                  = 'offline_access employee.info.read employee.info'
    Client_secret          = '<YOUR_CLIENT_SECRET>'
    Client_id              = '<YOUR_CLIENT_ID>'
    ResultRefreshTokenFile = 'C:\Temp\nmbrs_target_refresh_token_tmp.txt'
}

# Part 1: open this URL in a web browser
$browserUri = "$($config.AuthorizeUrl)?client_id=$([System.Web.HttpUtility]::UrlEncode($config.Client_id))&state=$($config.State)&scope=$([System.Web.HttpUtility]::UrlEncode($config.Scope))&response_type=code&redirect_uri=$([System.Web.HttpUtility]::UrlEncode($config.RedirectUri))"
Write-Host "Open this URL in a web browser:`n$browserUri"

# Part 2: paste the authorization code and run the rest of the script
$AuthorizationCode = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX-X'

$authenticationString = [System.Web.HttpUtility]::UrlEncode($config.Client_id) + ':' + [System.Web.HttpUtility]::UrlEncode($config.Client_secret)
$authorization = 'Basic ' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($authenticationString))

$splatParams = @{
    Uri         = $config.TokenUrl
    Method      = 'POST'
    ContentType = 'application/x-www-form-urlencoded'
    Headers     = @{
        'Authorization' = $authorization
        'Host'          = $config.TokenHost
    }
    Body        = "grant_type=authorization_code&code=$([System.Web.HttpUtility]::UrlEncode($AuthorizationCode))&redirect_uri=$([System.Web.HttpUtility]::UrlEncode($config.RedirectUri))"
}
try {
    $response = Invoke-RestMethod @splatParams -UseBasicParsing
    $response.refresh_token | Out-File $config.ResultRefreshTokenFile
    Write-Host "Refresh token saved to $($config.ResultRefreshTokenFile). Granted scopes: $($response.scope)"
}
catch {
    $ex = $PSItem
    Write-Error "An error occurred while retrieving the refresh token: $($ex.Exception.Message) $($ex.ErrorDetails.Message)"
}
