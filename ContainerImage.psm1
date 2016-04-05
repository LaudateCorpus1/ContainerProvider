﻿#region Variables
$script:location_modules = "$env:LOCALAPPDATA\ContainerImage"
$script:file_modules = "$script:location_modules\sources.txt"
$script:ContainerSources = $null
$script:wildcardOptions = [System.Management.Automation.WildcardOptions]::CultureInvariant -bor `
                          [System.Management.Automation.WildcardOptions]::IgnoreCase
$script:ContainerImageSearchIndex = "ContainerImageSearchIndex.txt"
$script:PSArtifactTypeModule = 'Module'
$script:PSArtifactTypeScript = 'Script'
$script:isNanoServerInitialized = $false
$script:isNanoServer = $false
$script:Providername = "ContainerImage"
$separator = "|#|"

Microsoft.PowerShell.Core\Set-StrictMode -Version Latest

#endregion Variables

#region One-Get Functions

function Find-Package
{ 
    [CmdletBinding()]
    param
    (
        [string[]]
        $names,

        [string]
        $RequiredVersion,

        [string]
        $MinimumVersion,

        [string]
        $MaximumVersion
    )

    Set-ModuleSourcesVariable
    
    $options = $request.Options

    foreach( $o in $options.Keys )
    {
        Write-Debug ( "OPTION: {0} => {1}" -f ($o, $options[$o]) )
    }

    $AllVersions = $null
    if($options.ContainsKey("AllVersions"))
    {
        $AllVersions = $options['AllVersions']
    }

    $sources = @()
    if($options.ContainsKey('Source'))
    {
        $sources = $options['Source']
    }

    $convertedRequiredVersion = Convert-Version $requiredVersion
    $convertedMinVersion = Convert-Version $minimumVersion
    $convertedMaxVersion = Convert-Version $maximumVersion

    if(-not (CheckVersion $convertedMinVersion $convertedMaxVersion $convertedRequiredVersion $AllVersions))
    {
        return $null
    }

    if ($null -eq $names -or $names.Count -eq 0)
    {
        $names = @('')
    }

    $allResults = @()
    $allSources = Get-Sources $sources
    foreach($currSource in $allSources)
    {
        foreach ($singleName in $names)
        {
            if ([string]::IsNullOrWhiteSpace($singleName) -or $singleName.Trim() -eq '*')
            {
                # if no name is supplied but min or max version is supplied, error out
                if ($null -ne $convertedMinVersion -or $null -ne $convertedMaxVersion)
                {
                    ThrowError -CallerPSCmdlet $PSCmdlet `
                                -ExceptionName System.Exception `
                                -ExceptionMessage "Name is required when either MinimumVersion or MaximumVersion parameter is used" `
                                -ExceptionObject $singleName `
                                -ErrorId NameRequiredForMinOrMaxVersion `
                                -ErrorCategory InvalidData
                }
            }

            $location = $currSource.SourceLocation
            $sourceName = $currSource.Name

            if($location.StartsWith("http://") -or $location.StartsWith("https://"))
            {
                $allResults += Find-Azure -Name $singleName `
                                    -MinimumVersion $convertedMinVersion `
                                    -MaximumVersion $convertedMaxVersion `
                                    -RequiredVersion $convertedRequiredVersion `
                                    -AllVersions:$AllVersions `
                                    -Location $location `
                                    -SourceName $sourceName
            }
            elseif($location.StartsWith("\\"))
            {
                $allResults += Find-UNCPath -Name $singleName `
                                    -MinimumVersion $convertedMinVersion `
                                    -MaximumVersion $convertedMaxVersion `
                                    -RequiredVersion $convertedRequiredVersion `
                                    -AllVersions:$AllVersions `
                                    -localPath $location `
                                    -SourceName $sourceName
            }
            else
            {
                Write-Error "Bad source '$sourceName' with location at $location"
            }
        }
    }

    if($null -eq $allResults)
    {
        return
    }

    foreach($result in $allResults)
    {
        $swid = New-SoftwareIdentityFromContainerImageItemInfo $result
        Write-Output $swid
    }
}

function Download-Package
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FastPackageReference,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )
    
    DownloadPackageHelper -FastPackageReference $FastPackageReference `
                            -Request $Request `
                            -Location $Location
}

function Install-Package
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FastPackageReference
    )

    [string[]] $splitterArray = @("$separator")    
    [string[]] $resultArray = $FastPackageReference.Split($splitterArray, [System.StringSplitOptions]::None)
    
    $name = $resultArray[0]
    $version = $resultArray[1]
    $Location = $script:location_modules

    $Destination = GenerateFullPath -Location $Location `
                                    -Name $name `
                                    -Version $Version

    $downloadOutput = DownloadPackageHelper -FastPackageReference $FastPackageReference `
                            -Request $Request `
                            -Location $Location
    
    $startInstallTime = Get-Date

    Write-Verbose "Trying to install the Image: $Destination"

    Install-ContainerOSImage -WimPath $Destination `
                             -Force

    $endInstallTime = Get-Date
    $differenceInstallTime = New-TimeSpan -Start $startInstallTime -End $endInstallTime
    $installTime = "Installed in " + $differenceInstallTime.Hours + " hours, " + $differenceInstallTime.Minutes + " minutes, " + $differenceInstallTime.Seconds + " seconds."
    Write-Verbose $installTime

    # Clean up
    Write-Verbose "Removing the installer: $Destination"
    rm $Destination
    
    Write-Output $downloadOutput
}

function Get-InstalledPackage
{
}

function Initialize-Provider
{
    write-debug "In $($script:Providername) - Initialize-Provider"
}

function Get-PackageProviderName
{
    return $script:Providername
}

#endregion One-Get Functions

#region Stand-Alone Functions

function Find-ContainerImage
{
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$false,Position=0)]
        [string[]]
        $Name,

        [System.Version]
        $MinimumVersion,

        [System.Version]
        $MaximumVersion,
        
        [System.Version]
        $RequiredVersion,

        [switch]
        $AllVersions,

        [System.string]
        $source
    )

    Begin
    {
    }

    Process
    {
        $PSBoundParameters["Provider"] = $script:Providername

        PackageManagement\Find-Package @PSBoundParameters
    }
}

function Save-ContainerImage
{
    [CmdletBinding(DefaultParameterSetName='NameAndPathParameterSet',
                   SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory=$true, 
                   ValueFromPipelineByPropertyName=$true,
                   Position=0,
                   ParameterSetName='NameAndPathParameterSet')]
        [Parameter(Mandatory=$true, 
                   ValueFromPipelineByPropertyName=$true,
                   Position=0,
                   ParameterSetName='NameAndLiteralPathParameterSet')]
        [ValidateNotNullOrEmpty()]

        [string[]]
        $Name,
        
        [Parameter(Mandatory=$true, 
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='InputOjectAndPathParameterSet')]
        [Parameter(Mandatory=$true, 
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='InputOjectAndLiteralPathParameterSet')]
        [ValidateNotNull()]
        [PSCustomObject[]]
        $InputObject,
        
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndPathParameterSet')]
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndLiteralPathParameterSet')]
        [Version]
        $MinimumVersion,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndPathParameterSet')]
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndLiteralPathParameterSet')]
        [Version]
        $MaximumVersion,
        
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndPathParameterSet')]
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameAndLiteralPathParameterSet')]
        [Alias('Version')]
        [Version]
        $RequiredVersion,

        [Parameter(Mandatory=$true, ParameterSetName='NameAndPathParameterSet')]
        [Parameter(Mandatory=$true, ParameterSetName='InputOjectAndPathParameterSet')]
        [string]
        $Path,

        [Parameter(Mandatory=$true, ParameterSetName='NameAndLiteralPathParameterSet')]
        [Parameter(Mandatory=$true, ParameterSetName='InputOjectAndLiteralPathParameterSet')]
        [string]
        $LiteralPath,

        [Parameter()]
        [switch]
        $Force,

        [Parameter()]
        [System.string]
        $source
    )

    if($InputObject)
    {
    }
    else
    {
        $PSBoundParameters["Provider"] = $script:Providername
    }

    PackageManagement\Save-Package @PSBoundParameters
}

function Install-ContainerImage
{
    [CmdletBinding(DefaultParameterSetName='NameAndPathParameterSet',
                   SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory=$true, 
                   ValueFromPipelineByPropertyName=$true,
                   Position=0,
                   ParameterSetName='NameParameterSet')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Name,

        [Parameter(Mandatory=$true, 
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0,
                   ParameterSetName='InputObject')]
        [ValidateNotNull()]
        [PSCustomObject[]]
        $InputObject,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameParameterSet')]
        [Alias("Version")]
        [ValidateNotNull()]
        [Version]
        $MinimumVersion,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameParameterSet')]
        [ValidateNotNull()]
        [Version]
        $MaximumVersion,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='NameParameterSet')]
        [ValidateNotNull()]
        [Version]
        $RequiredVersion,

        [Parameter()]
        [switch]
        $Force,

        [Parameter()]
        [System.string]
        $Source
    )

    if($WhatIfPreference)
    {
        $null = $PSBoundParameters.Remove("WhatIf")
        $findOutput = PackageManagement\Find-Package @PSBoundParameters
        $packageName = $findOutput.name
        $packageversion = $findOutput.version
        $packageSource = $findOutput.Source

        $string = '"Package ' + $packageName + ' version ' + $packageversion + ' from ' + $packageSource + '"'
        $messageWhatIf = 'What if: Performing the operation "Install Package" on target ' + $string + ' .'

        Write-Host $messageWhatIf
        return
    }

    if($InputObject)
    {
    }
    else
    {
        $PSBoundParameters["Provider"] = $script:Providername
    }

    #PackageManagement\Install-Package @PSBoundParameters

    $Location = $script:location_modules

    $PSBoundParameters["Path"] = $Location
    $PSBoundParameters["Force"] = $true

    $downloadOutput = PackageManagement\Save-Package @PSBoundParameters
    
    $Destination = GenerateFullPath -Location $Location `
                                    -Name $downloadOutput.Name `
                                    -Version $downloadOutput.Version

    $startInstallTime = Get-Date

    Write-Verbose "Trying to install the Image: $Destination"

    Install-ContainerOSImage -WimPath $Destination `
                             -Force

    $endInstallTime = Get-Date
    $differenceInstallTime = New-TimeSpan -Start $startInstallTime -End $endInstallTime
    $installTime = "Installed in " + $differenceInstallTime.Hours + " hours, " + $differenceInstallTime.Minutes + " minutes, " + $differenceInstallTime.Seconds + " seconds."
    Write-Verbose $installTime

    # Clean up
    Write-Verbose "Removing the installer: $Destination"
    rm $Destination
}

#endregion Stand-Alone Functions

#region Helper-Functions

function CheckVersion
{
    param
    (
        [System.Version]$MinimumVersion,
        [System.Version]$MaximumVersion,
        [System.Version]$RequiredVersion,
        [switch]$AllVersions
    )

    if($AllVersions -and $RequiredVersion)
    {
        Write-Error "AllVersions and RequiredVersion cannot be used together"
        return $false
    }

    if($AllVersions -or $RequiredVersion)
    {
        if($MinimumVersion -or $MaximumVersion)
        {
            Write-Error "AllVersions and RequiredVersion switch cannot be used with MinimumVersion or MaximumVersion"
            return $false
        }
    }

    if($MinimumVersion -and $MaximumVersion)
    {
        if($MaximumVersion -lt $MinimumVersion)
        {
            Write-Error "Minimum Version cannot be more than Maximum Version"
            return $false
        }
    }

    return $true
}

function Find-Azure
{
    param(
        [Parameter(Mandatory=$false,Position=0)]
        [string[]]
        $Name,

        [System.Version]
        $MinimumVersion,

        [System.Version]
        $MaximumVersion,
        
        [System.Version]
        $RequiredVersion,

        [switch]
        $AllVersions,

        [System.String]
        $Location,

        [System.String]
        $SourceName
    )

    if(-not (IsNanoServer))
    {
        Add-Type -AssemblyName System.Net.Http
    }

    $searchFile = Get-SearchIndex -fwdLink $Location `
                                    -SourceName $SourceName
 
    $searchFileContent = Get-Content $searchFile

    if($null -eq $searchFileContent)
    {
        return $null
    }

    if(IsNanoServer)
    {
        $jsonDll = [Microsoft.PowerShell.CoreCLR.AssemblyExtensions]::LoadFrom($PSScriptRoot + "\Json.coreclr.dll")
        $jsonParser = $jsonDll.GetTypes() | Where-Object name -match jsonparser
        $searchContent = $jsonParser::FromJson($searchFileContent)
        $searchStuff = $searchContent.Get_Item("array0")
        $searchData = @()
        foreach($searchStuffEntry in $searchStuff)
        {
            $obj = New-Object PSObject 
            $obj | Add-Member NoteProperty Name $searchStuffEntry.Name
            $obj | Add-Member NoteProperty Version $searchStuffEntry.Version
            $obj | Add-Member NoteProperty Description $searchStuffEntry.Description
            $obj | Add-Member NoteProperty SasToken $searchStuffEntry.SasToken
            $searchData += $obj
        }
    }
    else
    {
        $searchData = $searchFileContent | ConvertFrom-Json
    }

    # If name is null or whitespace, interpret as *
    if ([string]::IsNullOrWhiteSpace($Name))
    {
        $Name = "*"
    }

    # Handle the version not given scenario
    if((-not ($MinimumVersion -or $MaximumVersion -or $RequiredVersion -or $AllVersions)))
    {
        $MinimumVersion = [System.Version]'0.0.0.0'
    }

    $searchResults = @()
    $searchDictionary = @{}

    foreach($entry in $searchData)
    {
        $toggle = $false

        # Check if the search string has * in it
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name))
        {
            if($entry.name -like $Name)
            {
                $toggle = $true
            }
            else
            {
                continue
            }
        }
        else
        {
            if($entry.name -eq $Name)
            {
                $toggle = $true
            }
            else
            {
                continue
            }
        }

        $thisVersion = Convert-Version $entry.version

        if($MinimumVersion)
        {
            $convertedMinimumVersion = Convert-Version $MinimumVersion

            if(($thisVersion -ge $convertedMinimumVersion))
            {
                if($searchDictionary.ContainsKey($entry.name))
                {
                    $objEntry = $searchDictionary[$entry.name]
                    $objVersion = Convert-Version $objEntry.Version

                    if($thisVersion -gt $objVersion)
                    {
                        $toggle = $true
                    }
                    else
                    {
                        $toggle = $false
                    }
                }
                else
                {
                    $toggle = $true
                }   
            }
            else
            {
                $toggle = $false
            }
        }

        if($MaximumVersion)
        {
            $convertedMaximumVersion = Convert-Version $MaximumVersion

            if(($thisVersion -le $convertedMaximumVersion))
            {
                if($searchDictionary.ContainsKey($entry.name))
                {
                    $objEntry = $searchDictionary[$entry.name]
                    $objVersion = Convert-Version $objEntry.Version

                    if($thisVersion -gt $objVersion)
                    {
                        $toggle = $true
                    }
                    else
                    {
                        $toggle = $false
                    }
                }
                else
                {
                    $toggle = $true
                }
            }
            else
            {
                $toggle = $false
            }
        }

        if($RequiredVersion)
        {
            $convertedRequiredVersion = Convert-Version $RequiredVersion

            if(($thisVersion -eq $convertedRequiredVersion))
            {
                $toggle = $true                
            }
            else
            {
                $toggle = $false
            }
        }

        if($AllVersions)
        {
            if($toggle)
            {
                $searchResults += $entry
            }
        }

        if($toggle)
        {
            if($searchDictionary.ContainsKey($entry.name))
            {
                $searchDictionary.Remove($entry.name)
            }
            
            $searchDictionary.Add($entry.name, $entry)
        }
    }

    if(-not $AllVersions)
    {
        $searchDictionary.Keys | ForEach-Object {
                $searchResults += $searchDictionary.Item($_)
            }
    }

    $searchEntries = @()

    foreach($searchEntry in $searchResults)
    {
        $EntryName = $searchEntry.Name
        $EntryVersion = $searchEntry.Version
        $EntryDescription = $searchEntry.Description
        $SasToken = $searchEntry.SasToken
        $ResultEntry = Microsoft.PowerShell.Utility\New-Object PSCustomObject -Property ([ordered]@{
		    Name = $EntryName
		    Version = $EntryVersion
		    Description = $EntryDescription
		    SasToken = $SasToken
            Source = $SourceName
        })
        
        $searchEntries += $ResultEntry
    }

    $searchEntries = $searchEntries | Sort-Object "Version" -Descending

    return $searchEntries
}

function Find-UNCPath
{
    param(
        [Parameter(Mandatory=$false,Position=0)]
        [string]
        $Name,

        [System.Version]
        $MinimumVersion,

        [System.Version]
        $MaximumVersion,
        
        [System.Version]
        $RequiredVersion,

        [switch]
        $AllVersions,

        [System.String]
        $localPath,

        [System.String]
        $SourceName
    )

    $responseArray = @()
    try
    {
        $nameToSearch = ""
        if(-not $Name)
        {
            $nameToSearch = "*.wim"
        }
        else
        {
            if(-not($name.ToLower().EndsWith(".wim")))
            {
                $name = $name + ".wim"
            }

            $nameToSearch = $Name
        }

        $images = @()
        $images = Get-ChildItem -Path $localPath `
                                    -ErrorAction SilentlyContinue `
                                    -Filter $nameToSearch `
                                    -Recurse `
                                    -File `
                                    -Depth 1 `
                                    -Force | % { $_.FullName }

        $searchResults = @()
        $searchDictionary = @{}

        # Handle the version not given scenario
        if((-not ($MinimumVersion -or $MaximumVersion -or $RequiredVersion -or $AllVersions)))
        {
            $MinimumVersion = [System.Version]'0.0.0.0'
        }

        foreach($image in $images)
        {
            # Since the Get-ChildItem has filtered images by name
            # All images are potentially candidates for result
            $toggle = $true
            $thisVersion = get-Version $image
            $fileName = Split-Path $image -Leaf

            if($MinimumVersion)
            {
                $convertedMinimumVersion = Convert-Version $MinimumVersion

                if(($thisVersion -ge $convertedMinimumVersion))
                {
                    if($searchDictionary.ContainsKey($fileName))
                    {
                        $objEntry = $searchDictionary[$fileName]
                        $objVersion = Convert-Version $objEntry.Version

                        if($thisVersion -gt $objVersion)
                        {
                            $toggle = $true
                        }
                        else
                        {
                            $toggle = $false
                        }
                    }
                    else
                    {
                        $toggle = $true
                    }   
                }
                else
                {
                    $toggle = $false
                }
            }

            if($MaximumVersion)
            {
                $convertedMaximumVersion = Convert-Version $MaximumVersion

                if(($thisVersion -le $convertedMaximumVersion))
                {
                    if($searchDictionary.ContainsKey($fileName))
                    {
                        $objEntry = $searchDictionary[$fileName]
                        $objVersion = Convert-Version $objEntry.Version

                        if($thisVersion -gt $objVersion)
                        {
                            $toggle = $true
                        }
                        else
                        {
                            $toggle = $false
                        }
                    }
                    else
                    {
                        $toggle = $true
                    }
                }
                else
                {
                    $toggle = $false
                }
            }

            if($RequiredVersion)
            {
                $convertedRequiredVersion = Convert-Version $RequiredVersion

                if(($thisVersion -eq $convertedRequiredVersion))
                {
                    $toggle = $true                
                }
                else
                {
                    $toggle = $false
                }
            }

            if($AllVersions)
            {
                if($toggle)
                {
                    $searchResults += $image
                }
            }

            if($toggle)
            {
                if($searchDictionary.ContainsKey($fileName))
                {
                    $searchDictionary.Remove($fileName)
                }
            
                $searchDictionary.Add($fileName, $image)
            }
        }

        if(-not $AllVersions)
        {
            $searchDictionary.Keys | ForEach-Object {
                    $searchResults += $searchDictionary.Item($_)
                }
        }

        $searchEntries = @()

        foreach($searchEntry in $searchResults)
        {
            $entryName = Split-Path $searchEntry -Leaf
            $entryVersion = get-Version $searchEntry
            $entryDesc = $entryName
            $path = $localPath
            $ResultEntry = Microsoft.PowerShell.Utility\New-Object PSCustomObject -Property ([ordered]@{
		        Name = $EntryName
		        Version = $EntryVersion
		        Description = $EntryDesc
		        SasToken = $path
                Source = $SourceName
            })

            $searchEntries += $ResultEntry
        }

        return $searchEntries
    }
    catch
    {
        Write-Error "Unable to access the sub-folders of $localPath"
        return
    }
}

function Convert-Version([string]$version)
{
    if ([string]::IsNullOrWhiteSpace($version))
    {
        return $null;
    }

    # not supporting semver here. let's try to normalize the versions
    if ($version.StartsWith("."))
    {
        # add leading zeros
        $version = "0" + $version
    }
        
    # let's see how many parts are we given with the version
    $parts = $version.Split(".").Count

    # add .0 dependending number of parts since we need 4 parts
    while ($parts -lt 4)
    {
        $version = $version + ".0"
        $parts += 1
    }

    [version]$convertedVersion = $null

    # try to convert
    if ([version]::TryParse($version, [ref]$convertedVersion))
    {
        return $convertedVersion
    }

    return $null;
}

function IsNanoServer
{
    if ($script:isNanoServerInitialized)
    {
        return $script:isNanoServer
    }
    else
    {
        $operatingSystem = Get-CimInstance -ClassName win32_operatingsystem
        $systemSKU = $operatingSystem.OperatingSystemSKU
        $script:isNanoServer = ($systemSKU -eq 109) -or ($systemSKU -eq 144) -or ($systemSKU -eq 143)
        $script:isNanoServerInitialized = $true
        return $script:isNanoServer
    }
}

function Resolve-FwdLink
{
    param
    (
        [parameter(Mandatory=$false)]
        [System.String]$Uri
    )
    
    if(-not (IsNanoServer))
    {
        Add-Type -AssemblyName System.Net.Http
    }
    $httpClient = New-Object System.Net.Http.HttpClient
    $response = $httpclient.GetAsync($Uri)
    $link = $response.Result.RequestMessage.RequestUri

    return $link
}

function Get-SearchIndex
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]
        $fwdLink,

        [Parameter(Mandatory=$true)]
        [string]
        $SourceName
    )
    
    $fullUrl = Resolve-FwdLink $fwdLink
    $fullUrl = $fullUrl.AbsoluteUri
    $searchIndex = $SourceName + "_" + $script:ContainerImageSearchIndex
    $destination = Join-Path $script:location_modules $searchIndex

    if(-not(Test-Path $script:location_modules))
    {
        md $script:location_modules
    }

    if(Test-Path $destination)
    {
        Remove-Item $destination
        DownloadFile -downloadURL $fullUrl `
                    -destination $destination
    }
    else
    {
        DownloadFile -downloadURL $fullUrl `
                    -destination $destination
    }
    
    return $destination
} 

function DownloadFile
{
    [CmdletBinding()]
    param($downloadURL, $destination)
    
    $startTime = Get-Date

    try
    {
        # Download the file
        Write-Verbose "Downloading $downloadUrl to $destination"
        $saveItemPath = $PSScriptRoot + "\SaveHTTPItemUsingBITS.psm1"
        Import-Module "$saveItemPath"
        Save-HTTPItemUsingBitsTransfer -Uri $downloadURL `
                        -Destination $destination

        Write-Verbose "Finished downloading"
        $endTime = Get-Date
        $difference = New-TimeSpan -Start $startTime -End $endTime
        $downloadTime = "Downloaded in " + $difference.Hours + " hours, " + $difference.Minutes + " minutes, " + $difference.Seconds + " seconds."
        Write-Verbose $downloadTime
    }
    catch
    {
        ThrowError -CallerPSCmdlet $PSCmdlet `
                    -ExceptionName $_.Exception.GetType().FullName `
                    -ExceptionMessage $_.Exception.Message `
                    -ExceptionObject $downloadURL `
                    -ErrorId FailedToDownload `
                    -ErrorCategory InvalidOperation        
    }
}

function New-SoftwareIdentityFromContainerImageItemInfo
{
    [Cmdletbinding()]
    param(
        [PSCustomObject]
        $package
    )

    $fastPackageReference = $package.Name + 
                                $separator + $package.version + 
                                $separator + $package.Description + 
                                $separator + $package.Source + 
                                $separator + $package.SasToken

    $Name = [System.IO.Path]::GetFileNameWithoutExtension($package.Name)

    $params = @{
                    FastPackageReference = $fastPackageReference;
                    Name = $Name;
                    Version = $package.version.ToString();
                    versionScheme  = "MultiPartNumeric";
                    Source = $package.Source;
                    Summary = $package.Description;
                }
    New-SoftwareIdentity @params
}

function get-Version
{
    param($fullPath)

    # Throw error if the given File is folder or doesn't exist
    if((Get-Item $fullPath) -is [System.IO.DirectoryInfo])
    {
        Write-Error "Please enter a file name not a folder."
        throw "$fullPath is a folder not file"
    }

    $containerImageInfo = Get-WindowsImage -ImagePath $fullPath -Index 1
    $containerImageVersion = $containerImageInfo.Version

    return $containerImageVersion
}

# Utility to throw an errorrecord
function ThrowError
{
    param
    (        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCmdlet]
        $CallerPSCmdlet,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]        
        $ExceptionName,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ExceptionMessage,
        
        [System.Object]
        $ExceptionObject,
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ErrorId,

        [parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.ErrorCategory]
        $ErrorCategory
    )
        
    $exception = New-Object $ExceptionName $ExceptionMessage;
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, $ErrorId, $ErrorCategory, $ExceptionObject    
    $CallerPSCmdlet.ThrowTerminatingError($errorRecord)
}

function DownloadPackageHelper
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FastPackageReference,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $request
    )

    [string[]] $splitterArray = @("$separator")
    
    [string[]] $resultArray = $fastPackageReference.Split($splitterArray, [System.StringSplitOptions]::None)

    $name = $resultArray[0]
    $version = $resultArray[1]
    $description = $resultArray[2]
    $source = $resultArray[3]
    $sasToken = $resultArray[4]

    if($sasToken.StartsWith("\\"))
    {
        $sasToken = Join-Path $sasToken $name
    }

    $options = $request.Options

    foreach( $o in $options.Keys )
    {
        Write-Debug ( "OPTION: {0} => {1}" -f ($o, $options[$o]) )
    }

    $Force = $false
    if($options.ContainsKey("Force"))
    {
        $Force = $options['Force']
    }

    if(-not (Test-Path $Location))
    {
        if($Force)
        {
            Write-Verbose "Creating: $Location as it doesn't exist."
            mkdir $Location
        }
        else
        {
            $errorMessage = ("Cannot find the path '{0}' because it does not exist" -f $Location)
            ThrowError  -ExceptionName "System.ArgumentException" `
                    -ExceptionMessage $errorMessage `
                    -ErrorId "PathNotFound" `
                    -CallerPSCmdlet $PSCmdlet `
                    -ExceptionObject $Location `
                    -ErrorCategory InvalidArgument
        }
    }

    $fullPath = GenerateFullPath -Location $Location `
                                    -Name $name `
                                    -Version $Version

    if(Test-Path $fullPath)
    {
        if($Force)
        {
            $existingFileItem = get-item $fullPath
            if($existingFileItem.isreadonly)
            {
                throw "Cannot remove read-only file $fullPath. Remove read-only and use -Force again."
            }
            else
            {
                Remove-Item $fullPath
                DownloadFile $sasToken $fullPath
            }
        }
        else
        {
            Write-Verbose "$fullPath already exists. Skipping save. Use -Force to overwrite."
        }
    }
    else
    {
        DownloadFile $sasToken $fullPath
    }

    $savedWindowsPackageItem = Microsoft.PowerShell.Utility\New-Object PSCustomObject -Property ([ordered]@{
		                Name = $name
		                Version = $version
		                Description = $description
		                SasToken = $sasToken
                        Source = $source
                        FullPath = $fullPath
                    })

    Write-Output (New-SoftwareIdentityFromContainerImageItemInfo $savedWindowsPackageItem)
}

function GenerateFullPath
{
    param
    (
        [Parameter(Mandatory=$true)]
        [System.String]
        $Location,

        [Parameter(Mandatory=$true)]
        [System.String]
        $Name,

        [Parameter(Mandatory=$true)]
        [System.Version]
        $Version
    )

    $fileName = $name + "-" + $Version.ToString().replace('.','-') + ".wim"
    $fullPath = Join-Path $Location $fileName

    return $fullPath
}

#endregion Helper-Functions

#region PackageSource Functions

function Get-Sources
{
    param($sources)

    Set-ModuleSourcesVariable

    $listOfSources = @()
    
    foreach($mySource in $script:ContainerSources.Values)
    {
        if((-not $sources) -or
            (($mySource.Name -eq $sources) -or
               ($mySource.SourceLocation -eq $sources)))
        {
            $tempHolder = @{}

            $location = $mySource."SourceLocation"
            $tempHolder.Add("SourceLocation", $location)
            
            $packageSourceName = $mySource.Name
            $tempHolder.Add("Name", $packageSourceName)
            
            $listOfSources += $tempHolder
        }
    }

    return $listOfSources
}

function DeSerialize-PSObject
{
    [CmdletBinding(PositionalBinding=$false)]    
    Param
    (
        [Parameter(Mandatory=$true)]        
        $Path
    )
    $filecontent = Microsoft.PowerShell.Management\Get-Content -Path $Path
    [System.Management.Automation.PSSerializer]::Deserialize($filecontent)    
}

function Set-ModuleSourcesVariable
{
    [CmdletBinding()]
    param([switch]$Force)

    if(Microsoft.PowerShell.Management\Test-Path $script:file_modules)
    {
        $script:ContainerSources = DeSerialize-PSObject -Path $script:file_modules
    }
    else
    {
        $script:ContainerSources = [ordered]@{}
                
        $defaultModuleSource = Microsoft.PowerShell.Utility\New-Object PSCustomObject -Property ([ordered]@{
            Name = "ContainerImageGallery"
            SourceLocation = "http://go.microsoft.com/fwlink/?LinkID=746630&clcid=0x409"
            Trusted=$false
            Registered= $true
            InstallationPolicy = "Untrusted"
        })

        $script:ContainerSources.Add("ContainerImageGallery", $defaultModuleSource)
        Save-ModuleSources
    }
}

function Save-ModuleSources
{
    # check if exists
    if(-not (Test-Path $script:location_modules))
    {
        $null = md $script:location_modules
    }

    # seralize module
    Microsoft.PowerShell.Utility\Out-File -FilePath $script:file_modules `
                                            -Force `
                                            -InputObject ([System.Management.Automation.PSSerializer]::Serialize($script:ContainerSources))
}

function Get-DynamicOptions
{
    param
    (
        [Microsoft.PackageManagement.MetaProvider.PowerShell.OptionCategory]
        $category
    )
}

function Add-PackageSource
{
    [CmdletBinding()]
    param
    (
        [string]
        $Name,
         
        [string]
        $Location,

        [bool]
        $Trusted
    )

    Set-ModuleSourcesVariable -Force

    $Options = $request.Options

    # Add new module source
    $moduleSource = Microsoft.PowerShell.Utility\New-Object PSCustomObject -Property ([ordered]@{
            Name = $Name
            SourceLocation = $Location            
            Trusted=$Trusted
            Registered= $true
            InstallationPolicy = if($Trusted) {'Trusted'} else {'Untrusted'}
    })

    #TODO: Check if name already exists
    $script:ContainerSources.Add($Name, $moduleSource)

    Save-ModuleSources

    Write-Output -InputObject (New-PackageSourceFromModuleSource -ModuleSource $moduleSource)
}

function Remove-PackageSource
{
    param
    (
        [string]
        $Name
    )
    
    Set-ModuleSourcesVariable -Force

    if(-not $script:ContainerSources.Contains($Name))
    {
        Write-Error -Message "Package source $Name not found" `
                        -ErrorId "Package source $Name not found" `
                        -Category InvalidOperation `
                        -TargetObject $Name
        continue
    }

    $script:ContainerSources.Remove($Name)

    Save-ModuleSources

    #Write-Verbose ($LocalizedData.PackageSourceUnregistered -f ($Name))
}

function Resolve-PackageSource
{
    Set-ModuleSourcesVariable
    $SourceName = $request.PackageSources
    
    if(-not $SourceName)
    {
        $SourceName = "*"
    }

    foreach($moduleSourceName in $SourceName)
    {
        if($request.IsCanceled)
        {
            return
        }

        $wildcardPattern = New-Object System.Management.Automation.WildcardPattern $moduleSourceName,$script:wildcardOptions
        $moduleSourceFound = $false

        $script:ContainerSources.GetEnumerator() | 
            Microsoft.PowerShell.Core\Where-Object {$wildcardPattern.IsMatch($_.Key)} | 
                Microsoft.PowerShell.Core\ForEach-Object {

                    $moduleSource = $script:ContainerSources[$_.Key]

                    $packageSource = New-PackageSourceFromModuleSource -ModuleSource $moduleSource

                    Write-Output -InputObject $packageSource

                    $moduleSourceFound = $true
                }

        if(-not $moduleSourceFound)
        {
            $sourceName  = Get-SourceName -Location $moduleSourceName

            if($sourceName)
            {
                $moduleSource = $script:ContainerSources[$sourceName]

                $packageSource = New-PackageSourceFromModuleSource -ModuleSource $moduleSource

                Write-Output -InputObject $packageSource
            }
            
        }
    }
}

function New-PackageSourceFromModuleSource
{
    param
    (
        [Parameter(Mandatory=$true)]
        $ModuleSource
    )

    $packageSourceDetails = @{}

    # create a new package source
    $src =  New-PackageSource -Name $ModuleSource.Name `
                              -Location $ModuleSource.SourceLocation `
                              -Trusted $ModuleSource.Trusted `
                              -Registered $ModuleSource.Registered `
                              -Details $packageSourceDetails

    # return the package source object.
    Write-Output -InputObject $src
}

function Get-SourceName
{
    [CmdletBinding()]
    [OutputType("string")]
    Param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    Set-ModuleSourcesVariable

    foreach($psModuleSource in $script:ContainerSources.Values)
    {
        if(($psModuleSource.Name -eq $Location) -or
           ($psModuleSource.SourceLocation -eq $Location))
        {
            return $psModuleSource.Name
        }
    }
}

#endregion PackageSource Functions

#region Export
Export-ModuleMember -Function Find-Package, `
                              Download-Package, `
                              Install-Package, `
                              #Uninstall-Package, `
                              Get-InstalledPackage, `
                              Add-PackageSource, `
                              Remove-PackageSource, `
                              Resolve-PackageSource, `
                              Get-DynamicOptions, `
                              Initialize-Provider, `
                              Get-PackageProviderName, `
                              Find-ContainerImage, `
                              Save-ContainerImage, `
                              Install-ContainerImage
#endregion Export
# SIG # Begin signature block
# MIIarwYJKoZIhvcNAQcCoIIaoDCCGpwCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUeZYyYtB+epJhIde2uRjLxA7M
# tfmgghWCMIIEwzCCA6ugAwIBAgITMwAAAJFBzZF9mt4pKAAAAAAAkTANBgkqhkiG
# 9w0BAQUFADB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEw
# HwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EwHhcNMTUxMDA3MTgxNDEz
# WhcNMTcwMTA3MTgxNDEzWjCBszELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjENMAsGA1UECxMETU9QUjEnMCUGA1UECxMebkNpcGhlciBEU0UgRVNO
# OjMxQzUtMzBCQS03QzkxMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBT
# ZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmVaE3xcAAV2h
# NpvEDFT5W2hLuJfiGgOBERCO/Iqgo4M0ZJ+7x8WWG37cEspwDIphz7SxQpM+BbSH
# LYtOBM8IQqZSRLX0MzWHuE6so86xp0sOM0CJAVrtpFkCaSziBNrP3ZuRD81k90W6
# 6XCM4w5/1LfZ3mQPa7sXLDFRck37Smt9HGEsI/kP1MdrxuaJrqF04FYuPciWXMkf
# VYLHFkIc3eGulAf7pIT/ZnBsaj6j2wuAia35kFDYdwmPyo+ziUi+/6QM4GQ53SH4
# cMJdeJEyKgfA8utHMvmK7Ig3d4D010tvhze+e6gb6cavCxtrWFQLH40qcIApsc8d
# xjoCB8zOmwIDAQABo4IBCTCCAQUwHQYDVR0OBBYEFFTT1Ei5cvLc3VhV9CjTv38c
# KnX4MB8GA1UdIwQYMBaAFCM0+NlSRnAK7UD7dvuzK7DDNbMPMFQGA1UdHwRNMEsw
# SaBHoEWGQ2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY3Jvc29mdFRpbWVTdGFtcFBDQS5jcmwwWAYIKwYBBQUHAQEETDBKMEgGCCsG
# AQUFBzAChjxodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY3Jv
# c29mdFRpbWVTdGFtcFBDQS5jcnQwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZI
# hvcNAQEFBQADggEBAC5lnVnqeVPx+3JBHQ8x746y/99lbM9FBFvHHbY/GcIzm7sx
# 1JYPXIZAZ1PrwYJTpBXnBiYpxeYfSDfiFVegFm3zXIiyxxq4CuafGj0VHIWOKZK9
# TRczZl4paa8UJTXoh1rQsSOC+YSoRGcVmA9AczSKw3Mmcw0BJF4XhLsQZ1Uh7Mx0
# OyVE1zZDH9WwMEMKf8929mU7CKBGj4lzBo4gOUEOfpdRTtNHUvQ0DZedR0hbwsC5
# nEZWtuxfCsNf51l/nvSeXEpjpXE+DOtfunQsBetnWMe6647mXD7eWeANJ/0Mgp0V
# ciXLMx3Ivtx16M1GM7HfRKSMO8u4+ZLH5XRqGqYwggTsMIID1KADAgECAhMzAAAB
# Cix5rtd5e6asAAEAAAEKMA0GCSqGSIb3DQEBBQUAMHkxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xIzAhBgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBMB4XDTE1MDYwNDE3NDI0NVoXDTE2MDkwNDE3NDI0NVowgYMxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIx
# HjAcBgNVBAMTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJL8bza74QO5KNZG0aJhuqVG+2MWPi75R9LH7O3HmbEm
# UXW92swPBhQRpGwZnsBfTVSJ5E1Q2I3NoWGldxOaHKftDXT3p1Z56Cj3U9KxemPg
# 9ZSXt+zZR/hsPfMliLO8CsUEp458hUh2HGFGqhnEemKLwcI1qvtYb8VjC5NJMIEb
# e99/fE+0R21feByvtveWE1LvudFNOeVz3khOPBSqlw05zItR4VzRO/COZ+owYKlN
# Wp1DvdsjusAP10sQnZxN8FGihKrknKc91qPvChhIqPqxTqWYDku/8BTzAMiwSNZb
# /jjXiREtBbpDAk8iAJYlrX01boRoqyAYOCj+HKIQsaUCAwEAAaOCAWAwggFcMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBSJ/gox6ibN5m3HkZG5lIyiGGE3
# NDBRBgNVHREESjBIpEYwRDENMAsGA1UECxMETU9QUjEzMDEGA1UEBRMqMzE1OTUr
# MDQwNzkzNTAtMTZmYS00YzYwLWI2YmYtOWQyYjFjZDA1OTg0MB8GA1UdIwQYMBaA
# FMsR6MrStBZYAck3LjMWFrlMmgofMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9j
# cmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY0NvZFNpZ1BDQV8w
# OC0zMS0yMDEwLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljQ29kU2lnUENBXzA4LTMx
# LTIwMTAuY3J0MA0GCSqGSIb3DQEBBQUAA4IBAQCmqFOR3zsB/mFdBlrrZvAM2PfZ
# hNMAUQ4Q0aTRFyjnjDM4K9hDxgOLdeszkvSp4mf9AtulHU5DRV0bSePgTxbwfo/w
# iBHKgq2k+6apX/WXYMh7xL98m2ntH4LB8c2OeEti9dcNHNdTEtaWUu81vRmOoECT
# oQqlLRacwkZ0COvb9NilSTZUEhFVA7N7FvtH/vto/MBFXOI/Enkzou+Cxd5AGQfu
# FcUKm1kFQanQl56BngNb/ErjGi4FrFBHL4z6edgeIPgF+ylrGBT6cgS3C6eaZOwR
# XU9FSY0pGi370LYJU180lOAWxLnqczXoV+/h6xbDGMcGszvPYYTitkSJlKOGMIIF
# vDCCA6SgAwIBAgIKYTMmGgAAAAAAMTANBgkqhkiG9w0BAQUFADBfMRMwEQYKCZIm
# iZPyLGQBGRYDY29tMRkwFwYKCZImiZPyLGQBGRYJbWljcm9zb2Z0MS0wKwYDVQQD
# EyRNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwHhcNMTAwODMx
# MjIxOTMyWhcNMjAwODMxMjIyOTMyWjB5MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSMwIQYDVQQDExpNaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBD
# QTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJyWVwZMGS/HZpgICBC
# mXZTbD4b1m/My/Hqa/6XFhDg3zp0gxq3L6Ay7P/ewkJOI9VyANs1VwqJyq4gSfTw
# aKxNS42lvXlLcZtHB9r9Jd+ddYjPqnNEf9eB2/O98jakyVxF3K+tPeAoaJcap6Vy
# c1bxF5Tk/TWUcqDWdl8ed0WDhTgW0HNbBbpnUo2lsmkv2hkL/pJ0KeJ2L1TdFDBZ
# +NKNYv3LyV9GMVC5JxPkQDDPcikQKCLHN049oDI9kM2hOAaFXE5WgigqBTK3S9dP
# Y+fSLWLxRT3nrAgA9kahntFbjCZT6HqqSvJGzzc8OJ60d1ylF56NyxGPVjzBrAlf
# A9MCAwEAAaOCAV4wggFaMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFMsR6MrS
# tBZYAck3LjMWFrlMmgofMAsGA1UdDwQEAwIBhjASBgkrBgEEAYI3FQEEBQIDAQAB
# MCMGCSsGAQQBgjcVAgQWBBT90TFO0yaKleGYYDuoMW+mPLzYLTAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAfBgNVHSMEGDAWgBQOrIJgQFYnl+UlE/wq4QpTlVnk
# pDBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9taWNyb3NvZnRyb290Y2VydC5jcmwwVAYIKwYBBQUHAQEE
# SDBGMEQGCCsGAQUFBzAChjhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2Nl
# cnRzL01pY3Jvc29mdFJvb3RDZXJ0LmNydDANBgkqhkiG9w0BAQUFAAOCAgEAWTk+
# fyZGr+tvQLEytWrrDi9uqEn361917Uw7LddDrQv+y+ktMaMjzHxQmIAhXaw9L0y6
# oqhWnONwu7i0+Hm1SXL3PupBf8rhDBdpy6WcIC36C1DEVs0t40rSvHDnqA2iA6VW
# 4LiKS1fylUKc8fPv7uOGHzQ8uFaa8FMjhSqkghyT4pQHHfLiTviMocroE6WRTsgb
# 0o9ylSpxbZsa+BzwU9ZnzCL/XB3Nooy9J7J5Y1ZEolHN+emjWFbdmwJFRC9f9Nqu
# 1IIybvyklRPk62nnqaIsvsgrEA5ljpnb9aL6EiYJZTiU8XofSrvR4Vbo0HiWGFzJ
# NRZf3ZMdSY4tvq00RBzuEBUaAF3dNVshzpjHCe6FDoxPbQ4TTj18KUicctHzbMrB
# 7HCjV5JXfZSNoBtIA1r3z6NnCnSlNu0tLxfI5nI3EvRvsTxngvlSso0zFmUeDord
# EN5k9G/ORtTTF+l5xAS00/ss3x+KnqwK+xMnQK3k+eGpf0a7B2BHZWBATrBC7E7t
# s3Z52Ao0CW0cgDEf4g5U3eWh++VHEK1kmP9QFi58vwUheuKVQSdpw5OPlcmN2Jsh
# rg1cnPCiroZogwxqLbt2awAdlq3yFnv2FoMkuYjPaqhHMS+a3ONxPdcAfmJH0c6I
# ybgY+g5yjcGjPa8CQGr/aZuW4hCoELQ3UAjWwz0wggYHMIID76ADAgECAgphFmg0
# AAAAAAAcMA0GCSqGSIb3DQEBBQUAMF8xEzARBgoJkiaJk/IsZAEZFgNjb20xGTAX
# BgoJkiaJk/IsZAEZFgltaWNyb3NvZnQxLTArBgNVBAMTJE1pY3Jvc29mdCBSb290
# IENlcnRpZmljYXRlIEF1dGhvcml0eTAeFw0wNzA0MDMxMjUzMDlaFw0yMTA0MDMx
# MzAzMDlaMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xITAf
# BgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQTCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJ+hbLHf20iSKnxrLhnhveLjxZlRI1Ctzt0YTiQP7tGn
# 0UytdDAgEesH1VSVFUmUG0KSrphcMCbaAGvoe73siQcP9w4EmPCJzB/LMySHnfL0
# Zxws/HvniB3q506jocEjU8qN+kXPCdBer9CwQgSi+aZsk2fXKNxGU7CG0OUoRi4n
# rIZPVVIM5AMs+2qQkDBuh/NZMJ36ftaXs+ghl3740hPzCLdTbVK0RZCfSABKR2YR
# JylmqJfk0waBSqL5hKcRRxQJgp+E7VV4/gGaHVAIhQAQMEbtt94jRrvELVSfrx54
# QTF3zJvfO4OToWECtR0Nsfz3m7IBziJLVP/5BcPCIAsCAwEAAaOCAaswggGnMA8G
# A1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFCM0+NlSRnAK7UD7dvuzK7DDNbMPMAsG
# A1UdDwQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADCBmAYDVR0jBIGQMIGNgBQOrIJg
# QFYnl+UlE/wq4QpTlVnkpKFjpGEwXzETMBEGCgmSJomT8ixkARkWA2NvbTEZMBcG
# CgmSJomT8ixkARkWCW1pY3Jvc29mdDEtMCsGA1UEAxMkTWljcm9zb2Z0IFJvb3Qg
# Q2VydGlmaWNhdGUgQXV0aG9yaXR5ghB5rRahSqClrUxzWPQHEy5lMFAGA1UdHwRJ
# MEcwRaBDoEGGP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL21pY3Jvc29mdHJvb3RjZXJ0LmNybDBUBggrBgEFBQcBAQRIMEYwRAYIKwYB
# BQUHMAKGOGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljcm9z
# b2Z0Um9vdENlcnQuY3J0MBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEB
# BQUAA4ICAQAQl4rDXANENt3ptK132855UU0BsS50cVttDBOrzr57j7gu1BKijG1i
# uFcCy04gE1CZ3XpA4le7r1iaHOEdAYasu3jyi9DsOwHu4r6PCgXIjUji8FMV3U+r
# kuTnjWrVgMHmlPIGL4UD6ZEqJCJw+/b85HiZLg33B+JwvBhOnY5rCnKVuKE5nGct
# xVEO6mJcPxaYiyA/4gcaMvnMMUp2MT0rcgvI6nA9/4UKE9/CCmGO8Ne4F+tOi3/F
# NSteo7/rvH0LQnvUU3Ih7jDKu3hlXFsBFwoUDtLaFJj1PLlmWLMtL+f5hYbMUVbo
# nXCUbKw5TNT2eb+qGHpiKe+imyk0BncaYsk9Hm0fgvALxyy7z0Oz5fnsfbXjpKh0
# NbhOxXEjEiZ2CzxSjHFaRkMUvLOzsE1nyJ9C/4B5IYCeFTBm6EISXhrIniIh0EPp
# K+m79EjMLNTYMoBMJipIJF9a6lbvpt6Znco6b72BJ3QGEe52Ib+bgsEnVLaxaj2J
# oXZhtG6hE6a/qkfwEm/9ijJssv7fUciMI8lmvZ0dhxJkAj0tr1mPuOQh5bWwymO0
# eFQF1EEuUKyUsKV4q7OglnUa2ZKHE3UiLzKoCG6gW4wlv6DvhMoh1useT8ma7kng
# 9wFlb4kLfchpyOZu6qeXzjEp/w7FW1zYTRuh2Povnj8uVRZryROj/TGCBJcwggST
# AgEBMIGQMHkxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xIzAh
# BgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBAhMzAAABCix5rtd5e6as
# AAEAAAEKMAkGBSsOAwIaBQCggbAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFMpm
# gPF2crSBGcWPVuYWHwlVxOnxMFAGCisGAQQBgjcCAQwxQjBAoBaAFABQAG8AdwBl
# AHIAUwBoAGUAbABsoSaAJGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9Qb3dlclNo
# ZWxsIDANBgkqhkiG9w0BAQEFAASCAQBauPkUVw1AHBua5KWUq98XAZDH2lHHqvqp
# fAV0fs0nMh0bkXGM9K2fH6Ll0b3EN735WETLlCUbItK0WYDV2EnCodoU0dkhZisW
# h5sni2z63WL7jEwlx7h8zvy3CmrHvaBj3GUQMTQT0gOHAle3NntD634R9L/pIYL9
# GFTTsfhHeQgTmXeuD9Uz/lrtXlRVXkO3+SP+WOyYWY6AuEuqAj/IrYfWPXatUccu
# Blt4gBa7DUyYXM9Bixso+1APEdjZZouech2QTIbsdf/6gHmNTqFp0kB+mo1e6Cbo
# EggSWZmHQZmABpGevA9iiTQ2ZNrI5qHea7OkuynEFJjRaVd6UoO3oYICKDCCAiQG
# CSqGSIb3DQEJBjGCAhUwggIRAgEBMIGOMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xITAfBgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QQITMwAAAJFBzZF9mt4pKAAAAAAAkTAJBgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMTYwNDA1MDAzMjU4WjAjBgkq
# hkiG9w0BCQQxFgQU1UTBwmQQuGYOUGo0RZ26q4B4bscwDQYJKoZIhvcNAQEFBQAE
# ggEAJstyc4b8nncivajflpOej3zQwO/NlIIedCqLOlnaqomamq983QCSKnyhlEmn
# vUfz1PyIZihxid/PxSrQ9E6lNoXZBFOn3IYnVTscET4ie3G0HGm9MvtahRZjhdwU
# SQQ7ctDCkBuFfjdmUZfkHO+YoTvwCGITdDNB75NgjwvbZoY1cWGvZShZzvM/9RP7
# E7v05goplAWlYNifGrtjWCURLYEbMX7iHsXG4uxlY+CSUITAp2p5gHygPrcOiC8X
# UzQ7BmxTPYfI8sa2MhKdLPkSEAmSsyEZqCPKx1UJfhgRYM8DqgIxG8v1zPa9uLbN
# Jqhul65VdoS8H9ciy+RGN54hOA==
# SIG # End signature block
