# Azure Database for MySQL long-term retention

This repository automates logical backups of Azure Database for MySQL databases for long-term retention. Azure Automation starts a runbook that creates an Azure Container Instance, runs `mysqldump`, writes the resulting SQL dump to an Azure Files share, and copies it to the Blob Storage container associated with the schedule that triggered the runbook.

## Architecture

The Bicep template deploys and configures:

- An Azure Automation account with a PowerShell 7.6 runbook and customizable weekly, monthly, and yearly schedules
- A user-assigned managed identity and the role assignments needed by the runbook
- A geo-redundant storage account, Azure Files share, per-schedule blob containers, and private endpoints
- An Azure Container Registry and ACR task that builds the image from this repository
- Automation credentials for MySQL and the container registry

At a scheduled time, the runbook creates a container group in the supplied delegated subnet. The container mounts the file share, runs `mysqldump` for the configured databases, copies the generated dump to the blob container mapped to that schedule with `azcopy` and the user-assigned managed identity, and stops after the backup completes. Backup files are named `dumps-<timestamp>.sql`.

## Prerequisites

Before deploying, ensure that:

- You have an existing virtual network with a subnet delegated to `Microsoft.ContainerInstance/containerGroups`.
- You have a separate subnet available for the storage account private endpoints.
- The `privatelink.file.core.windows.net` private DNS zone exists and is linked to the container virtual network.
- The `privatelink.blob.core.windows.net` private DNS zone exists and is linked to the container virtual network.
- The container subnet can resolve and connect to the MySQL server.
- The deployment identity can create resources and role assignments at the target resource group and virtual network scopes.
- The MySQL account can read all databases selected for backup.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FSvenAelterman%2Fazure-mysql-ltr%2Fmain%2Ftemplate%2Ftemplate.json)

You can also deploy with Azure CLI and a Bicep parameters file:

```powershell
az deployment group create `
 --resource-group <resource-group-name> `
 --template-file template/template.bicep `
 --parameters template/<parameters-file>.bicepparam
```

Do not commit real database passwords to a parameters file. Supply `mySqlPassword` through a secure deployment process.

## Template parameters

The entry point is [`template/template.bicep`](template/template.bicep).

| Parameter | Type | Required | Default | Description |
| --- | --- | :---: | --- | --- |
| `storageAccountName` | string | No | `mysqlltrprodst01<unique>` | Name of the storage account that holds the backup file share. |
| `automationAccountName` | string | No | `MySQLLTR-prod-aa-<location>-01` | Name of the Azure Automation account. |
| `userAssignedIdentityName` | string | No | `MySQLLTR-prod-id-<location>-01` | Name of the user-assigned managed identity used by the runbook and container workflow. |
| `location` | string | No | Resource group location | Azure region for the deployed resources. |
| `backupFileShareName` | string | No | `backup-file-share` | Name of the Azure Files share where SQL dumps are stored. |
| `backupBlobContainerNames` | array of strings | No | `['backup-weekly-container', 'backup-monthly-container', 'backup-yearly-container']` | Blob containers where SQL dumps are copied. Entries map by position to `automationSchedules`; repeat a name to send multiple schedules to the same container. |
| `scriptLocation` | string | No | Linked template URI | Base URI used to locate `runbook/backupmysql.ps1`. Override it when the template is not deployed from the linked ARM template. |
| `enableAvmTelemetry` | bool | No | `true` | Enables telemetry for the Azure Verified Modules used by the deployment. |
| `tags` | object | No | `null` | Tags applied to deployed resources. |
| `fileSharePrivateDnsZoneResourceId` | string | Yes | - | Resource ID of the existing `privatelink.file.core.windows.net` private DNS zone. The zone must be linked to the container virtual network. |
| `blobPrivateDnsZoneResourceId` | string | Yes | - | Resource ID of the existing `privatelink.blob.core.windows.net` private DNS zone. The zone must be linked to the container virtual network. |
| `privateEndpointSubnetResourceId` | string | Yes | - | Resource ID of the subnet where the storage account private endpoints are created. |
| `containerInstanceSubnetResourceId` | string | Yes | - | Resource ID of the subnet used by the container group. It must be delegated to `Microsoft.ContainerInstance/containerGroups`. |
| `mySqlUsername` | string | No | `sqladmin` | MySQL account used by `mysqldump`. |
| `mySqlPassword` | secure string | Yes | - | Password for the MySQL account. It is stored as an encrypted Automation credential. |
| `databaseNamesForBackup` | array | No | `['redcapdb']` | Names of the databases included in each dump. |
| `databaseHostName` | string | Yes | - | Fully qualified hostname of the Azure Database for MySQL server. |
| `scheduleTimeZone` | string | No | `America/New_York` | IANA time-zone identifier used by the default schedules. Can also be referenced by custom schedule definitions. |
| `automationSchedules` | array of objects | No | Weekly, monthly, and yearly schedules | Azure Automation schedule definitions. Each object can customize the schedule name, description, frequency, interval, start time, time zone, and advanced schedule settings. |

## Backup schedules and destinations

By default, the template creates three schedules:

- `WeeklyBackupSchedule` runs every Sunday.
- `MonthlyBackupSchedule` runs on the first Sunday of every month.
- `YearlyBackupSchedule` runs every 12 months beginning January 1, 2027.

Use `scheduleTimeZone` to change the time zone used by the default schedules. For full control, replace `automationSchedules` with Azure Automation schedule objects that specify properties such as `frequency`, `interval`, `startTime`, `timeZone`, and `advancedSchedule`.

Each entry in `automationSchedules` is paired with the entry at the same array position in `backupBlobContainerNames`. The two arrays must therefore contain the same number of entries. This mapping makes it possible to use separate containers for different retention classes—for example, weekly, monthly, and yearly backups—or to route multiple schedules to one container by repeating its name.

Azure Files and Blob Storage retain backups until they are deleted manually or by a retention process that you configure separately. The template enables a seven-day soft-delete retention period for the file share, but it does not automatically expire individual backup files. Configure Blob Storage lifecycle-management rules separately if each schedule or container requires a different retention period.

Runbook job output includes the container status and logs for troubleshooting. The generated container group is named `mysqldumpci1` in the deployment resource group.

## Build the image locally

The deployed ACR task builds the image from the repository automatically. To build it locally instead, run:

```powershell
docker build -t azure-mysql-ltr/mysql-ltr-dump:latest .
```
