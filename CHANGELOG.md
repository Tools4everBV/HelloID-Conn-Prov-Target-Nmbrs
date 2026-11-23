# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [2.0.0] - 2026-11-23

### Added

- OAuth 2.0 authentication (refresh token flow) with client ID, client secret and subscription key (`X-Subscription-Key`).
- Token cache in `RefreshTokenSaveFile`: the rotating refresh token and the access token are saved encrypted (DPAPI). A valid access token is reused.
- Named mutex around the token file, so parallel target actions on the agent do not use the same refresh token twice.
- Automatic fallback to the `RefreshToken` from the configuration when the saved refresh token is invalid.
- Helper script `GetRefreshTokenFromAuthorisationCode.ps1` to generate the initial refresh token (scopes `offline_access employee.info.read employee.info`).
- Configuration settings `BaseUrl`, `TokenUrl`, `TokenHost`, `Client_id`, `Client_secret`, `SubscriptionKey`, `RefreshToken`, `RefreshTokenSaveFile` and `isDebug`.
- Settings `$script:UpdatePersonalInfoPath` and `$script:ReadOnlyPersonalInfoProperties` at the top of `update.ps1` and `delete.ps1`.

### Changed

- Complete conversion from the deprecated Nmbrs SOAP API (`EmployeeService.asmx`) to the Nmbrs REST API.
- Employee lookup uses `GET /employees/{employeeId}`. Update and delete use `PUT /employees/{employeeId}/personalInfo` and change only `contactInfo.businessEmail`. The other personal info is sent back unchanged.
- The account reference is now the REST EmployeeId (GUID). The `Id` field mapping is changed from `Person.Custom.employeeId` to `Person.ExternalId`, in line with the Nmbrs REST source connector 3.0.0.
- Create correlates on the correlation value (`accountFieldValue`) instead of the mapped `Id`.
- Update only compares `EmailWork` with the business email in Nmbrs, instead of comparing all properties.
- Delete is skipped when the business email is already empty.
- `EmailWork` is stored in the account data, so the previous value is visible in HelloID.
- Error handling: `Resolve-NmbrsError` now returns a readable error message from the API response.

### Deprecated

- All SOAP API functionality has been removed.

### Removed

- Configuration settings `UserName`, `Token`, `Domain` and `version` (SOAP).

## [1.0.0]

First release of _HelloID-Conn-Prov-Target-Nmbrs_, based on the Nmbrs SOAP API v3.
