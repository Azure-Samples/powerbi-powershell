# This script adds the specified user to
# the Workspace mentioned. If no Workspace
# is mentioned, it would add to all the Workspaces

[cmdletbinding()]
param (
	[Parameter(Mandatory=$true)][string]$UserEmail,
    [Parameter][string]$Workspace,
    [Parameter][string]$AccessRight
)

# Instructions:
# 1. Install PowerShell (https://msdn.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell) 
#    and the PowerShell cmdlets (Install-Module -Name MicrosoftPowerBIMgmt)
# 2. Run PowerShell as an administrator
# 3. Change PowerShell directory to where this script is saved
# 4. > ./Add-User-All-Workspace.ps1

try {

    # Authentication and Header
    Connect-PowerBIServiceAccount
    $headers = Get-PowerBIAccessToken

    # Defaults to Admin is access right is not specified
    if(!$AccessRight) {
        $AccessRight = 'Admin'
    }

    # If a Workspace is specified, if not all the available Workspace is taken
    if($Workspace) {
        $Workspace = Get-PowerBIWorkspace -Scope Organization -Name $Workspace
        $target_group_id = $Workspace.Id
        Add-PowerBIWorkspaceUser -Scope Organization -Id $target_group_id -UserEmailAddress $UserEmail -AccessRight $AccessRight
    }
    else {
        $Workspaces = Get-PowerBIWorkspace -Scope Organization -Filter "Type eq 'Workspace'"
        Foreach($Workspace in $Workspaces) {
            Write-Host $Workspace.Name
            $target_group_id = $Workspace.Id
            Add-PowerBIWorkspaceUser -Scope Organization -Id $target_group_id -UserEmailAddress $UserEmail -AccessRight $AccessRight
        }
    }
} catch { 
    Write-Host $_.Exception
    Write-Host Resolve-PowerBIError -Last
    Break
}