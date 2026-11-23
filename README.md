# HelloID-Conn-Prov-Target-Nmbrs

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://github.com/Tools4everBV/HelloID-Conn-Prov-Target-Nmbrs/blob/main/Logo.png?raw=true">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Nmbrs](#helloid-conn-prov-target-nmbrs)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Provisioning PowerShell V2 connector](#provisioning-powershell-v2-connector)
      - [Correlation configuration](#correlation-configuration)
      - [Field mapping](#field-mapping)
    - [Connection settings](#connection-settings)
    - [Prerequisites](#prerequisites)
    - [Obtaining API credentials](#obtaining-api-credentials)
    - [Remarks](#remarks)
  - [Setup the connector](#setup-the-connector)
  - [Migrating from the SOAP version](#migrating-from-the-soap-version)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Nmbrs_ is a _target_ connector. _Nmbrs_ provides a set of REST APIs that allow you to programmatically interact with its data. This connector writes the business email address (`EmailWork`) of an existing employee back to Nmbrs. It does not create employees in Nmbrs.

> [!NOTE]
> Version 2.0.0 of this connector uses the Nmbrs **REST API** with OAuth 2.0. The deprecated SOAP API (`/soap/v3/EmployeeService.asmx`) is no longer used. See [Migrating from the SOAP version](#migrating-from-the-soap-version).

The following lifecycle actions are available:

| Action                                  | Description                                                                         |
| --------------------------------------- | ----------------------------------------------------------------------------------- |
| create.ps1                              | Correlates a HelloID person with an existing Nmbrs employee. No account is created. |
| update.ps1                              | Updates the business email address (`EmailWork`) when it differs from Nmbrs.       |
| delete.ps1                              | Clears the business email address (`EmailWork`) in Nmbrs.                           |
| configuration.json                      | Default _configuration.json_                                                        |
| fieldMapping.json                       | Default _fieldMapping.json_                                                         |
| GetRefreshTokenFromAuthorisationCode.ps1 | Helper script to generate the initial refresh token                                |

## Getting started

### Provisioning PowerShell V2 connector

#### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Nmbrs_ to a person in _HelloID_.

To properly setup the correlation:

1. Open the `Correlation` tab.

2. Specify the following configuration:

   | Setting                   | Value                             |
   | ------------------------- | --------------------------------- |
   | Enable correlation        | `True`                            |
   | Person correlation field  | `PersonContext.Person.ExternalId` |
   | Account correlation field | `Id`                              |

The `ExternalId` of a person imported by the [Nmbrs REST source connector](https://github.com/Tools4everBV/HelloID-Conn-Prov-Source-NMBRS) is the Nmbrs REST `EmployeeId` (GUID). This value is used as the account reference.

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

#### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

| Field     | Actions          | Description                                                                                |
| --------- | ---------------- | ------------------------------------------------------------------------------------------ |
| Id        | Create           | The Nmbrs REST EmployeeId. Mapped to `Person.ExternalId`.                                  |
| EmailWork | Create, Update   | Business email address (`personalInfo.contactInfo.businessEmail`). Default: AD `mail`.     |
| EmailWork | Delete           | Fixed empty value, which clears the business email address in Nmbrs.                      |

### Connection settings

The following settings are required to connect to the API.

| Setting              | Description                                                                                                                                       | Mandatory |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| BaseUrl              | The URL to the API. e.g. [https://api.nmbrsapp.com/api]                                                                                           | Yes       |
| TokenUrl             | The URL to retrieve the token. e.g. [https://identityservice.nmbrs.com/connect/token]                                                             | Yes       |
| TokenHost            | The host of the token URL. e.g. [identityservice.nmbrs.com]                                                                                       | Yes       |
| Client_id            | The client ID of the app definition in the Nmbrs partner portal                                                                                   | Yes       |
| Client_secret        | The client secret of the app definition in the Nmbrs partner portal                                                                               | Yes       |
| SubscriptionKey      | The subscription key (Primary Key) of the Nmbrs API subscription                                                                                  | Yes       |
| RefreshToken         | The initial refresh token, generated with `GetRefreshTokenFromAuthorisationCode.ps1`                                                              | Yes       |
| RefreshTokenSaveFile | Full path of the file on the HelloID agent server where the encrypted tokens are saved, e.g. `C:\HelloID\Nmbrs\target_token.json`                 | Yes       |
| proxyAddress         | The address of the proxy                                                                                                                          | No        |
| isDebug              | When toggled, debug logging will be displayed                                                                                                     | No        |

The previous settings `UserName`, `Token`, `Domain` and `version` (SOAP) are no longer used.

### Prerequisites

- An app definition in the Nmbrs partner portal, with a client ID and client secret.
- A Nmbrs API subscription with a subscription key.
- The app must be allowed to read and write employee personal info (scopes `employee.info.read` and `employee.info`).
- The connector stores the rotating refresh token in a file. Therefore it must run on a **HelloID agent (on-premises)**. In the `System` tab, select the option to execute on-premises.

### Obtaining API credentials

1. Log in to the Nmbrs partner portal (partner-portal.nmbrsapp.com) and go to **My Integrations**. Create a new app definition, or use an existing one. Here you find the **Client ID** and can create a **Client Secret**. Set the redirect URI to `http://localhost:8080`, or another unused local URL.
2. In **Products**, add a subscription for your Nmbrs environment. The **SubscriptionKey** is the Primary Key of the subscription, which is shown in your user profile.
3. Generate the initial refresh token:
   - Fill in the client ID, client secret and redirect URI in `GetRefreshTokenFromAuthorisationCode.ps1`.
   - Open the printed URL in a browser, log in with a Nmbrs account that is allowed to change employee personal info, and give consent.
   - Copy the `code` value from the address bar of the redirect page into the script and run the rest of the script.
   - Copy the refresh token from the result file into the `RefreshToken` setting of the connector and remove the result file.

> [!IMPORTANT]
> Do not use this refresh token anywhere else. Nmbrs invalidates a refresh token after each use and returns a new one.

### Remarks

- **Token handling.** Nmbrs rotates the refresh token on every use. The connector saves the new refresh token and the access token, both encrypted with DPAPI, in `RefreshTokenSaveFile`. As long as the access token is valid, it is reused, so not every action refreshes the token. Access to the file is guarded by a named mutex, because HelloID can run target actions in parallel on the agent.
- **Token file per connector.** Use a separate token file and a separate refresh token for the source and the target connector. Use one HelloID agent server for this target connector, because the token file and the mutex are local to the server.
- **Invalid refresh token.** When the saved refresh token is no longer valid, the connector automatically tries the `RefreshToken` from the configuration. So after generating a new refresh token, you only have to save it in the configuration. Deleting the token file is not needed.
- **Encryption.** The token file can only be decrypted by the Windows account that wrote it. When the service account of the HelloID agent changes, remove the token file and provide a new refresh token.
- **Update of the business email.** The update action reads the current personal info of the employee (`GET /employees/{employeeId}`), changes only `contactInfo.businessEmail`, and sends the personal info back. This way no other personal info is overwritten with empty values. Read-only properties (`personalInfoId`, `createdAt`) are removed from the request.
- **No account creation.** When no Nmbrs employee is found for the correlation value, the create action fails. Accounts are not created with this connector.

> [!WARNING]
> The update endpoint is set at the top of `update.ps1` and `delete.ps1`:
> ```powershell
> $script:UpdatePersonalInfoPath = 'employees/{0}/personalInfo'
> $script:ReadOnlyPersonalInfoProperties = @('personalInfoId', 'createdAt')
> ```
> Before going live, check in the [Nmbrs REST API reference](https://nmbrs.stoplight.io/docs/nmbrs-restapi/YXBpOjEyMDg0NzYw-nmbrs-public-rest-api) that the path and the request body of the operation "Update employee personal info" match, and test the update in a Nmbrs test environment. Adjust these two settings if needed.

## Setup the connector

1. Import the connector in HelloID as a PowerShell V2 target system.
2. Fill in the connection settings. See [Connection settings](#connection-settings).
3. Configure the correlation. See [Correlation configuration](#correlation-configuration).
4. Import `fieldMapping.json` and adjust the `EmailWork` mapping if needed.
5. In the `System` tab, select the option to execute on-premises.
6. Test with a single person (preview/dry run first) before enabling enforcement for all persons.

## Migrating from the SOAP version

- **Other EmployeeId.** The EmployeeId of the REST API (GUID) differs from the EmployeeId of the SOAP API (number). Existing account references from the SOAP version do not work with the REST version. Plan the migration together with the [Nmbrs REST source connector](https://github.com/Tools4everBV/HelloID-Conn-Prov-Source-NMBRS) (version 3.0.0 or later):
  1. Upgrade the source connector first, so `Person.ExternalId` contains the REST EmployeeId.
  2. Unmanage the existing accounts of this target system (or remove the entitlements without running the delete action), so the delete action does not clear the business email addresses.
  3. Replace the scripts, configuration and field mapping with this version.
  4. Grant the entitlements again. The create action then correlates the accounts with the new REST EmployeeId.
- **Other credentials.** The SOAP settings `UserName`, `Token`, `Domain` and `version` are replaced by OAuth 2.0 settings. See [Connection settings](#connection-settings).
- **Field mapping.** The `Id` mapping is changed from `Person.Custom.employeeId` to `Person.ExternalId`.

## Development resources

API documentation for the Nmbrs REST API:

https://nmbrs.stoplight.io/docs/nmbrs-restapi/9c14f1c024642-getting-started

### API endpoints

| Endpoint                                   | Method | Description                                         |
| ------------------------------------------ | ------ | --------------------------------------------------- |
| https://identityservice.nmbrs.com/connect/token | POST   | Get an access token with a refresh token        |
| /employees/{employeeId}                    | GET    | Get the employee, including the personal info       |
| /employees/{employeeId}/personalInfo       | PUT    | Update the personal info (business email address)   |

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
> _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/4928-helloid-conn-prov-target-nmbrs)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
