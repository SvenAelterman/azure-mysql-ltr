Param(
    [Parameter(Mandatory = $true)]
    [string] $ManagedIdentityClientId,
    [Parameter(Mandatory = $true)]
    [string] $ManagedIdentityResourceId,
    [Parameter(Mandatory = $true)]
    [string] $ContainerResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string] $DatabaseHostName,
    [Parameter(Mandatory = $true)]
    [string] $DatabaseNames,
    [Parameter(Mandatory = $true)]
    [string] $StorageAccountName,
    [Parameter(Mandatory = $true)]
    [string] $BackupFileShareName,
    [Parameter(Mandatory = $true)]
    [string] $BackupBlobContainerName,
    [Parameter(Mandatory = $true)]
    [string] $ContainerInstanceSubnetResourceId,
    [Parameter(Mandatory = $true)]
    [string] $ContainerRegistryUrl,
    [Parameter(Mandatory = $true)]
    [string] $Location,
    [Parameter()]
    [string] $BackupFileNamePrefix = 'dumps-',
    [Parameter()]
    [int] $ContainerCpuCores = 1,
    [Parameter()]
    [double] $ContainerMemoryInGb = 1.5
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

$ErrorActionPreference = "Stop"

# Connect to Azure with the specified user-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

Write-Output "Successfully connected with Automation account's Managed Identity"

[string]$ContainerName = 'mysqldumpci1'

$MySQLCredential = Get-AutomationPSCredential -Name "MySQLCredential"
[string]$MySQLUsername = $MySQLCredential.UserName
[securestring]$MySQLPassword = ConvertTo-SecureString ($MySQLCredential.GetNetworkCredential().Password) -AsPlainText -Force

Write-Output "Retrieved MySQL credential"

# Construct the container entry command
[string]$BackupJobTimeStamp = Get-Date -Format "yyyyMMddhhmmss"
# LATER: Allow customizing file name prefix
[string]$filename = "--result-file=/data/backups/" + $BackupFileNamePrefix + $BackupJobTimeStamp + ".sql"
[string]$HostName = "--host=$DatabaseHostName"
[string]$user = "--user=$MySQLUsername"
# Do not interpret $MYSQL_PASSWORD here, it's an env var inside the container
[string]$sqlPassword = '--password=${{MYSQL_PASSWORD}}'

[string[]]$DatabaseNamesArray = $DatabaseNames.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)

[string[]]$cmd = "/usr/local/bin/backup-and-upload.sh", "--opt", "--single-transaction", $HostName, $user, $sqlPassword, $filename, "--databases"

# Add each database name as a separate entry to the container command
foreach ($DatabaseName in $DatabaseNamesArray) {
    $cmd += $DatabaseName
}

# Get storage account access key
[securestring]$StorageAccountKey = ConvertTo-SecureString ((Get-AzStorageAccountKey -ResourceGroupName $ContainerResourceGroupName -AccountName $StorageAccountName) `
    | Where-object { $_.KeyName -eq "Key1" }).Value -AsPlainText -Force

# Create mount object as backup volume in container
$VolumeMount = New-AzContainerInstanceVolumeMountObject -Name "backups" -MountPath "/data/backups/" -ReadOnly $false
# Create a new volume on the mount object from the Azure File share
$Volume = New-AzContainerGroupVolumeObject -Name "backups" -AzureFileShareName $BackupFileShareName `
    -AzureFileStorageAccountName $StorageAccountName `
    -AzureFileStorageAccountKey $StorageAccountKey 

$ContainerRegistryCredential = Get-AutomationPSCredential -Name "ContainerRegistryCredential"
$ContainerRegistryUsername = $ContainerRegistryCredential.UserName
$ContainerRegistryPassword = ConvertTo-SecureString ($ContainerRegistryCredential.GetNetworkCredential().Password) -AsPlainText -Force
$ImageRegistryCredential = New-AzContainerGroupImageRegistryCredentialObject -Server $ContainerRegistryUrl -Username $ContainerRegistryUsername -Password $ContainerRegistryPassword

$EnvironmentVariables = @(
    (New-AzContainerInstanceEnvironmentVariableObject -Name "STORAGE_ACCOUNT_NAME" -Value $StorageAccountName),
    (New-AzContainerInstanceEnvironmentVariableObject -Name "BLOB_CONTAINER_NAME" -Value $BackupBlobContainerName),
    # Log folder does not need to exist yet
    (New-AzContainerInstanceEnvironmentVariableObject -Name "AZCOPY_LOG_LOCATION" -Value "/data/backups/azcopy-logs"),
    (New-AzContainerInstanceEnvironmentVariableObject -Name "AZCOPY_AUTO_LOGIN_TYPE" -Value "MSI"),
    (New-AzContainerInstanceEnvironmentVariableObject -Name "AZCOPY_MSI_CLIENT_ID" -Value $ManagedIdentityClientId),
    (New-AzContainerInstanceEnvironmentVariableObject -Name "MYSQL_PASSWORD" -SecureValue $MySQLPassword)
)

# Create the container instance object
$Container = New-AzContainerInstanceObject -Name $ContainerName -Image "$ContainerRegistryUrl/azure-mysql-ltr/mysql-ltr-dump:latest" -VolumeMount $VolumeMount `
    -Command $cmd -EnvironmentVariable $EnvironmentVariables `
    -RequestCpu $ContainerCpuCores -RequestMemoryInGb $ContainerMemoryInGb

$SubnetId = @{
    Id   = $ContainerInstanceSubnetResourceId
    Name = "ContainerSubnet"   
}

$ContainerGroupIdentity = @{}
$ContainerGroupIdentity[$ManagedIdentityResourceId] = @{}

try {
    # Deploy the container in a container group
    Write-Output "Creating container..."
    $ContainerGroup = New-AzContainerGroup -ResourceGroupName $ContainerResourceGroupName -Name $ContainerName `
        -Location $Location -Container $Container -Volume $Volume `
        -RestartPolicy Never -OSType Linux -SubnetId $SubnetId `
        -ImageRegistryCredential $ImageRegistryCredential `
        -IdentityType "UserAssigned" -IdentityUserAssignedIdentity $ContainerGroupIdentity

    while ($true) {
        $Status = (Get-AzContainerGroup -Name $ContainerName -ResourceGroupName $ContainerResourceGroupName | Select-Object -Property @{Name = "Status"; Expression = { $_.InstanceViewState } }).Status

        if ($Status -eq "Failed") {
            Write-Error "Container in Failed State. Please check the logs below."
            Break
        }
        elseif ($Status -eq "Stopped" -or $Status -eq "Succeeded") {
            Write-Output "Container execution complete. Please check the logs below."
            Break
        }
        else {
            Write-Output $Status
            Start-Sleep -Seconds 30
        }
    }
}
catch {
    Write-Error "Message: $($_.Exception.Message)"
    Write-Error "Type: $($_.Exception.GetType().FullName)"
    Write-Error "Invocation: $($_.InvocationInfo.Line)"
    Write-Error "ScriptLineNumber: $($_.InvocationInfo.ScriptLineNumber)"
    Write-Error "Position: $($_.InvocationInfo.PositionMessage)"
    Write-Error "ScriptStackTrace:`n$($_.ScriptStackTrace)"

    throw
}
finally {
    [string]$separator = '=' * 80
    Write-Output "Fetching container logs..."
    Write-Output $separator
    Get-AzContainerInstanceLog -ContainerGroupName $ContainerGroup.Name -ContainerName $ContainerName -ResourceGroupName $ContainerResourceGroupName | Write-Output
    Write-Output $separator

    # Stop container after backup
    Write-Output "Stopping container..."
    Stop-AzContainerGroup -Name $ContainerGroup.Name -ResourceGroupName $ContainerResourceGroupName
}