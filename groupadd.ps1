
<#
.SYNOPSIS
    Assigns a specified Azure AD group to all Windows-based Intune configuration items.
    Supports classic profiles, settings catalog, endpoint security (intents), and scripts.
    Requires PowerShell 7+ and the Microsoft.Graph module.
#>

# --- CONFIGURATION ---
$GroupId = 5ba5b4dc-6e8d-4b75-8bec-5c7fabf6fbff

 # <-- Replace with your AAD Group Object ID

# --- CONNECT ---
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementConfiguration.ReadWrite.All"
Write-Host "`nConnected to Microsoft Graph.`n" -ForegroundColor Cyan

# --- COLLECT DATA FROM ALL RELEVANT SOURCES ---
Write-Host "Fetching all policy types from Graph..." -ForegroundColor Yellow

# Classic
$uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
$classic = @()
do {
    $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
    $classic += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)
$classic | ForEach-Object { $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'Classic' }
Write-Host "Classic configs: $($classic.Count)"

# Settings Catalog
$uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
$catalog = @()
do {
    $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
    $catalog += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)
$catalog | ForEach-Object { $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'SettingsCatalog' }
Write-Host "Settings Catalog: $($catalog.Count)"

# Endpoint Security (intents)
$uri = "https://graph.microsoft.com/beta/deviceManagement/intents"
$intents = @()
do {
    $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
    $intents += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)
$intents | ForEach-Object { $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'EndpointSecurity' }
Write-Host "Endpoint Security: $($intents.Count)"

# PowerShell scripts
$uri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts"
$scripts = @()
do {
    $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
    $scripts += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)
$scripts | ForEach-Object { $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'Script' }
Write-Host "PowerShell Scripts: $($scripts.Count)"

# Shell scripts (macOS/Linux)
$uri = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts"
$shscripts = @()
do {
    $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
    $shscripts += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)
$shscripts | ForEach-Object { $_ | Add-Member -NotePropertyName Source -NotePropertyValue 'ShellScript' }
Write-Host "Shell Scripts: $($shscripts.Count)"

# Combine all assignable items
$all = @($classic + $catalog + $intents + $scripts + $shscripts)

# --- NORMALIZE PLATFORM AND FILTER FOR WINDOWS ---
$processed = $all | ForEach-Object {
    $scope = "unknown"

    if ($_.'@odata.type') {
        if ($_.'@odata.type' -match 'windows') { $scope = 'Windows' }
        elseif ($_.'@odata.type' -match 'ios') { $scope = 'iOS' }
        elseif ($_.'@odata.type' -match 'mac') { $scope = 'macOS' }
        elseif ($_.'@odata.type' -match 'android') { $scope = 'Android' }
    }

    if ($_.platforms) {
        if ($_.platforms -match 'windows') { $scope = 'Windows' }
        elseif ($_.platforms -match 'ios') { $scope = 'iOS' }
        elseif ($_.platforms -match 'mac') { $scope = 'macOS' }
        elseif ($_.platforms -match 'android') { $scope = 'Android' }
    }

    if ($_.templateId -and $scope -eq 'unknown') {
        if ($_.templateId -match 'windows') { $scope = 'Windows' }
    }

    [PSCustomObject]@{
        Source      = $_.Source
        Scope       = $scope
        DisplayName = $_.displayName
        Id          = $_.id
    }
}

# Filter out non-Windows and unnamed entries
$windowsOnly = $processed | Where-Object { $_.Scope -eq 'Windows' }

Write-Host "`n✅ Total Windows items found: $($windowsOnly.Count)`n" -ForegroundColor Green
$windowsOnly | Format-Table Scope, DisplayName, Id, Source -AutoSize

# --- ASSIGN GROUP TO EACH POLICY ---
$body = @{
    assignments = @(
        @{
            target = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId       = $GroupId
            }
        }
    )
} | ConvertTo-Json -Depth 5

foreach ($item in $windowsOnly) {
    switch ($item.Source) {
        'Classic'           { $base = 'deviceConfigurations' }
        'SettingsCatalog'   { $base = 'configurationPolicies' }
        'EndpointSecurity'  { $base = 'intents' }
        'Script'            { $base = 'deviceManagementScripts' }
        'ShellScript'       { $base = 'deviceShellScripts' }
        default             { $base = $null }
    }

    if ($base) {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/$base/$($item.Id)/assign"
        try {
            Invoke-MgGraphRequest -Uri $uri -Method POST -Body $body -ContentType "application/json"
            Write-Host "✔ Assigned group to $($item.DisplayName) [$($item.Source)]" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "✖ Failed to assign to $($item.DisplayName) [$($item.Source)]: $($_.Exception.Message)"
        }
    }
}

Write-Host "`n✅ Completed assigning group to all Windows-based policies.`n" -ForegroundColor Green
