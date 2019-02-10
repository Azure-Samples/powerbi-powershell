# This script calls the Power BI API to programmatically upload the local PBIX files
# into a Workspace

[cmdletbinding()]
param (
	[Parameter(Mandatory=$true)][string]$Workspace
)

# Instructions:
# 1. Install PowerShell (https://msdn.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell) 
#    and Azure PowerShell cmdlets (Install-Module AzureRM) and the Microsoft Power BI Cmdlets (https://docs.microsoft.com/en-us/powershell/power-bi/overview) 
# 2. Run PowerShell as an administrator
# 3. Change PowerShell directory to where this script is saved
# 4. > ./uploadApplication.ps1 - Workspace <Workspace Name>

# Report Folder
# Local Folder which has the PBIX files. The folder has to be created and PBIX files has to be placed in that
# Default Path is Reports

$report_path_root = "$PSScriptRoot\Reports"

# End Parameters =======================================

# PART 1: Authentication
# ==================================================================
Connect-PowerBIServiceAccount

# Getting Header with Token
$auth_header = Get-PowerBIAccessToken


# PART 2: Checking the Workspace if it exists, if not creating it
# ==================================================================

try 
{
	$target_group_name = $Workspace
	# Checking if the Workspace already exist that the user can access
    $reponse = Get-PowerBIWorkspace -Name "$target_group_name" -Scope Individual
	$target_group_id = $response.id

	if(!$target_group_id) {
		# Checking if the Workspace exist in the Organization
        $reponse = Get-PowerBIWorkspace -Name "$target_group_name" -Scope Organization
		$target_group_id = $response.id
		if (!$target_group_id) {
			# Creating the Workspace
			$body = "{`"name`":`"$target_group_name`"}"
			$response = Invoke-PowerBIRestMethod -Url 'groups' –Headers $auth_header –Method POST -Body $body
			$target_group_id = $response.id
		}
		else {
			# TODO: add logic to add the user to the Workspace
			"Please add the Service user to the Workspace or try again with the user who has access to the Workspace"
			Break
		}
	}
} catch { 
	"Could not find or create a group with that name. Please try again"
    "More details: "
    Write-Host $_.Exception
    Write-Host Resolve-PowerBIError -Last
    Break
}


# PART 3: Copying reports and datasets using Export/Import PBIX APIs
# ==================================================================

$reports = Get-ChildItem $report_path_root

# import the reports that are built on PBIXes
Foreach($report in $reports) {

    $report_name = $report.Name
    $temp_path = "$report_path_root\$report_name"
     
    try {
        New-PowerBIReport -Path '$temp_path' -Name '$report_name' -ConflictAction CreateOrOverwrite -WorkspaceId '$target_group_id'    
        
    } catch [Exception] {
        Write-Host $_.Exception
	    Write-Host "== Error: failed to import PBIX"
        Write-Host Resolve-PowerBIError -Last
        continue
    }
}