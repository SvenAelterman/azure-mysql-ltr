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
    [string] $Location
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

$ErrorActionPreference = "Stop"

# Connect to Azure with the specified user-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

Write-Output "Successfully connected with Automation account's Managed Identity"

$ContainerName = 'mysqldumpci1'

$MySQLCredential = Get-AutomationPSCredential -Name "MySQLCredential"
$MySQLUsername = $MySQLCredential.UserName
$MySQLPassword = $MySQLCredential.GetNetworkCredential().Password

$BackupJobTimeStamp = Get-Date -Format "yyyyMMddhhmmss"
$filename = "--result-file=/data/backups/dumps-" + $BackupJobTimeStamp + ".sql"
$h1 = "--host=" + $DatabaseHostName
$user = "--user=" + $MySQLUsername
$sqlPassword = "--password=" + $MySQLPassword
$dbnamearray = $DatabaseNames.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)

$cmd = "/usr/local/bin/backup-and-upload.sh", "--opt", "--single-transaction", $h1, $user, $sqlPassword, $filename, "--databases"

foreach ($names in $dbnamearray) {
    $cmd += $names
}

# Get storage account access key
$StorageAccountKey = ConvertTo-SecureString ((Get-AzStorageAccountKey -ResourceGroupName $ContainerResourceGroupName -AccountName $StorageAccountName) | Where-object { $_.KeyName -eq "Key1" }).Value -AsPlainText -Force
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
    (New-AzContainerInstanceEnvironmentVariableObject -Name "MANAGED_IDENTITY_CLIENT_ID" -Value $ManagedIdentityClientId)
)

# Create the container instance object
$Container = New-AzContainerInstanceObject -Name $ContainerName -Image "$ContainerRegistryUrl/azure-mysql-ltr/mysql-ltr-dump:latest" -VolumeMount $VolumeMount `
    -Command $cmd -EnvironmentVariable $EnvironmentVariables

$SubnetId = @{
    Id   = $ContainerInstanceSubnetResourceId
    Name = "ContainerSubnet"   
}

$ContainerGroupIdentity = @{}
$ContainerGroupIdentity[$ManagedIdentityResourceId] = @{}

# Deploy the container in a container group
Write-Output "Creating container..."
$ContainerGroup = New-AzContainerGroup -ResourceGroupName $ContainerResourceGroupName -Name $ContainerName -Location $Location -Container $Container -Volume $Volume `
    -RestartPolicy Never -OSType Linux -SubnetId $SubnetId `
    -ImageRegistryCredential $ImageRegistryCredential `
    -IdentityType UserAssigned -IdentityUserAssignedIdentity $ContainerGroupIdentity

while ($true) {
    $Status = (Get-AzContainerGroup -Name $ContainerName -ResourceGroupName $ContainerResourceGroupName | Select-Object -Property @{Name = "Status"; Expression = { $_.InstanceViewState } }).Status

    if ($Status -eq "Failed") {
        Write-Output "Container in Failed State. Please check the logs below."
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

Write-Output "Fetching container logs..."
Get-AzContainerInstanceLog -ContainerGroupName $ContainerGroup.Name -ContainerName $ContainerName -ResourceGroupName $ContainerResourceGroupName | Write-Output

# Stop container after backup
Write-Output "Stopping container..."
Stop-AzContainerGroup -Name $ContainerGroup.Name -ResourceGroupName $ContainerResourceGroupName
