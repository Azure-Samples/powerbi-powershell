#This sample script calls the Power BI API and ARM REST API to programmatically scale capacity resource with no downtime (i.e. embedded content is available during the scaling process).
# It also provides an option to reassign workspaces from one capacity resource to another.
# The procedure creates a temporary capacity resource and reassigns the workspaces to it during the scaling process.
# Once the procedure is completed, the workspaces are assigned back to the original capacity resource and the temporary capacity resource is deleted.
#
#
#                                                             MAIN		    TEMP
#                                                          ==========            ==========
#                                                         |  SKU-X   |          | TEMPORARY|          
#       STEP 1 - Create temporary capacity                |          |		| CAPACITY |
#                                                     	  |WORKSPACES|          | 	   |	
#                                                          ==========            ==========
#                                                                           
#                                                          ==========            ==========
#                                                         |          |          | TEMPORARY|
#       STEP 2 - Reassign workspaces to temporary capacity|  SKU-X   |--------->| CAPACITY,| 
#                                                         |          |          |WORKSPACES|
#                                                          ==========            ==========
#
#                                                          ==========            ==========
#                                                         |          |          | TEMPORARY|
#       STEP 3 - Scale main capacity                      | SCALING  |          | CAPACITY,|
#                                                         |          |          |WORKSPACES|
#                                                          ==========            ==========
#                                                                           
#                                                          ==========            ==========
#                                                         |  SKU-Y   |          | TEMPORARY|         
#       STEP 4 - Assign workspaces back to main capacity  |  	     |<---------| CAPACITY |
#                                                         |WORKSPACES|          | 	   |
#                                                          ==========            ==========
#                                                             
#                                                          ==========            ==========
#                                                         |  SKU-Y   |          |          |
#       STEP 5 - Delete temporary capacity                |          |          |  DELETED |
#                                                         |WORKSPACES|          |          |
#                                                          ==========            ==========

# For more information, see the accompanying blog post:
# TODO : Add link to blog

# Instructions:
# 1. Install PowerShell (https://msdn.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell), and the Azure PowerShell cmdlets (Install-Module AzureRM)
# 2. Run PowerShell as an administrator
# 3. Follow the instructions below to fill in the client ID
# 4. Change PowerShell directory to where this script is saved 
# 5. Run Login-AzureRmAccount (In order to be able to run the script, the user should have an Azure RBAC 'owner' role, or any other Azure RBAC role with write permissions on the resource)
# 6. Run the script with params 

#   Scale Up example:
#   .\Zero-Downtime-Capacity-Scale.ps1 -CapacityName 'democap1' -CapacityResourceGroup 'demorg' -TargetSku A3
#
#   Workspaces Migration example: 
#   .\Zero-Downtime-Capacity-Scale.ps1 -CapacityName 'democap1' -CapacityResourceGroup 'demorg' -AssignWorkspacesOnly $true -SourceCapacityName 'democap2' -SourceCapacityResourceGroup 'demorg'

# Parameters - fill these in before running the script!
# ======================================================

# AAD Client ID:
# To get this, go to the following page and follow the steps to register an app
# https://app.powerbi.com/embedsetup/AppOwnsData
# To get the sample to work, ensure that you have the following fields:
# App Type: Native app
# Redirect URL: urn:ietf:wg:oauth:2.0:oob
# Level of access: check all boxes

[CmdletBinding()]
Param(
   [Parameter(Mandatory=$TRUE, HelpMessage="Name of capacity for scaling or target for workspaces migration.")]
   [string]$CapacityName,
   
   [Parameter(Mandatory=$TRUE, HelpMessage="ResourceGroup of capacity for scaling or target for workspaces migration")]
   [string]$CapacityResourceGroup,

   [Parameter(Mandatory=$False, HelpMessage="True if you want to assign all workspaces from srouce capacity only, provide SourceCapacityName and SourceCapacityResourceGroup params")]
   [bool]$AssignWorkspacesOnly = $FALSE,
   
   [Parameter(Mandatory=$FALSE, HelpMessage="Target SKU for scaling, e.g. A3")]
   [string]$TargetSku,
   
   [Parameter(Mandatory=$False, HelpMessage="Name of source capacity for workspaces migration.")]
   [string]$SourceCapacityName,
   
   [Parameter(Mandatory=$False, HelpMessage="ResourceGroup of source capacity for workspaces migration.")]
   [string]$SourceCapacityResourceGroup,

   [Parameter(Mandatory=$False, HelpMessage="User Name")]
   [string]$username,
   
   [Parameter(Mandatory=$False, HelpMessage="Password")]
   [string]$Password

)

# =====================================================
# $clientId = "FILL ME IN"
$clientId = "3101a374-7392-4667-b202-76383a02a872"
# =====================================================


$apiUri = "https://api.powerbi.com/v1.0/myorg/"

# =====================================================
# Get authentication token for PowerBI API 
FUNCTION GetAuthToken
{
    Import-Module AzureRm

    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"

    $resourceAppIdURI = "https://analysis.windows.net/powerbi/api"

    $authority = "https://login.microsoftonline.com/common/oauth2/authorize";

    $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority
    
    IF ($username -ne "" -and $Password -ne "")
    {
        $creds = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential" -ArgumentList $Username,$Password
        $authResult = $authContext.AcquireToken($resourceAppIdURI, $clientId, $creds)
    }
    ELSE
    {
        $authResult = $authContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, 'Always')
    }

    return $authResult
}

$token = GetAuthToken

# =====================================================
# Building Rest API header with authorization token
$auth_header = @{
   'Content-Type'='application/json'
   'Authorization'=$token.CreateAuthorizationHeader()
}

# =====================================================
# Helper function used for gettting the capacity object ID by capacity Name
FUNCTION GetCapacityObjectID($capacitiesList, $capacity_name) 
{
    $done = $False 
    
    # loop over capacitis list and find the right capacity by name
    $capacitiesList.value | ForEach-Object -Process {
        # Find main capacity ID
        if ($_.DisplayName -eq $capacity_name)
        {
            Write-Host ">>> Object ID for" $capacity_name  "is" $_.id
            $done = $True
            return $_.id
        }
    }

    # If capacity was not found then print error and exit
    IF ($done -ne $True) {
        $errmsg = "Capacity " + $capacity_name + " object ID was not found!"
        Write-Error $errmsg
        Break Script
    }
}

# =====================================================
# Helper function used for assigning workspaces from source to target capacity
FUNCTION AssignWorkspacesToCapacity($source_capacity_objectid, $target_capacity_objectid)
{
    $getCapacityGroupsUri = $apiUri + "groups?$" + "filter=capacityId eq " + "'$source_capacity_objectid'"
    $capacityWorkspaces = Invoke-RestMethod -Method GET -Headers $auth_header -Uri $getCapacityGroupsUri

    # Assign workspaces to temporary capacity
    $capacityWorkspaces.value | ForEach-Object -Process {          
      Write-Host ">>> Assigning workspace Name:" $_.name " Id:" $_.id "to capacity id:" $target_capacity_objectid
      $assignToCapacityUri = $apiUri + "groups/" + $_.id + "/AssignToCapacity"
      $assignToCapacityBody = @{capacityId=$target_capacity_objectid} | ConvertTo-Json
      Invoke-RestMethod -Method Post -Headers $auth_header -Uri $assignToCapacityUri -Body $assignToCapacityBody -ContentType 'application/json'
    }

    $getCapacityGroupsUri = $apiUri + "groups?$" + "filter=capacityId eq " + "'$target_capacity_objectid'"
    $capacityWorkspaces = Invoke-RestMethod -Method GET -Headers $auth_header -Uri $getCapacityGroupsUri

    return $capacityWorkspaces
}

# =====================================================
# Helper function used for validation capacity in Active state
FUNCTION ValidateCapacityInActiveState($capacity_name, $resource_group)
{
    # Get capacity and validate its in active state
    $getCapacityResult = Get-AzureRmPowerBIEmbeddedCapacity -Name $capacity_name -ResourceGroup $resource_group

    IF (!$getCapacityResult -OR $getCapacityResult -eq "")
    {
        $errmsg = "Capacity " + $capacity_name +" was not found!"
        Write-Error -Message $errmsg
        Break Script
    }
    ELSEIF ($getCapacityResult.State.ToString() -ne "Succeeded") 
    {
        $errmsg = "Capacity " + $capacity_name + " is not in active state!"
        Write-Error $errmsg
        Break Script
    }

    return $getCapacityResult
}

# Start watch to measure E2E time duration
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Get and Validate main capacity is in active state
$mainCapacity = ValidateCapacityInActiveState $CapacityName $CapacityResourceGroup

# Check if script execution is for assigning workspaces only
IF ($AssignWorkspacesOnly -ne $TRUE)
{
    # Check if user is a capacity administrator, if not exist script
    $context = Get-AzureRmContext
    $isUserAdminOnCapacity = $False
    $mainCapacity.Administrator | ForEach-Object -Process {
      IF ($_ -eq $context.Account.Id)
      {
        $isUserAdminOnCapacity = $TRUE
      } 
    }

    IF ($isUserAdminOnCapacity -eq $False)
    {
        $errmsg = "User is not capacity administrator!"
        Write-Error $errmsg
        Break Script 
    }

    # Check if Current SKU is equal to main SKU
    IF ($mainCapacity.Sku -eq $TargetSku)
    { 
      Write-Host "Current SKU is equal to the target SKU, No scale is needed!"
      Break Script
    }        

    Write-Host
    Write-Host "========================================================================================================================" -ForegroundColor DarkGreen
    Write-Host "                                           SCALING CAPACITY FROM" $mainCapacity.Sku "To" $TargetSku -ForegroundColor DarkGreen
    Write-Host "========================================================================================================================" -ForegroundColor DarkGreen
    Write-Host 
    Write-Host ">>> Capacity" $CapacityName "is available and ready for scaling!"

    # Create new temporary capacity to be used for scale
    $guid = New-Guid
    $temporaryCapacityName = 'tmpcapacity' + $guid.ToString().Replace('-','s').ToLowerInvariant()
    $temporarycapacityResourceGroup = $mainCapacity.ResourceGroup
    
    Write-Host
    Write-Host ">>> STEP 1 - Creating a temporary capacity name:"$temporaryCapacityName
    $newcap = New-AzureRmPowerBIEmbeddedCapacity -ResourceGroupName $mainCapacity.ResourceGroup -Name $temporaryCapacityName -Location $mainCapacity.Location -Sku $TargetSku -Administrator $mainCapacity.Administrator
  
    # Check if new capacity provisioning succeeded
    IF (!$newcap -OR $newcap.State.ToString() -ne 'Succeeded') 
    {
        Remove-AzureRmPowerBIEmbeddedCapacity -Name $temporaryCapacityName -ResourceGroupName $temporarycapacityResourceGroup    
        $errmsg = "Try to remove temporary capacity due to some failure while provisioning!, Please restart script!"
        Write-Error -Message $errmsg	
        Break Script
    }

    # Get capacities from PowerBI to find the capacities ID
    $getCapacityUri = $apiUri + "capacities"
    $capacitiesList = Invoke-RestMethod -Method Get -Headers $auth_header -Uri $getCapacityUri
    $sourceCapacityObjectId = GetCapacityObjectID $capacitiesList $CapacityName
    $targetCapacityObjectId = GetCapacityObjectID $capacitiesList $temporaryCapacityName
    Write-Host ">>> STEP 1 - Completed!"

    Write-Host
    Write-Host ">>> STEP 2 - Assigning workspaces"
    $assignedMainCapacityWorkspaces = AssignWorkspacesToCapacity $sourceCapacityObjectId $targetCapacityObjectId
    Write-Host ">>> STEP 2 Completed!"

    Write-Host
    Write-Host ">>> STEP 3 - Scaling capacity " $CapacityName "to" $targetSku
    Update-AzureRmPowerBIEmbeddedCapacity -Name $CapacityName -sku $targetSku        
    $mainCapacity = ValidateCapacityInActiveState $CapacityName $CapacityResourceGroup
    Write-Host ">>> STEP 3 completed!" $CapacityName "to" $targetSku

    Write-Host
    Write-Host ">>> STEP 4 - Assigning workspaces to main capacity"
    $AssignedTargetCapacityWorkspaces = AssignWorkspacesToCapacity $targetCapacityObjectId $sourceCapacityObjectId
    
    # validate all workspaces were assigned back to the main capacity
    $diff =  Compare-Object $AssignedTargetCapacityWorkspaces.value $assignedMainCapacityWorkspaces.value
    if ($diff -ne $null)
    {  
        $errmsg = "Something went wrong while assigning workspaces to the main capacity, Please re-execute the script"
        Write-Error -Message $errmsg
        Break Script
    }
    Write-Host ">>> STEP 4 Completed!"

    Write-Host
    Write-Host ">>> STEP 5 - Delete temporary capacity"
    # Delete temporary capacity if it was newly created
    Remove-AzureRmPowerBIEmbeddedCapacity -Name $temporaryCapacityName -ResourceGroupName $temporarycapacityResourceGroup
    Write-Host ">>> STEP 5 Completed!"
}
ELSE
{
    # Get capacities from PowerBI to find the capacities ID
    $getCapacityUri = $apiUri + "capacities"
    $capacitiesList = Invoke-RestMethod -Method Get -Headers $auth_header -Uri $getCapacityUri
 
    ValidateCapacityInActiveState $CapacityName $CapacityResourceGroup
    Write-Host ">>> Capacity" $CapacityName "is available and ready!"
    $sourceCapacityObjectId = GetCapacityObjectID $capacitiesList $SourceCapacityName

    ValidateCapacityInActiveState $SourceCapacityName $SourceCapacityResourceGroup
    $targetCapacityObjectId = GetCapacityObjectID $capacitiesList $CapacityName
    Write-Host ">>> Capacity" $SourceCapacityName "is available and ready!"

    $assignedcapacities = AssignWorkspacesToCapacity $sourceCapacityObjectId $targetCapacityObjectId
}

Write-Host
Write-Host "========================================================================================================================" -ForegroundColor DarkGreen
Write-Host "                                           Completed Successfully" -ForegroundColor DarkGreen
Write-Host "                                              Total Duration" -ForegroundColor DarkGreen
Write-Host "                                            "$stopwatch.Elapsed -ForegroundColor DarkGreen
Write-Host "========================================================================================================================" -ForegroundColor DarkGreen
