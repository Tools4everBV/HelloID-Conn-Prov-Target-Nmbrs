# HelloID-Conn-Prov-Target-Nmbrs

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://www.tools4ever.nl/connector-logos/vismanmbrs-logo.png" width="500">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Nmbrs](#helloid-conn-prov-target-connectorname)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Provisioning PowerShell V2 connector](#provisioning-powershell-v2-connector)
      - [Correlation configuration](#correlation-configuration)
      - [Field mapping](#field-mapping)
    - [Connection settings](#connection-settings)
    - [Prerequisites](#prerequisites)
    - [Remarks](#remarks)
  - [Setup the connector](#setup-the-connector)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Nmbrs_ is a _target_ connector. _Nmbrs_ provides a set of REST API's that allow you to programmatically interact with its data. The HelloID connector uses the API endpoints listed in the table below.

| Endpoint              | Description                                 |
| --------------------- | ------------------------------------------- |
| /EmployeeService.asmx | info regarding persons, contracts and so on |

The following lifecycle actions are available:

| Action             | Description                          |
| ------------------ | ------------------------------------ |
| create.ps1         | PowerShell _create_ lifecycle action |
| delete.ps1         | PowerShell _delete_ lifecycle action |
| update.ps1         | PowerShell _update_ lifecycle action |
| configuration.json | Default _configuration.json_         |
| fieldMapping.json  | Default _fieldMapping.json_          |

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

> [!TIP] > _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

#### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

### Connection settings

The following settings are required to connect to the API.

| Setting      | Description                                          | Mandatory |
| ------------ | ---------------------------------------------------- | --------- |
| UserName     | The UserName to connect to the API                   | Yes       |
| Token        | The token to connect to the API                      | Yes       |
| Domain       | The Domain [mydomain.nmbrs.nl] to connect to the API | Yes       |
| BaseUrl      | The URL to the API.[https://api.nmbrs.nl]            | Yes       |
| Version      | The version of the API [v3]                          | Yes       |
| proxyAddress | The address of the proxy                             | No        |

### Prerequisites

There are no specific requirements besides the necessary connection settings.

### Remarks

Some fields are mandatory to provide to the NMBRS api to perform updates. The value for these fields will be used from the employee data which is returned from the NMBRS api when looking up the employee.

## Setup the connector

> _How to setup the connector in HelloID._ Are special settings required. Like the _primary manager_ settings for a source connector.

## Getting help

> [!TIP] > _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP] > _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/4928-helloid-conn-prov-target-nmbrs)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
