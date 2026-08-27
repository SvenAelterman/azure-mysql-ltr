param automationAccountName string
param containerInstanceSubnetResourceId string
param scriptLocation string
param location string
param scheduleStartDate string
param scheduleStartTimeUtc string
param uamiClientId string
param databaseHostName string
param databaseNamesForBackup array
param storageAccountName string
param backupFileShareName string
param backupBlobContainerName string
param containerRegistryLoginServer string
param uamiResourceId string
param enableAvmTelemetry bool
param tags object?
param acrName string

@secure()
param mySqlUsername string
@secure()
param mySqlPassword string

var runBookName = 'BackupMySqlDatabase'
var scheduleName = 'WeeklyOnSundaySchedule'

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
}

module automationAccountModule 'br/public:avm/res/automation/automation-account:0.19.2' = {
  name: 'automationAccountModule'
  params: {
    name: automationAccountName
    location: location
    skuName: 'Basic'

    credentials: [
      {
        name: 'ContainerRegistryCredential'
        userName: acr.listCredentials().username
        password: acr.listCredentials().passwords[0].value
        description: 'Credential for Container Registry access for Container Instance'
      }
      {
        name: 'MySqlCredential'
        userName: mySqlUsername
        password: mySqlPassword
        description: 'Credential for MySQL database access'
      }
    ]

    // runbooks: [
    //   {
    //     name: runBookName
    //     description: 'Runbook to backup MySQL database to Azure Storage for long-term retention. See https://techcommunity.microsoft.com/blog/adformysql/azure-database-for-mysql-extending-long-term-retention-by-using-containers/3065164'
    //     type: 'PowerShell72'
    //     uri: uri(scriptLocation, 'runbook/backupmysql.ps1')
    //     version: '1.0.0.0'
    //   }
    // ]

    schedules: [
      {
        name: scheduleName
        description: 'Schedule to run every week at 2 AM UTC.'
        frequency: 'Week'
        interval: 1
        startTime: '${scheduleStartDate}T${scheduleStartTimeUtc}'
        timeZone: 'America/New_York'
        advancedSchedule: {
          weekDays: ['Sunday']
        }
      }
    ]

    // jobSchedules: [
    //   {
    //     description: 'Schedule to run the ${runBookName} runbook based on the ${scheduleName} schedule.'
    //     runbookName: runBookName
    //     scheduleName: scheduleName

    //     parameters: {
    //       ManagedIdentityClientId: uamiClientId
    //       ManagedIdentityResourceId: uamiResourceId
    //       ContainerResourceGroupName: resourceGroup().name
    //       DatabaseHostName: databaseHostName
    //       DatabaseNames: join(databaseNamesForBackup, ' ')
    //       StorageAccountName: storageAccountName
    //       BackupFileShareName: backupFileShareName
    //       BackupBlobContainerName: backupBlobContainerName
    //       ContainerInstanceSubnetResourceId: containerInstanceSubnetResourceId
    //       ContainerRegistryUrl: containerRegistryLoginServer
    //       Location: location
    //     }
    //   }
    // ]

    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: [
        uamiResourceId
      ]
    }

    enableTelemetry: enableAvmTelemetry
    tags: tags
  }
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
  dependsOn: [
    automationAccountModule
  ]
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  name: 'PowerShell-76-Custom'
  parent: automationAccount
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.6'
    }
    defaultPackages: {
      az: '15.1.0'
      'azure cli': '2.77.0'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: runBookName
  parent: automationAccount
  location: location
  properties: {
    description: 'Runbook to backup MySQL database to Azure Storage for long-term retention. See https://techcommunity.microsoft.com/blog/adformysql/azure-database-for-mysql-extending-long-term-retention-by-using-containers/3065164'
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnvironment.name
    logVerbose: true
    logProgress: true
    publishContentLink: {
      uri: uri(scriptLocation, 'runbook/backupmysql.ps1')
      version: '1.0.0.0'
    }
  }
}

resource jobSchedules 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = {
  name: guid(automationAccountName, runBookName, scheduleName)
  parent: automationAccount
  properties: {
    schedule: {
      name: scheduleName
    }
    runbook: {
      name: runbook.name
    }
    parameters: {
      ManagedIdentityClientId: uamiClientId
      ManagedIdentityResourceId: uamiResourceId
      ContainerResourceGroupName: resourceGroup().name
      DatabaseHostName: databaseHostName
      DatabaseNames: join(databaseNamesForBackup, ' ')
      StorageAccountName: storageAccountName
      BackupFileShareName: backupFileShareName
      BackupBlobContainerName: backupBlobContainerName
      ContainerInstanceSubnetResourceId: containerInstanceSubnetResourceId
      ContainerRegistryUrl: containerRegistryLoginServer
      Location: location
    }
  }
}
