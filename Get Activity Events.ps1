# This sample script calls the Power BI API to progammtically Get the Power BI Audit Activity Events
# You can customize this script to pass Continuation Token to get the next set of audit activity events
# For full documentation on the REST APIs, see:
# https://docs.microsoft.com/en-us/rest/api/power-bi/admin/getactivityevents


# Instructions:
# 1. Install PowerShell (https://msdn.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell)
# 2. Install Azure PowerShell Module (https://docs.microsoft.com/en-us/powershell/azure/azurerm/install-azurerm-ps?view=azurermps-6.13.0)
# 3. Fill in the parameter below
# 4. Run the PowerShell script

# Parameters - fill these in before running the script!
# =====================================================

# AAD Client ID
# To get this, go to the following page and follow the steps to provision an app
# https://dev.powerbi.com/apps
# To get the sample to work, ensure that you have the following fields:
# App Type: Native app
# Redirect URL: urn:ietf:wg:oauth:2.0:oob
#  Level of access: Tenant.Read.All or Tenant.ReadWrite.All

$clientId = "<Client ID>"


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

# Get the auth token from AAD
$token = GetAuthToken

# Building Rest API header with authorization token
$authHeader = @{
   'Content-Type'='application/json'
   'Authorization'=$token.CreateAuthorizationHeader()
}


# Get Activity Events
$uri = "https://api.powerbi.com/v1.0/myorg/admin/activityevents?startDateTime=  &endDateTime='2020-03-30T23%3A59%3A59.000Z'"
Invoke-RestMethod -Uri $uri –Headers $authHeader –Method GET –Verbose