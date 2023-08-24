# HelloID-Conn-Prov-Target-Nmbrs
Repository for HelloID Provisioning Target Connector Nmbrs


| :information_source: Information                                                         |
| :--------------------------------------------------------------------------------------- |
| This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.       |

<br /> 
<p align="center">
  <img src="https://www.tools4ever.nl/connector-logos/vismanmbrs-logo.png" width="500">
</p>

## Versioning
| Version | Description     |
| ------- | --------------- |
| 1.0.0   | Initial release |

<!-- TABLE OF CONTENTS -->
## Table of Contents
- [HelloID-Conn-Prov-Target-Nmbrs](#helloid-conn-prov-target-nmbrs)
  - [Versioning](#versioning)
  - [Table of Contents](#table-of-contents)
  - [Requirements](#requirements)
  - [Introduction](#introduction)
  - [Getting Started](#getting-started)
    - [Application Registration](#application-registration)
    - [Configuring App Permissions](#configuring-app-permissions)
    - [Connection settings](#connection-settings)
  - [Remarks](#remarks)
  - [Getting help](#getting-help)
  - [HelloID Docs](#helloid-docs)

## Requirements
There are no specific requirements besides the necessary connection settings.

## Introduction
_HelloID-Conn-Prov-Target-NMBRS_ is a _target_ connector. NMBRS provides a set of SOAP API's that allow you to programmatically interact with it's data. The HelloID connector uses the API endpoints listed in the table below.

| Endpoint     | Description |
| ------------ | ----------- |
| https://api.nmbrs.nl/soap/v3/EmployeeService.asmx? | info regarding persons, contracts and so on           |


With this connector you can add, update and delete employee information within NMBRS. The current code only provides the possibility to update the business e-mailaddress of an employee.

| Action | Action(s) Performed | Comment |
| ------ | ------------------- | ------- |
| create.ps1                | Correlate or Correlate-Update employee                                              | Users are only correlated or correlated and updated when this is configured, **make sure to check your configuration options to set the right option**. |
| update.ps1                | Update account                                                        | Update the e-mailaddress.   |
| delete.ps1                | Remove account                                                        | Updates the e-mailaddress in NMBRS with an empty value.              |

## Getting Started

### Connection settings
The following settings are required to connect to the API.

| Setting      | Description                        | Mandatory   |
| ------------ | -----------                        | ----------- |
| UserName     | The UserName to connect to the API | Yes         |
| Token        | The token to connect to the API | Yes         |
| Domain      | The Domain [mydomain.nmbrs.nl] to connect to the API                | Yes         |
| BaseUrl | The URL to the API.[https://api.nmbrs.nl] | Yes |
| Version | The version of the API [v3]               | Yes |
| CompanyId | The companyId for which the employees will be imported | Yes |
|proxyAddress| The addres of the proxy  |No |
|IsDebug | When toggled, debug logging will be displayed |
| updateOnCorrelate | When toggled, employee will be updated on correlation | 


## Remarks
Some fields are mandatory to provide to the NMBRS api to perform updates. The value for these fields will be used from the employee data which is returned from the NMBRS api when looking up the employee.

## Getting help
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/hc/en-us/articles/360012518799-How-to-add-a-target-system) pages_

> _If you need help, feel free to ask questions on our [TODO-forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/0000-helloid-provisioning-helloid-conn-prov-target-nmbrs)_

## HelloID Docs
The official HelloID documentation can be found at: https://docs.helloid.com/
