# This script calls the Power BI API to programmatically upload the local PBIX files
# into a Workspace

[cmdletbinding()]
param (
	[Parameter(Mandatory=$true)][string]$Workspace
)

# Instructions:
# 1. Install PowerShell (https://msdn.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell) 
#    and the Azure PowerShell cmdlets (Install-Module AzureRM)
# 2. Run PowerShell as an administrator
# 3. Follow the instructions below to fill in the client ID
# 4. Change PowerShell directory to where this script is saved
# 5. > ./uploadApplication.ps1 - Workspace <Workspace Name>

# Parameters - fill these in before running the script!
# ======================================================

# AAD Client ID
# To get this, go to the following page and follow the steps to provision an app
# https://dev.powerbi.com/apps
# ensure that you have the following fields:
# App Type: Native app
# Redirect URL: urn:ietf:wg:oauth:2.0:oob
# Level of access: check all boxes

$clientId = " FILL ME IN " 

# Report Folder
# Local Folder which has the PBIX files. The folder has to be created and PBIX files has to be placed in that
# Default Path is Reports

$report_path_root = "$PSScriptRoot\Reports"

# End Parameters =======================================

# Calls the Active Directory Authentication Library (ADAL) to authenticate against AAD
function GetAuthToken
{
    if(-not (Get-Module AzureRm.Profile)) {
      Import-Module AzureRm.Profile
    }

    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"

    $resourceAppIdURI = "https://analysis.windows.net/powerbi/api"

    $authority = "https://login.microsoftonline.com/common/oauth2/authorize";

    $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority

    $authResult = $authContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, "Auto")

    return $authResult
}

function get_groups_path($group_id) {
    if ($group_id -eq "me") {
        return "myorg"
    } else {
        return "myorg/groups/$group_ID"
    }
}

# PART 1: Authentication
# ==================================================================
$token = GetAuthToken

Add-Type -AssemblyName System.Net.Http

# Building Rest API header with authorization token
$auth_header = @{
   'Content-Type'='application/json'
   'Authorization'=$token.CreateAuthorizationHeader()
}


# PART 2: Checking the Workspace if it exists, if not creating it
# ==================================================================

try 
{
	$target_group_name = $Workspace
	# Checking if the Workspace already exist that the user can access
	$uri = "https://api.powerbi.com/v1.0/myorg/groups?`$filter=name eq '$target_group_name'"
	$response = (Invoke-RestMethod -Uri $uri –Headers $auth_header –Method GET).value
	$target_group_id = $response.id

	if(!$target_group_id) {
		# Checking if the Workspace exist in the Organization
		$uri = "https://api.powerbi.com/v1.0/myorg/admin/groups?`$filter=(name eq '$target_group_name') and (state eq 'Active')"
		$response = (Invoke-RestMethod -Uri $uri –Headers $auth_header –Method GET).value
		$target_group_id = $response.id
		if (!$target_group_id) {
			# Creating the Workspace
			$uri = "https://api.powerbi.com/v1.0/myorg/groups"
			$body = "{`"name`":`"$target_group_name`"}"
			$response = Invoke-RestMethod -Uri $uri –Headers $auth_header –Method POST -Body $body
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
	Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
    Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
    Break
}


# PART 3: Copying reports and datasets using Export/Import PBIX APIs
# ==================================================================
$failure_log = @()
$import_jobs = @()
$target_group_path = get_groups_path($target_group_ID)

$reports = Get-ChildItem $report_path_root

# import the reports that are built on PBIXes

Foreach($report in $reports) {
   
    $report_name = $report.Name
    $temp_path = "$report_path_root\$report_name"
     
    try {
        "== Importing $report_name to target workspace"
        $uri = "https://api.powerbi.com/v1.0/$target_group_path/imports/?datasetDisplayName=$report_name.pbix&nameConflict=CreateOrOverwrite"

        # Here we switch to HttpClient class to help POST the form data for importing PBIX
        $httpClient = New-Object System.Net.Http.Httpclient $httpClientHandler
        $httpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token.AccessToken);
        $packageFileStream = New-Object System.IO.FileStream @($temp_path, [System.IO.FileMode]::Open)
        
	    $contentDispositionHeaderValue = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue "form-data"
	    $contentDispositionHeaderValue.Name = "file0"
	    $contentDispositionHeaderValue.FileName = $file_name
 
        $streamContent = New-Object System.Net.Http.StreamContent $packageFileStream
        $streamContent.Headers.ContentDisposition = $contentDispositionHeaderValue
        
        $content = New-Object System.Net.Http.MultipartFormDataContent
        $content.Add($streamContent)

	    $response = $httpClient.PostAsync($Uri, $content).Result
 
	    if (!$response.IsSuccessStatusCode) {
		    $responseBody = $response.Content.ReadAsStringAsync().Result
            "= This report cannot be imported to target workspace. Skipping..."
			$errorMessage = "Status code {0}. Reason {1}. Server reported the following message: {2}." -f $response.StatusCode, $response.ReasonPhrase, $responseBody
			throw [System.Net.Http.HttpRequestException] $errorMessage
		} 
        
        # save the import IDs
        $import_job_id = (ConvertFrom-JSON($response.Content.ReadAsStringAsync().Result)).id

        # wait for import to complete
        $upload_in_progress = $true
        while($upload_in_progress) {
            $uri = "https://api.powerbi.com/v1.0/$target_group_path/imports/$import_job_id"
            $response = Invoke-RestMethod -Uri $uri –Headers $auth_header –Method GET
            
            if ($response.importState -eq "Succeeded") {
                "Publish succeeded!"
                break
            }

            if ($response.importState -ne "Publishing") {
                "Error: publishing failed, skipping this. More details: "
                $response
                break
            }
            
            Write-Host -NoNewLine "."
            Start-Sleep -s 5
        }
            
        
    } catch [Exception] {
        Write-Host $_.Exception
	    Write-Host "== Error: failed to import PBIX"
        Write-Host "= HTTP Status Code:" $_.Exception.Response.StatusCode.value__ 
        Write-Host "= HTTP Status Description:" $_.Exception.Response.StatusDescription
        continue
    }
}