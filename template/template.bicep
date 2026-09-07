// Naming conventions
@description('The naming convention structure for all resources names, unless overridden. May contain the following placeholders: {workloadName}, {env}, {rtype}, {loc}, {seq}.')
param namingConvention string = '{workloadName}-{env}-{rtype}-{loc}-{seq}'
@description('The workload name to use in resource names. Defaults to "mysqlltr".')
param workloadName string = 'mysqlltr'
@description('The environment name to use in resource names. Defaults to "prod".')
param environment string = 'prod'
@description('The sequence number to use for resource names. Defaults to 1.')
param sequence int = 1

@description('The Azure region where all resources should be deployed. Defaults to the resource group location.')
param location string = resourceGroup().location
@description('The name of the file share to be created in the storage account for storing the backups.')
@minLength(3)
@maxLength(63)
param backupFileShareName string = 'backup-file-share'
@description('The names of the blob container to be created in the storage account for storing backup copies. Specify one container per schedule, in the same order. You can use the same container for multiple schedules by repeating the name.')
param backupBlobContainerNames string[] = [
  'backup-weekly-container'
  'backup-monthly-container'
  'backup-yearly-container'
]
@description('The URI of the PowerShell script file that is the runbook code.')
param scriptLocation string = deployment().properties.templateLink.uri

@description('If true, telemetry from the Azure Verified Modules will be sent.')
param enableAvmTelemetry bool = true
@description('Optional. Tags will be applied to all resources.')
param tags object?

@description('The private DNS zone must already be linked to the virtual network where the Container Instance will be deployed.')
param fileSharePrivateDnsZoneResourceId string
@description('The blob private DNS zone must already be linked to the virtual network where the Container Instance will be deployed.')
param blobPrivateDnsZoneResourceId string
@description('The subnet resource ID where the private endpoints.')
param privateEndpointSubnetResourceId string
@description('The subnet resource ID where the container instance will be deployed. Must be delegated to *Microsoft.ContainerInstance/containerGroups*.')
param containerInstanceSubnetResourceId string

@description('The URL of the Docker context for the container build task. Defaults to the GitHub repository for this project.')
param containerTaskDockerContextPath string = 'https://github.com/SvenAelterman/azure-mysql-ltr'

@description('The username for the MySQL server. Defaults to "sqladmin".')
param mySqlUsername string = 'sqladmin'
@description('The password for the MySQL server.')
@secure()
param mySqlPassword string

@description('The names of the databases to be backed up. Defaults to ["redcapdb"].')
param databaseNamesForBackup array = ['redcapdb']
@description('The hostname of the MySQL server to be backed up.')
param databaseHostName string

@description('The name of the time zone (IANA TZ identifier) used for the schedule. Defaults to "America/New_York".')
param scheduleTimeZone string = 'America/New_York'

@description('The schedules to create in the Automation Account. The runbook will be executed according to each schedule.')
param automationSchedules object[] = [
  {
    name: 'WeeklyBackupSchedule'
    description: 'Schedule to run every week at 2 AM Eastern.'
    frequency: 'Week'
    interval: 1
    startTime: '${dateTimeAdd(utcNow(), 'P1D', 'yyyy-MM-dd')}T06:00:00' // 2 AM Eastern, tomorrow
    timeZone: scheduleTimeZone
    advancedSchedule: {
      weekDays: ['Sunday']
    }
  }
  {
    name: 'MonthlyBackupSchedule'
    description: 'Schedule to run every month on the first Sunday at 2 AM Eastern.'
    frequency: 'Month'
    // Every month
    interval: 1
    advancedSchedule: {
      monthlyOccurrence: {
        // First Sunday of the month
        dayOfWeek: 'Sunday'
        occurrence: 1
      }
    }
    startTime: '${dateTimeAdd(utcNow(), 'P1D', 'yyyy-MM-dd')}T06:00:00'
    timeZone: scheduleTimeZone
  }
  {
    name: 'YearlyBackupSchedule'
    description: 'Schedule to run every year on the first Sunday of January at 2 AM Eastern.'
    // Every 12 months equals yearly
    frequency: 'Month'
    interval: 12
    advancedSchedule: {
      monthDays: [1]
    }
    startTime: '2027-01-01T06:00:00'
    timeZone: scheduleTimeZone
  }
]

module userAssignedIdentityModule 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'userAssignedIdentityModule'
  params: {
    name: userAssignedIdentityNameModule.outputs.validName
    location: location

    enableTelemetry: enableAvmTelemetry
    tags: tags
  }
}

module automationAccountOuterModule './modules/automationAccount.bicep' = {
  name: 'automationAccountOuterModule'
  params: {
    automationAccountName: automationAccountNameModule.outputs.validName
    containerInstanceSubnetResourceId: containerInstanceSubnetResourceId
    scriptLocation: scriptLocation
    location: location
    uamiClientId: userAssignedIdentityModule.outputs.clientId
    uamiResourceId: userAssignedIdentityModule.outputs.resourceId
    databaseHostName: databaseHostName
    databaseNamesForBackup: databaseNamesForBackup
    storageAccountName: storageAccountModule.outputs.name
    backupFileShareName: backupFileShareName
    backupBlobContainerNames: backupBlobContainerNames
    mySqlUsername: mySqlUsername
    mySqlPassword: mySqlPassword
    acrName: containerRegistryModule.outputs.name
    enableAvmTelemetry: enableAvmTelemetry
    schedules: automationSchedules
    tags: tags
  }
}

module storageAccountModule 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'storageAccountModule'
  params: {
    name: storageAccountNameModule.outputs.validName
    location: location
    skuName: 'Standard_GRS'
    kind: 'StorageV2'

    supportsHttpsTrafficOnly: true
    // Required to support mounting container volume
    allowSharedKeyAccess: true

    fileServices: {
      shareDeleteRetentionPolicy: {
        enabled: true
        days: 7
      }
      shares: [
        {
          name: backupFileShareName
          accessTier: 'TransactionOptimized'
          shareQuota: 5120
          enabledProtocols: 'SMB'
        }
      ]
    }

    blobServices: {
      containers: [
        for backupBlobContainerName in backupBlobContainerNames: {
          name: backupBlobContainerName
          publicAccess: 'None'
        }
      ]
    }

    // Create private endpoints for the blob and file services
    privateEndpoints: [
      {
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: fileSharePrivateDnsZoneResourceId
            }
          ]
        }
        subnetResourceId: privateEndpointSubnetResourceId
        service: 'file'
        name: filePrivateEndpointNameModule.outputs.validName
        customNetworkInterfaceName: filePENicNameModule.outputs.validName
      }
      {
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: blobPrivateDnsZoneResourceId
            }
          ]
        }
        subnetResourceId: privateEndpointSubnetResourceId
        service: 'blob'
        name: blobPrivateEndpointNameModule.outputs.validName
        customNetworkInterfaceName: blobPENicNameModule.outputs.validName
      }
    ]

    roleAssignments: [
      {
        principalId: userAssignedIdentityModule.outputs.principalId
        // Required role to retrieve storage account keys for mounting the file share in the container instance
        roleDefinitionIdOrName: 'Storage Account Key Operator Service Role'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: userAssignedIdentityModule.outputs.principalId
        // Required role to allow the container to read from the mounted file share with managed identity
        roleDefinitionIdOrName: 'Storage File Data SMB Share Reader'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: userAssignedIdentityModule.outputs.principalId
        // Required role to allow azcopy to upload dumps to the blob container with managed identity
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: deployer().objectId
        // Assign registry-wide permissions
        roleDefinitionIdOrName: 'Storage File Data SMB Share Contributor'
        principalType: 'User'
      }
    ]

    enableTelemetry: enableAvmTelemetry
    tags: tags
  }
}

module containerRegistryModule 'br/public:avm/res/container-registry/registry:0.13.0' = {
  name: 'containerRegistryModule'
  params: {
    name: containerRegistryNameModule.outputs.validName
    location: location
    acrSku: 'Basic'

    // Required for Container Instance to pull the image
    acrAdminUserEnabled: true

    roleAssignmentMode: 'AbacRepositoryPermissions'

    networkRuleBypassAllowedForTasks: true

    roleAssignments: [
      {
        principalId: userAssignedIdentityModule.outputs.principalId
        roleDefinitionIdOrName: 'AcrPull'
        principalType: 'ServicePrincipal'
      }
      // The roles below need to be used because the support ABAC, though we're not using attributes
      // and allow access to all repositories in the registry.
      {
        principalId: userAssignedIdentityModule.outputs.principalId
        // Required role to allow the container instance to push the image to the ABAC-enabled registry
        roleDefinitionIdOrName: 'Container Registry Repository Writer'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: deployer().objectId
        // Assign registry-wide permissions
        roleDefinitionIdOrName: 'Container Registry Repository Contributor'
        principalType: 'User'
      }
      {
        principalId: deployer().objectId
        // Assign registry-wide permissions
        roleDefinitionIdOrName: 'Container Registry Repository Catalog Lister'
        principalType: 'User'
      }
    ]

    // Task to build the container image from the Dockerfile in this repo
    tasks: [
      {
        name: 'azure-mysql-ltr'
        platform: {
          os: 'Linux'
          architecture: 'amd64'
        }
        tags: tags
        status: 'Enabled'
        // disable-next-line required due to https://github.com/Azure/bicep-registry-modules/issues/7296
        #disable-next-line BCP037
        managedIdentities: {
          userAssignedResourceIds: [userAssignedIdentityModule.outputs.resourceId]
        }
        // disable-next-line required due to 
        #disable-next-line BCP037
        credentials: {
          // An ABAC-enabled registry requires credentials for the task to access the registry.
          // The user-assigned identity is used to authenticate to the registry.
          sourceRegistry: {
            loginMode: 'Default'
            identity: userAssignedIdentityModule.outputs.clientId
          }
        }
        step: {
          type: 'Docker'
          dockerFilePath: 'Dockerfile'
          imageNames: ['azure-mysql-ltr/mysql-ltr-dump:latest']
          isPushEnabled: true
          contextPath: containerTaskDockerContextPath
        }
      }
    ]

    enableTelemetry: enableAvmTelemetry
    tags: tags
  }
}

// Create role assignment on resource group for the
// user-assigned managed identity to be able to deploy the container instance
module resourceGroupRoleAssignmentModule 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.1' = {
  name: 'resourceGroupRoleAssignmentModule'
  params: {
    principalId: userAssignedIdentityModule.outputs.principalId
    roleDefinitionIdOrName: 'Contributor'
    principalType: 'ServicePrincipal'

    enableTelemetry: enableAvmTelemetry
  }
}

var splitSubnetId = split(containerInstanceSubnetResourceId, '/')
resource containerVirtualNetwork 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: splitSubnetId[8]
  scope: resourceGroup(splitSubnetId[2], splitSubnetId[4])
}

// Create role assignment on the virtual network for the 
// user-assigned managed identity to be able to deploy container groups
module vnetRoleAssignmentModule 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.2' = {
  name: 'vnetRoleAssignmentModule'
  scope: resourceGroup(splitSubnetId[2], splitSubnetId[4])
  params: {
    principalId: userAssignedIdentityModule.outputs.principalId
    roleDefinitionId: '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
    principalType: 'ServicePrincipal'
    resourceId: containerVirtualNetwork.id

    enableTelemetry: enableAvmTelemetry
  }
}

// Resource name generation
module storageAccountNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'storageAccountNameModule'
  params: {
    namingConvention: namingConvention
    addRandomChars: 4
    workloadName: workloadName
    environment: environment
    resourceType: 'st'
    location: location
    sequence: sequence
  }
}

module automationAccountNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'automationAccountNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'aa'
    location: location
    sequence: sequence
  }
}

module userAssignedIdentityNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'userAssignedIdentityNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'uami'
    location: location
    sequence: sequence
  }
}

module containerRegistryNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'containerRegistryNameModule'
  params: {
    namingConvention: namingConvention
    addRandomChars: 4
    workloadName: workloadName
    environment: environment
    resourceType: 'cr'
    location: location
    sequence: sequence
  }
}

module blobPrivateEndpointNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'blobPrivateEndpointNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'pe'
    resourceTypeReplacementOverride: 'pe-st-blob'
    location: location
    sequence: sequence
  }
}

module filePrivateEndpointNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'filePrivateEndpointNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'pe'
    resourceTypeReplacementOverride: 'pe-st-file'
    location: location
    sequence: sequence
  }
}

module blobPENicNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'blobPENicNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'nic'
    resourceTypeReplacementOverride: 'nic-pe-st-blob'
    location: location
    sequence: sequence
  }
}

module filePENicNameModule './modules/createValidAzResourceName.bicep' = {
  name: 'filePENicNameModule'
  params: {
    namingConvention: namingConvention
    workloadName: workloadName
    environment: environment
    resourceType: 'nic'
    resourceTypeReplacementOverride: 'nic-pe-st-file'
    location: location
    sequence: sequence
  }
}
