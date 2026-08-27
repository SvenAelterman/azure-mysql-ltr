# Azure Database for MySQL long-term retention

This repository automates logical backups of Azure Database for MySQL databases for long-term retention. An Azure Automation runbook starts an Azure Container Instance that runs `mysqldump`, writes the resulting SQL dump to an Azure Files share, and copies it to Azure Blob Storage.

## Architecture

The Bicep template deploys and configures:

- An Azure Automation account with a PowerShell 7.2 runbook and weekly schedule
- A user-assigned managed identity and the role assignments needed by the runbook
- A geo-redundant storage account, Azure Files share, blob container, and private endpoints
- An Azure Container Registry and ACR task that builds the image from this repository
- Automation credentials for MySQL and the container registry

At the scheduled time, the runbook creates a container group in the supplied delegated subnet. The container mounts the file share, runs `mysqldump` for the configured databases, copies the generated dump to the blob container with `azcopy` and the user-assigned managed identity, and stops after the backup completes. Backup files are named `dumps-<timestamp>.sql`.

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
| `backupBlobContainerName` | string | No | `backup-blob-container` | Name of the blob container where SQL dumps are copied. |
| `scriptLocation` | string | No | Linked template URI | Base URI used to locate `runbook/backupmysql.ps1`. Override it when the template is not deployed from the linked ARM template. |
| `enableAvmTelemetry` | bool | No | `true` | Enables telemetry for the Azure Verified Modules used by the deployment. |
| `tags` | object | No | `null` | Tags applied to deployed resources. |
| `fileSharePrivateDnsZoneResourceId` | string | Yes | - | Resource ID of the existing `privatelink.file.core.windows.net` private DNS zone. The zone must be linked to the container virtual network. |
| `blobPrivateDnsZoneResourceId` | string | Yes | - | Resource ID of the existing `privatelink.blob.core.windows.net` private DNS zone. The zone must be linked to the container virtual network. |
| `privateEndpointSubnetResourceId` | string | Yes | - | Resource ID of the subnet where the storage account private endpoints are created. |
| `containerInstanceSubnetResourceId` | string | Yes | - | Resource ID of the subnet used by the container group. It must be delegated to `Microsoft.ContainerInstance/containerGroups`. |
| `mySqlUsername` | string | No | `sqladmin` | MySQL account used by `mysqldump`. |
| `mySqlPassword` | secure string | Yes | - | Password for the MySQL account. It is stored as an encrypted Automation credential. |
| `scheduleStartDate` | string | No | Tomorrow (`yyyy-MM-dd`) | Date on which the weekly backup schedule starts. |
| `scheduleStartTimeUtc` | string | No | `06:00:00` | Start time passed to the Automation schedule. The schedule is configured with the `America/New_York` time zone. |
| `databaseNamesForBackup` | array | No | `['redcapdb']` | Names of the databases included in each dump. |
| `databaseHostName` | string | Yes | - | Fully qualified hostname of the Azure Database for MySQL server. |

## Backup schedule and retention

The template schedules the runbook weekly on Sunday. Azure Files and Blob Storage store the backup until it is deleted manually or by a retention process that you configure separately. The template enables a seven-day soft-delete retention period for the file share, but it does not automatically expire individual backup files.

Runbook job output includes the container status and logs for troubleshooting. The generated container group is named `mysqldumpci1` in the deployment resource group.

## Build the image locally

The deployed ACR task builds the image from the repository automatically. To build it locally instead, run:

```powershell
docker build -t azure-mysql-ltr/mysql-ltr-dump:latest .
```
