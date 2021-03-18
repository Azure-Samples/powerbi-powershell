# Orignial Script https://github.com/Azure-Samples/powerbi-powershell/blob/master/Zero-Downtime-Capacity-Scale.ps1 migrated to use Az modules

# This runbook requires the following Powershell Modules:
# MicrosoftPowerBIMgmt.Profile
# Az.Accounts
# Az.PowerBIEmbedded

# This sample script calls the Power BI API and ARM REST API to programmatically scale capacity resource with no downtime (i.e. embedded content is available during the scaling process).
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
# 3. Follow the instructions below to fill in the client ID
#    Make sure the applicationId is the Administrator on Power BI Embeded and Workspace
#    This runbook is using the Azure Account Manged Identity as ApplicationId 
#    in case you would like to use a different Application Id comment out the line 69-72 and 235 and then comment the line 242
# Parameters - fill these in before running the script!
# ======================================================

# AAD Client ID:
# To get this, go to the following page and follow the steps to register an app
# https://app.powerbi.com/embedsetup/AppOwnsData
# To get the sample to work, ensure that you have the following fields:
# App Type: Native app
# Redirect URL: urn:ietf:wg:oauth:2.0:oob
# Level of access: check all boxes




Param
(
  # [Parameter (Mandatory= $false)] 
  #[String] $clientId = "FILL ME IN",
  # [Parameter (Mandatory= $false)]
  # [String] $secret = "FILL ME IN",
  [Parameter (Mandatory= $false)]
  [String] $CapacityName = "FILL ME IN",
  [Parameter (Mandatory= $false)]
  [String] $CapacityResourceGroup = "FILL ME IN",
  [Parameter (Mandatory= $false)]
  [String] $TargetSku = "A1"
  
  
)




# Start watch to measure E2E time duration
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()


# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave –Scope Process

$connection = Get-AutomationConnection -Name AzureRunAsConnection

# Wrap authentication in retry logic for transient network failures
$logonAttempt = 0
while(!($connectionResult) -and ($logonAttempt -le 2))
{
    $LogonAttempt++
    # Logging in to Azure...
    $connectionResult = Connect-AzAccount `
                            -ServicePrincipal `
                            -Tenant $connection.TenantID `
                            -ApplicationId $connection.ApplicationID `
                            -CertificateThumbprint $connection.CertificateThumbprint

    Start-Sleep -Seconds 30
}


$AzureContext = Get-AzSubscription -SubscriptionId $connection.SubscriptionID


# =====================================================
# Helper function used for validation capacity in Active state
# Make sure the applicationId is the Administrator on Power BI Embeded and Workspace
FUNCTION ValidateCapacityInActiveState($capacity_name, $resource_group)
{
    # Get capacity and validate its in active state
    $getCapacityResult = Get-AzPowerBIEmbeddedCapacity -Name $capacity_name -ResourceGroup $resource_group
    
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

# =====================================================
# Helper function used for assigning workspaces from source to target capacity
FUNCTION AssignWorkspacesToCapacity($source_capacity_objectid, $target_capacity_objectid)
{
    $getCapacityGroupsUri = $apiUri + "groups?$" + "filter=capacityId eq " + "'$source_capacity_objectid'"
    $capacityWorkspaces = Invoke-RestMethod -Method GET -Headers $auth_header -Uri $getCapacityGroupsUri

    # Assign workspaces to temporary capacity
    $capacityWorkspaces.value | ForEach-Object -Process {          
      Write-Output ">>> Assigning workspace Name:" $_.name " Id:" $_.id "to capacity id:" $target_capacity_objectid
      $assignToCapacityUri = $apiUri + "groups/" + $_.id + "/AssignToCapacity"
      $assignToCapacityBody = @{capacityId=$target_capacity_objectid} | ConvertTo-Json
      Invoke-RestMethod -Method Post -Headers $auth_header -Uri $assignToCapacityUri -Body $assignToCapacityBody -ContentType 'application/json'

      # Validate workspace to capacity assignment status was completed successfully, if not then exit script
      DO
      {
        $assignToCapacityStatusUri = $apiUri + "groups/" + $_.id + "/CapacityAssignmentStatus"
        $status = Invoke-RestMethod -Method Get -Headers $auth_header -Uri $assignToCapacityStatusUri

        # Exit script if workspace assignment has failed
        IF ($status.status -eq 'AssignmentFailed')
        {
          $errmsg = "workspace " +  $_.id + " assignment has failed!, script will stop."
          Break Script
        }
        
        Start-Sleep -Milliseconds 200

        Write-Output ">>> Assigning workspace Id:" $_.id "to capacity id:" $target_capacity_objectid "Status:" $status.status
      } while ($status.status -ne 'CompletedSuccessfully')
    }

    $getCapacityGroupsUri = $apiUri + "groups?$" + "filter=capacityId eq " + "'$target_capacity_objectid'"
    $capacityWorkspaces = Invoke-RestMethod -Method GET -Headers $auth_header -Uri $getCapacityGroupsUri

    return $capacityWorkspaces
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
            Write-Output ">>> Object ID for" $capacity_name  "is" $_.id
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
# Get authentication token for PowerBI API 
# Make sure the applicationId is the Administrator on Power BI Embeded and Workspace
FUNCTION GetAuthTokenForApplicationId ($applicationId, $secret)
{
    $securePassword = $secret | ConvertTo-SecureString -AsPlainText -Force
    $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $applicationId, $securePassword
    Connect-PowerBIServiceAccount -ServicePrincipal -Credential $credential -TenantId $connection.TenantID
    $headers = Get-PowerBIAccessToken
    return $headers
}

# =====================================================
# Get authentication token for PowerBI API 
# Make sure the applicationId for this runbook is the Administrator on Power BI Embeded and Workspace
FUNCTION GetAuthToken
{
    Connect-PowerBIServiceAccount -ServicePrincipal `
                            -Tenant $connection.TenantID `
                            -ApplicationId $connection.ApplicationID `
                            -CertificateThumbprint $connection.CertificateThumbprint

    $headers = Get-PowerBIAccessToken
    return $headers
}


# =====================================================
# If the applicationId is different from the runbook configure: $token = GetAuthTokenForApplicationId
# $clientId = "FILL ME IN"
# $secret = "FILL ME IN"
# $token = GetAuthTokenForApplicationId $clientId $secret
# =====================================================


$apiUri = "https://api.powerbi.com/v1.0/myorg/"


$token = GetAuthToken 

# =====================================================
# Building Rest API header with authorization token
$auth_header = @{
   'Content-Type'='application/json'
   'Authorization'=$token.Values
}

# =====================================================



# Get and Validate main capacity is in active state
$mainCapacity = ValidateCapacityInActiveState $CapacityName $CapacityResourceGroup

Write-Output " "
Write-Output "========================================================================================================================"
Write-Output "                                           SCALING CAPACITY FROM" $mainCapacity.Sku "To" $TargetSku
Write-Output "========================================================================================================================"
Write-Output " "
Write-Output ">>> Capacity" $CapacityName "is available and ready for scaling!"

# Create new temporary capacity to be used for scale
$guid = New-Guid
$temporaryCapacityName = 'tmpcapacity' + $guid.ToString().Replace('-','s').ToLowerInvariant()
$temporarycapacityResourceGroup = $mainCapacity.ResourceGroup

Write-Output ">>> STEP 1 - Creating a temporary capacity name:"$temporaryCapacityName

$newcap = New-AzPowerBIEmbeddedCapacity -ResourceGroupName $temporarycapacityResourceGroup -Name $temporaryCapacityName -Location $mainCapacity.Location -Sku $TargetSku -Administrator $mainCapacity.Administrator

# Check if new capacity provisioning succeeded
IF (!$newcap -OR $newcap.State.ToString() -ne 'Succeeded') 
{
    Remove-AzPowerBIEmbeddedCapacity -Name $temporaryCapacityName -ResourceGroupName $temporarycapacityResourceGroup    
    $errmsg = "Try to remove temporary capacity due to some failure while provisioning!, Please restart script!"
    Write-Error -Message $errmsg	
    Break Script
}

# Get capacities from PowerBI to find the capacities ID
$getCapacityUri = $apiUri + "capacities"
$capacitiesList = Invoke-RestMethod -Method Get -Headers $auth_header -Uri $getCapacityUri
$sourceCapacityObjectId = GetCapacityObjectID $capacitiesList $CapacityName
$targetCapacityObjectId = GetCapacityObjectID $capacitiesList $temporaryCapacityName
Write-Output ">>> STEP 1 - Completed!"

Write-Output ">>> STEP 2 - Assigning workspaces"
$assignedMainCapacityWorkspaces = AssignWorkspacesToCapacity $sourceCapacityObjectId $targetCapacityObjectId
Write-Output ">>> STEP 2 Completed!"

Write-Output ">>> STEP 3 - Scaling capacity " $CapacityName "to" $targetSku
Update-AzPowerBIEmbeddedCapacity -Name $CapacityName -Sku $targetSku -resourceGroup $CapacityResourceGroup
#Update-AzureRmPowerBIEmbeddedCapacity -Name $CapacityName -sku $targetSku        
$mainCapacity = ValidateCapacityInActiveState $CapacityName $CapacityResourceGroup
Write-Output ">>> STEP 3 completed!" $CapacityName "to" $targetSku

Write-Output " "
Write-Output ">>> STEP 4 - Assigning workspaces to main capacity"
$AssignedTargetCapacityWorkspaces = AssignWorkspacesToCapacity $targetCapacityObjectId $sourceCapacityObjectId

# validate all workspaces were assigned back to the main capacity
$diff =  Compare-Object $AssignedTargetCapacityWorkspaces.value $assignedMainCapacityWorkspaces.value
if ($diff -ne $null)
{  
    $errmsg = "Something went wrong while assigning workspaces to the main capacity, Please re-execute the script"
    Write-Error -Message $errmsg
    Break Script
}
Write-Output ">>> STEP 4 Completed!"
Write-Output " "
Write-Output ">>> STEP 5 - Delete temporary capacity"
# Delete temporary capacity if it was newly created
Remove-AzPowerBIEmbeddedCapacity -Name $temporaryCapacityName -ResourceGroupName $temporarycapacityResourceGroup
Write-Output ">>> STEP 5 Completed!"

Write-Output " "
Write-Output "========================================================================================================================"
Write-Output "                                           Completed Successfully"
Write-Output "                                              Total Duration"
Write-Output "                                            "$stopwatch.Elapsed
Write-Output "========================================================================================================================"
