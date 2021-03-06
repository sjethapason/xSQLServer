$script:currentPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
Import-Module -Name (Join-Path -Path (Split-Path -Path (Split-Path -Path $script:currentPath -Parent) -Parent) -ChildPath 'xSQLServerHelper.psm1')
Import-Module -Name (Join-Path -Path (Split-Path -Path (Split-Path -Path $script:currentPath -Parent) -Parent) -ChildPath 'xPDT.psm1')

<#
    .SYNOPSIS
        Returns the current state of the SQL Server features.

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource.  Environment variables can be used in the path.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath`. Using this parameter will trigger a copy
        of the installation media to a temp folder on the target node. Setup will then be started from the temp folder on the target node.
        For any subsequent calls to the resource, the parameter `SourceCredential` is used to evaluate what major version the file 'setup.exe'
        has in the path set, again, by the parameter `SourcePath`.
        If the path, that is assigned to parameter `SourcePath`, contains a leaf folder, for example '\\server\share\folder', then that leaf
        folder will be used as the name of the temporary folder. If the path, that is assigned to parameter `SourcePath`, does not have a
        leaf folder, for example '\\server\share', then a unique guid will be used as the name of the temporary folder.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.
#>
function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter()]
        [System.String]
        $SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [Parameter(Mandatory = $true)]
        [System.String]
        $InstanceName
    )

    $InstanceName = $InstanceName.ToUpper()

    $SourcePath = [Environment]::ExpandEnvironmentVariables($SourcePath)

    if ($SourceCredential)
    {
        $newSmbMappingParameters = @{
            RemotePath = $SourcePath
            UserName = "$($SourceCredential.GetNetworkCredential().Domain)\$($SourceCredential.GetNetworkCredential().UserName)"
            Password = $($SourceCredential.GetNetworkCredential().Password)
        }

        $null = New-SmbMapping @newSmbMappingParameters
    }

    $pathToSetupExecutable = Join-Path -Path $SourcePath -ChildPath 'setup.exe'

    New-VerboseMessage -Message "Using path: $pathToSetupExecutable"

    $sqlVersion = Get-SqlMajorVersion -Path $pathToSetupExecutable

    if ($SourceCredential)
    {
        Remove-SmbMapping -RemotePath $SourcePath -Force
    }

    if ($InstanceName -eq 'MSSQLSERVER')
    {
        $databaseServiceName = 'MSSQLSERVER'
        $agentServiceName = 'SQLSERVERAGENT'
        $fullTextServiceName = 'MSSQLFDLauncher'
        $reportServiceName = 'ReportServer'
        $analysisServiceName = 'MSSQLServerOLAPService'
    }
    else
    {
        $databaseServiceName = "MSSQL`$$InstanceName"
        $agentServiceName = "SQLAgent`$$InstanceName"
        $fullTextServiceName = "MSSQLFDLauncher`$$InstanceName"
        $reportServiceName = "ReportServer`$$InstanceName"
        $analysisServiceName = "MSOLAP`$$InstanceName"
    }

    $integrationServiceName = "MsDtsServer$($sqlVersion)0"

    $features = ''
    $clusteredSqlGroupName = ''
    $clusteredSqlHostname = ''
    $clusteredSqlIPAddress = ''

    $services = Get-Service
    if ($services | Where-Object {$_.Name -eq $databaseServiceName})
    {
        $features += 'SQLENGINE,'

        $sqlServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$databaseServiceName'").StartName
        $agentServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$agentServiceName'").StartName

        $fullInstanceId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -Name $InstanceName).$InstanceName

        # Check if Replication sub component is configured for this instance
        New-VerboseMessage -Message "Detecting replication feature (HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\ConfigurationState)"
        $isReplicationInstalled = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\ConfigurationState").SQL_Replication_Core_Inst
        if ($isReplicationInstalled -eq 1)
        {
            New-VerboseMessage -Message 'Replication feature detected'
            $Features += 'REPLICATION,'
        }
        else
        {
            New-VerboseMessage -Message 'Replication feature not detected'
        }

        $instanceId = $fullInstanceId.Split('.')[1]
        $instanceDirectory = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\Setup" -Name 'SqlProgramDir').SqlProgramDir.Trim("\")

        $databaseServer = Connect-SQL -SQLServer 'localhost' -SQLInstanceName $InstanceName

        $sqlCollation = $databaseServer.Collation

        $sqlSystemAdminAccounts = @()
        foreach ($sqlUser in $databaseServer.Logins)
        {
            foreach ($sqlRole in $sqlUser.ListMembers())
            {
                if ($sqlRole -like 'sysadmin')
                {
                    $sqlSystemAdminAccounts += $sqlUser.Name
                }
            }
        }

        if ($databaseServer.LoginMode -eq 'Mixed')
        {
            $securityMode = 'SQL'
        }
        else
        {
            $securityMode = 'Windows'
        }

        $installSQLDataDirectory = $databaseServer.InstallDataDirectory
        $sqlUserDatabaseDirectory = $databaseServer.DefaultFile
        $sqlUserDatabaseLogDirectory = $databaseServer.DefaultLog
        $sqlBackupDirectory = $databaseServer.BackupDirectory

        if ($databaseServer.IsClustered)
        {
            New-VerboseMessage -Message 'Clustered instance detected'

            $clusteredSqlInstance = Get-CimInstance -Namespace root/MSCluster -ClassName MSCluster_Resource -Filter "Type = 'SQL Server'" |
                Where-Object { $_.PrivateProperties.InstanceName -eq $InstanceName }

            if (!$clusteredSqlInstance)
            {
                throw New-TerminatingError -ErrorType FailoverClusterResourceNotFound -FormatArgs $InstanceName -ErrorCategory 'ObjectNotFound'
            }

            New-VerboseMessage -Message 'Clustered SQL Server resource located'

            $clusteredSqlGroup = $clusteredSqlInstance | Get-CimAssociatedInstance -ResultClassName MSCluster_ResourceGroup
            $clusteredSqlNetworkName = $clusteredSqlGroup | Get-CimAssociatedInstance -ResultClassName MSCluster_Resource | 
                Where-Object { $_.Type -eq "Network Name" }

            $clusteredSqlIPAddress = ($clusteredSqlNetworkName | Get-CimAssociatedInstance -ResultClassName MSCluster_Resource |
                Where-Object { $_.Type -eq "IP Address" }).PrivateProperties.Address

            # Extract the required values
            $clusteredSqlGroupName = $clusteredSqlGroup.Name
            $clusteredSqlHostname = $clusteredSqlNetworkName.PrivateProperties.DnsName
        }
        else 
        {
            New-VerboseMessage -Message 'Clustered instance not detected'
        }
    }

    if ($services | Where-Object {$_.Name -eq $fullTextServiceName})
    {
        $features += 'FULLTEXT,'
        $fulltextServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$fullTextServiceName'").StartName
    }

    if ($services | Where-Object {$_.Name -eq $reportServiceName})
    {
        $features += 'RS,'
        $reportingServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$reportServiceName'").StartName
    }

    if ($services | Where-Object {$_.Name -eq $analysisServiceName})
    {
        $features += 'AS,'
        $analysisServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$analysisServiceName'").StartName

        $analysisServer = Connect-SQLAnalysis -SQLServer localhost -SQLInstanceName $InstanceName

        $analysisCollation = $analysisServer.ServerProperties['CollationName'].Value
        $analysisDataDirectory = $analysisServer.ServerProperties['DataDir'].Value
        $analysisTempDirectory = $analysisServer.ServerProperties['TempDir'].Value
        $analysisLogDirectory = $analysisServer.ServerProperties['LogDir'].Value
        $analysisBackupDirectory = $analysisServer.ServerProperties['BackupDir'].Value

        $analysisSystemAdminAccounts = $analysisServer.Roles['Administrators'].Members.Name

        $analysisConfigDirectory = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$analysisServiceName" -Name 'ImagePath').ImagePath.Replace(' -s ',',').Split(',')[1].Trim('"')
    }

    if ($services | Where-Object {$_.Name -eq $integrationServiceName})
    {
        $features += 'IS,'
        $integrationServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$integrationServiceName'").StartName
    }

    $registryUninstallPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'

    # Verify if SQL Server Management Studio 2008 or SQL Server Management Studio 2008 R2 (major version 10) is installed
    $installedProductSqlServerManagementStudio2008R2 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{72AB7E6F-BC24-481E-8C45-1AB5B3DD795D}'
    ) -ErrorAction SilentlyContinue

    # Verify if SQL Server Management Studio 2012 (major version 11) is installed
    $installedProductSqlServerManagementStudio2012 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{A7037EB2-F953-4B12-B843-195F4D988DA1}'
    ) -ErrorAction SilentlyContinue

    # Verify if SQL Server Management Studio 2014 (major version 12) is installed
    $installedProductSqlServerManagementStudio2014 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{75A54138-3B98-4705-92E4-F619825B121F}'
    ) -ErrorAction SilentlyContinue

    if (
        ($sqlVersion -eq 10 -and $installedProductSqlServerManagementStudio2008R2) -or
        ($sqlVersion -eq 11 -and $installedProductSqlServerManagementStudio2012) -or
        ($sqlVersion -eq 12 -and $installedProductSqlServerManagementStudio2014)
        )
    {
        $features += 'SSMS,'
    }

    # Evaluating if SQL Server Management Studio Advanced 2008  or SQL Server Management Studio Advanced 2008 R2 (major version 10) is installed
    $installedProductSqlServerManagementStudioAdvanced2008R2 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{B5FE23CC-0151-4595-84C3-F1DE6F44FE9B}'
    ) -ErrorAction SilentlyContinue

    # Evaluating if SQL Server Management Studio Advanced 2012 (major version 11) is installed
    $installedProductSqlServerManagementStudioAdvanced2012 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{7842C220-6E9A-4D5A-AE70-0E138271F883}'
    ) -ErrorAction SilentlyContinue

    # Evaluating if SQL Server Management Studio Advanced 2014 (major version 12) is installed
    $installedProductSqlServerManagementStudioAdvanced2014 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{B5ECFA5C-AC4F-45A4-A12E-A76ABDD9CCBA}'
    ) -ErrorAction SilentlyContinue

    if (
        ($sqlVersion -eq 10 -and $installedProductSqlServerManagementStudioAdvanced2008R2) -or
        ($sqlVersion -eq 11 -and $installedProductSqlServerManagementStudioAdvanced2012) -or
        ($sqlVersion -eq 12 -and $installedProductSqlServerManagementStudioAdvanced2014)
        )
    {
        $features += 'ADV_SSMS,'
    }

    $features = $features.Trim(',')
    if ($features -ne '')
    {
        $registryInstallerComponentsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'

        switch ($sqlVersion)
        {
            '10'
            {
                $registryKeySharedDir = '0D1F366D0FE0E404F8C15EE4F1C15094'
                $registryKeySharedWOWDir = 'C90BFAC020D87EA46811C836AD3C507F'
            }

            '11'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'A79497A344129F64CA7D69C56F5DD8B4'
            }

            '12'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'C90BFAC020D87EA46811C836AD3C507F'
            }

            '13'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'A79497A344129F64CA7D69C56F5DD8B4'
            }
        }

        if ($registryKeySharedDir)
        {
            $installSharedDir = Get-FirstItemPropertyValue -Path (Join-Path -Path $registryInstallerComponentsPath -ChildPath $registryKeySharedDir)
        }

        if ($registryKeySharedWOWDir)
        {
            $installSharedWOWDir = Get-FirstItemPropertyValue -Path (Join-Path -Path $registryInstallerComponentsPath -ChildPath $registryKeySharedWOWDir)
        }
    }

    return @{
        SourcePath = $SourcePath
        Features = $features
        InstanceName = $InstanceName
        InstanceID = $instanceID
        InstallSharedDir = $installSharedDir
        InstallSharedWOWDir = $installSharedWOWDir
        InstanceDir = $instanceDirectory
        SQLSvcAccountUsername = $sqlServiceAccountUsername
        AgtSvcAccountUsername = $agentServiceAccountUsername
        SQLCollation = $sqlCollation
        SQLSysAdminAccounts = $sqlSystemAdminAccounts
        SecurityMode = $securityMode
        InstallSQLDataDir = $installSQLDataDirectory
        SQLUserDBDir = $sqlUserDatabaseDirectory
        SQLUserDBLogDir = $sqlUserDatabaseLogDirectory
        SQLTempDBDir = $null
        SQLTempDBLogDir = $null
        SQLBackupDir = $sqlBackupDirectory
        FTSvcAccountUsername = $fulltextServiceAccountUsername
        RSSvcAccountUsername = $reportingServiceAccountUsername
        ASSvcAccountUsername = $analysisServiceAccountUsername
        ASCollation = $analysisCollation
        ASSysAdminAccounts = $analysisSystemAdminAccounts
        ASDataDir = $analysisDataDirectory
        ASLogDir = $analysisLogDirectory
        ASBackupDir = $analysisBackupDirectory
        ASTempDir = $analysisTempDirectory
        ASConfigDir = $analysisConfigDirectory
        ISSvcAccountUsername = $integrationServiceAccountUsername
        FailoverClusterGroupName = $clusteredSqlGroupName
        FailoverClusterNetworkName = $clusteredSqlHostname
        FailoverClusterIPAddress = $clusteredSqlIPAddress
    }
}

<#
    .SYNOPSIS
        Installs the SQL Server features to the node.

    .PARAMETER Action
        The action to be performed. Default value is 'Install'.
        Possible values are 'Install', 'InstallFailoverCluster', 'AddNode', 'PrepareFailoverCluster', and 'CompleteFailoverCluster'

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource. Environment variables can be used in the path.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath`. Using this parameter will trigger a copy
        of the installation media to a temp folder on the target node. Setup will then be started from the temp folder on the target node.
        For any subsequent calls to the resource, the parameter `SourceCredential` is used to evaluate what major version the file 'setup.exe'
        has in the path set, again, by the parameter `SourcePath`.
        If the path, that is assigned to parameter `SourcePath`, contains a leaf folder, for example '\\server\share\folder', then that leaf
        folder will be used as the name of the temporary folder. If the path, that is assigned to parameter `SourcePath`, does not have a
        leaf folder, for example '\\server\share', then a unique guid will be used as the name of the temporary folder.

    .PARAMETER SuppressReboot
        Suppressed reboot.

    .PARAMETER ForceReboot
        Forces reboot.

    .PARAMETER Features
        SQL features to be installed.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.

    .PARAMETER InstanceID
        SQL instance ID, if different from InstanceName.

    .PARAMETER PID
        Product key for licensed installations.

    .PARAMETER UpdateEnabled
        Enabled updates during installation.

    .PARAMETER UpdateSource
        Path to the source of updates to be applied during installation.

    .PARAMETER SQMReporting
        Enable customer experience reporting.

    .PARAMETER ErrorReporting
        Enable error reporting.

    .PARAMETER InstallSharedDir
        Installation path for shared SQL files.

    .PARAMETER InstallSharedWOWDir
        Installation path for x86 shared SQL files.

    .PARAMETER InstanceDir
        Installation path for SQL instance files.

    .PARAMETER SQLSvcAccount
        Service account for the SQL service.

    .PARAMETER AgtSvcAccount
        Service account for the SQL Agent service.

    .PARAMETER SQLCollation
        Collation for SQL.

    .PARAMETER SQLSysAdminAccounts
        Array of accounts to be made SQL administrators.

    .PARAMETER SecurityMode
        Security mode to apply to the SQL Server instance.

    .PARAMETER SAPwd
        SA password, if SecurityMode is set to 'SQL'.

    .PARAMETER InstallSQLDataDir
        Root path for SQL database files.

    .PARAMETER SQLUserDBDir
        Path for SQL database files.

    .PARAMETER SQLUserDBLogDir
        Path for SQL log files.

    .PARAMETER SQLTempDBDir
        Path for SQL TempDB files.

    .PARAMETER SQLTempDBLogDir
        Path for SQL TempDB log files.

    .PARAMETER SQLBackupDir
        Path for SQL backup files.

    .PARAMETER FTSvcAccount
        Service account for the Full Text service.

    .PARAMETER RSSvcAccount
        Service account for Reporting Services service.

    .PARAMETER ASSvcAccount
       Service account for Analysis Services service.

    .PARAMETER ASCollation
        Collation for Analysis Services.

    .PARAMETER ASSysAdminAccounts
        Array of accounts to be made Analysis Services admins.

    .PARAMETER ASDataDir
        Path for Analysis Services data files.

    .PARAMETER ASLogDir
        Path for Analysis Services log files.

    .PARAMETER ASBackupDir
        Path for Analysis Services backup files.

    .PARAMETER ASTempDir
        Path for Analysis Services temp files.

    .PARAMETER ASConfigDir
        Path for Analysis Services config.

    .PARAMETER ISSvcAccount
       Service account for Integration Services service.

    .PARAMETER BrowserSvcStartupType
       Specifies the startup mode for SQL Server Browser service

    .PARAMETER FailoverClusterGroupName
        The name of the resource group to create for the clustered SQL Server instance

    .PARAMETER FailoverClusterIPAddress
        Array of IP Addresses to be assigned to the clustered SQL Server instance

    .PARAMETER FailoverClusterNetworkName
        Host name to be assigned to the clustered SQL Server instance
#>
function Set-TargetResource
{
    # Suppressing this rule because $global:DSCMachineStatus is used to trigger a reboot, either by force or when there are pending changes.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
    [CmdletBinding()]
    param
    (
        [ValidateSet('Install','InstallFailoverCluster','AddNode','PrepareFailoverCluster','CompleteFailoverCluster')]
        [System.String]
        $Action = 'Install',

        [System.String]
        $SourcePath,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [System.Boolean]
        $SuppressReboot,

        [System.Boolean]
        $ForceReboot,

        [System.String]
        $Features,

        [parameter(Mandatory = $true)]
        [System.String]
        $InstanceName,

        [System.String]
        $InstanceID,

        [System.String]
        $PID,

        [System.String]
        $UpdateEnabled,

        [System.String]
        $UpdateSource,

        [System.String]
        $SQMReporting,

        [System.String]
        $ErrorReporting,

        [System.String]
        $InstallSharedDir,

        [System.String]
        $InstallSharedWOWDir,

        [System.String]
        $InstanceDir,

        [System.Management.Automation.PSCredential]
        $SQLSvcAccount,

        [System.Management.Automation.PSCredential]
        $AgtSvcAccount,

        [System.String]
        $SQLCollation,

        [System.String[]]
        $SQLSysAdminAccounts,

        [System.String]
        $SecurityMode,

        [System.Management.Automation.PSCredential]
        $SAPwd,

        [System.String]
        $InstallSQLDataDir,

        [System.String]
        $SQLUserDBDir,

        [System.String]
        $SQLUserDBLogDir,

        [System.String]
        $SQLTempDBDir,

        [System.String]
        $SQLTempDBLogDir,

        [System.String]
        $SQLBackupDir,

        [System.Management.Automation.PSCredential]
        $FTSvcAccount,

        [System.Management.Automation.PSCredential]
        $RSSvcAccount,

        [System.Management.Automation.PSCredential]
        $ASSvcAccount,

        [System.String]
        $ASCollation,

        [System.String[]]
        $ASSysAdminAccounts,

        [System.String]
        $ASDataDir,

        [System.String]
        $ASLogDir,

        [System.String]
        $ASBackupDir,

        [System.String]
        $ASTempDir,

        [System.String]
        $ASConfigDir,

        [System.Management.Automation.PSCredential]
        $ISSvcAccount,

        [System.String]
        [ValidateSet('Automatic', 'Disabled', 'Manual')]
        $BrowserSvcStartupType,

        [System.String]
        $FailoverClusterGroupName = "SQL Server ($InstanceName)",

        [System.String[]]
        $FailoverClusterIPAddress,

        [System.String]
        $FailoverClusterNetworkName
    )

    $parameters = @{
        SourcePath = $SourcePath
        SetupCredential = $SetupCredential
        SourceCredential = $SourceCredential
        InstanceName = $InstanceName
    }

    $getTargetResourceResult = Get-TargetResource @parameters

    $InstanceName = $InstanceName.ToUpper()

    $SourcePath = [Environment]::ExpandEnvironmentVariables($SourcePath)

    if ($SourceCredential)
    {
        $newSmbMappingParameters = @{
            RemotePath = $SourcePath
            UserName = "$($SourceCredential.GetNetworkCredential().Domain)\$($SourceCredential.GetNetworkCredential().UserName)"
            Password = $($SourceCredential.GetNetworkCredential().Password)
        }

        $null = New-SmbMapping @newSmbMappingParameters

        # Create a destination folder so the media files aren't written to the root of the Temp folder.
        $mediaDestinationFolder = Split-Path -Path $SourcePath -Leaf
        if (-not $mediaDestinationFolder )
        {
            $mediaDestinationFolder = New-Guid | Select-Object -ExpandProperty Guid
        }

        $mediaDestinationPath = Join-Path -Path (Get-TemporaryFolder) -ChildPath $mediaDestinationFolder

        New-VerboseMessage -Message "Robocopy is copying media from source '$SourcePath' to destination '$mediaDestinationPath'"
        Copy-ItemWithRoboCopy -Path $SourcePath -DestinationPath $mediaDestinationPath

        Remove-SmbMapping -RemotePath $SourcePath -Force

        $SourcePath = $mediaDestinationPath
    }

    $pathToSetupExecutable = Join-Path -Path $SourcePath -ChildPath 'setup.exe'

    New-VerboseMessage -Message "Using path: $pathToSetupExecutable"

    $sqlVersion = Get-SqlMajorVersion -Path $pathToSetupExecutable

    # Determine features to install
    $featuresToInstall = ""
    foreach ($feature in $Features.Split(","))
    {
        # Given that all the returned features are uppercase, make sure that the feature to search for is also uppercase
        $feature = $feature.ToUpper();

        if (($sqlVersion -eq '13') -and (($feature -eq 'SSMS') -or ($feature -eq 'ADV_SSMS')))
        {
            Throw New-TerminatingError -ErrorType FeatureNotSupported -FormatArgs @($feature) -ErrorCategory InvalidData
        }

        if (!($getTargetResourceResult.Features.Contains($feature)))
        {
            $featuresToInstall += "$feature,"
        }
    }

    $Features = $featuresToInstall.Trim(',')

    # If SQL shared components already installed, clear InstallShared*Dir variables
    switch ($sqlVersion)
    {
        '10'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\0D1F366D0FE0E404F8C15EE4F1C15094' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\C90BFAC020D87EA46811C836AD3C507F' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '11'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\30AE1F084B1CF8B4797ECB3CCAA3B3B6' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\A79497A344129F64CA7D69C56F5DD8B4' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '12'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\FEE2E540D20152D4597229B6CFBC0A69' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\C90BFAC020D87EA46811C836AD3C507F' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '13'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\FEE2E540D20152D4597229B6CFBC0A69' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\A79497A344129F64CA7D69C56F5DD8B4' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }
    }

    # Remove trailing "\" from paths
    foreach ($var in @(
        'InstallSQLDataDir',
        'SQLUserDBDir',
        'SQLUserDBLogDir',
        'SQLTempDBDir',
        'SQLTempDBLogDir',
        'SQLBackupDir',
        'ASDataDir',
        'ASLogDir',
        'ASBackupDir',
        'ASTempDir',
        'ASConfigDir')
    )
    {
        if (Get-Variable -Name $var -ErrorAction SilentlyContinue)
        {
            Set-Variable -Name $var -Value (Get-Variable -Name $var).Value.TrimEnd('\')
        }
    }

    $setupArguments = @{}

    if ($Action -in @('PrepareFailoverCluster','CompleteFailoverCluster','InstallFailoverCluster','AddNode'))
    {
        # Set the group name for this clustered instance.
        $setupArguments += @{ 
            FailoverClusterGroup = $FailoverClusterGroupName

            # This was brought over from the old module. Should be removed (breaking change).
            SkipRules = 'Cluster_VerifyForErrors'
        }
    }

    # Perform disk mapping for specific cluster installation types
    if ($Action -in @('CompleteFailoverCluster','InstallFailoverCluster'))
    {
        $failoverClusterDisks = @()

        # Get a required lising of drives based on user parameters
        $requiredDrives = Get-Variable -Name 'SQL*Dir' -ValueOnly | Where-Object { -not [String]::IsNullOrEmpty($_) } | Split-Path -Qualifier | Sort-Object -Unique

        # Get the disk resources that are available (not assigned to a cluster role)
        $availableStorage = Get-CimInstance -Namespace 'root/MSCluster' -ClassName 'MSCluster_ResourceGroup' -Filter "Name = 'Available Storage'" |
                                Get-CimAssociatedInstance -Association MSCluster_ResourceGroupToResource -ResultClassName MSCluster_Resource

        foreach ($diskResource in $availableStorage)
        {
            # Determine whether the current node is a possible owner of the disk resource
            $possibleOwners = $diskResource | Get-CimAssociatedInstance -Association 'MSCluster_ResourceToPossibleOwner' -KeyOnly | Select-Object -ExpandProperty Name

            if ($possibleOwners -icontains $env:COMPUTERNAME)
            {
                # Determine whether this disk contains one of our required partitions
                if ($requiredDrives -icontains ($diskResource | Get-CimAssociatedInstance -ResultClassName 'MSCluster_DiskPartition' | Select-Object -ExpandProperty Path))
                {
                    $failoverClusterDisks += $diskResource.Name
                }
            }
        }

        # Ensure we have a unique listing of disks
        $failoverClusterDisks = $failoverClusterDisks | Sort-Object -Unique

        # Ensure we mapped all required drives
        $requiredDriveCount = $requiredDrives.Count
        $mappedDriveCount = $failoverClusterDisks.Count

        if ($mappedDriveCount -ne $requiredDriveCount)
        {
            throw New-TerminatingError -ErrorType FailoverClusterDiskMappingError -FormatArgs ($failoverClusterDisks -join '; ') -ErrorCategory InvalidResult
        }

        # Add the cluster disks as a setup argument
        $setupArguments += @{ FailoverClusterDisks = ($failoverClusterDisks | Sort-Object) }
    }

    # Determine network mapping for specific cluster installation types
    if ($Action -in @('CompleteFailoverCluster','InstallFailoverCluster','AddNode'))
    {
        $clusterIPAddresses = @()

        # If no IP Address has been specified, use "DEFAULT"
        if ($FailoverClusterIPAddress.Count -eq 0)
        {
            $clusterIPAddresses += "DEFAULT"
        }
        else
        {
            # Get the available client networks
            $availableNetworks = @(Get-CimInstance -Namespace root/MSCluster -ClassName MSCluster_Network -Filter 'Role >= 2')

            # Add supplied IP Addresses that are valid for available cluster networks
            foreach ($address in $FailoverClusterIPAddress)
            {
                foreach ($network in $availableNetworks)
                {
                    # Determine whether the IP address is valid for this network
                    if (Test-IPAddress -IPAddress $address -NetworkID $network.Address -SubnetMask $network.AddressMask)
                    {
                        # Add the formatted string to our array
                        $clusterIPAddresses += "IPv4; $address; $($network.Name); $($network.AddressMask)"
                    }
                }
            }
        }

        # Ensure we mapped all required networks
        $suppliedNetworkCount = $FailoverClusterIPAddress.Count
        $mappedNetworkCount = $clusterIPAddresses.Count

        # Determine whether we have mapping issues for the IP Address(es)
        if ($mappedNetworkCount -lt $suppliedNetworkCount)
        {
            throw New-TerminatingError -ErrorType FailoverClusterIPAddressNotValid -ErrorCategory InvalidArgument
        }

        # Add the networks to the installation arguments
        $setupArguments += @{ FailoverClusterIPAddresses = $clusterIPAddresses }
    }

    # Add standard install arguments
    $setupArguments += @{
        Quiet = $true
        IAcceptSQLServerLicenseTerms = $true
        Action = $Action
    }

    $argumentVars = @(
        'InstanceName',
        'InstanceID',
        'UpdateEnabled',
        'UpdateSource',
        'Features',
        'PID',
        'SQMReporting',
        'ErrorReporting',
        'InstallSharedDir',
        'InstallSharedWOWDir',
        'InstanceDir'
    )

    if ($null -ne $BrowserSvcStartupType)
    {
        $argumentVars += 'BrowserSvcStartupType'
    }

    if ($Features.Contains('SQLENGINE'))
    {
        $argumentVars += @(
            'SecurityMode',
            'SQLCollation',
            'InstallSQLDataDir',
            'SQLUserDBDir',
            'SQLUserDBLogDir',
            'SQLTempDBDir',
            'SQLTempDBLogDir',
            'SQLBackupDir'
        )

        if ($PSBoundParameters.ContainsKey('SQLSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $SQLSvcAccount -ServiceType 'SQL')
        }

        if($PSBoundParameters.ContainsKey('AgtSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $AgtSvcAccount -ServiceType 'AGT')
        }

        $setupArguments += @{ SQLSysAdminAccounts =  @($SetupCredential.UserName) }
        if ($PSBoundParameters -icontains 'SQLSysAdminAccounts')
        {
            $setupArguments['SQLSysAdminAccounts'] += $SQLSysAdminAccounts
        }
        
        if ($SecurityMode -eq 'SQL')
        {
            $setupArguments += @{ SAPwd = $SAPwd.GetNetworkCredential().Password }
        }

        $setupArguments += @{ AgtSvcStartupType = 'Automatic' }
    }

    if ($Features.Contains('FULLTEXT'))
    {
        if ($PSBoundParameters.ContainsKey('FTSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $FTSvcAccount -ServiceType 'FT')
        }
    }

    if ($Features.Contains('RS'))
    {
        if ($PSBoundParameters.ContainsKey('RSSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $RSSvcAccount -ServiceType 'RS')
        }
    }

    if ($Features.Contains('AS'))
    {
        $argumentVars += @(
            'ASCollation',
            'ASDataDir',
            'ASLogDir',
            'ASBackupDir',
            'ASTempDir',
            'ASConfigDir'
        )

        if ($PSBoundParameters.ContainsKey('ASSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $ASSvcAccount -ServiceType 'AS')
        }

        $setupArguments += @{ ASSysAdminAccounts = @($SetupCredential.UserName) }

        if($PSBoundParameters.ContainsKey("ASSysAdminAccounts"))
        {
            $setupArguments['ASSysAdminAccounts'] += $ASSysAdminAccounts
        }
    }

    if ($Features.Contains('IS'))
    {
        if ($PSBoundParameters.ContainsKey('ISSvcAccount'))
        {
            $setupArguments += (Get-ServiceAccountParameters -ServiceAccount $ISSvcAccount -ServiceType 'IS')
        }
    }

    # Automatically include any additional arguments
    foreach ($argument in $argumentVars)
    {
        $setupArguments += @{ $argument = (Get-Variable -Name $argument -ValueOnly) }
    }

    # Build the argument string to be passed to setup
    $arguments = ''
    foreach ($currentSetupArgument in $setupArguments.GetEnumerator())
    {
        if ($currentSetupArgument.Value -ne '')
        {
            # Arrays are handled specially
            if ($currentSetupArgument.Value -is [array])
            {
                # Sort and format the array
                $setupArgumentValue = ($currentSetupArgument.Value | Sort-Object | ForEach-Object { '"{0}"' -f $_ }) -join ' '
            }
            elseif ($currentSetupArgument.Value -is [Boolean])
            {
                $setupArgumentValue = @{ $true = 'True'; $false = 'False' }[$currentSetupArgument.Value]
                $setupArgumentValue = '"{0}"' -f $setupArgumentValue
            }
            else
            {
                # Features are comma-separated, no quotes
                if ($currentSetupArgument.Key -eq 'Features')
                {
                    $setupArgumentValue = $currentSetupArgument.Value
                }
                else 
                {
                    $setupArgumentValue = '"{0}"' -f $currentSetupArgument.Value
                }
            }

            $arguments += "/$($currentSetupArgument.Key.ToUpper())=$($setupArgumentValue) "
        }

    }

    # Replace sensitive values for verbose output
    $log = $arguments
    if ($SecurityMode -eq 'SQL')
    {
        $log = $log.Replace($SAPwd.GetNetworkCredential().Password,"********")
    }

    if ($PID -ne "")
    {
        $log = $log.Replace($PID,"*****-*****-*****-*****-*****")
    }

    $logVars = @('AgtSvcAccount', 'SQLSvcAccount', 'FTSvcAccount', 'RSSvcAccount', 'ASSvcAccount','ISSvcAccount')
    foreach ($logVar in $logVars)
    {
        if ($PSBoundParameters.ContainsKey($logVar))
        {
            $log = $log.Replace((Get-Variable -Name $logVar).Value.GetNetworkCredential().Password,"********")
        }
    }

    New-VerboseMessage -Message "Starting setup using arguments: $log"

    $arguments = $arguments.Trim()
    $process = StartWin32Process -Path $pathToSetupExecutable -Arguments $arguments

    New-VerboseMessage -Message $process
    WaitForWin32ProcessEnd -Path $pathToSetupExecutable -Arguments $arguments

    if ($ForceReboot -or ($null -ne (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)))
    {
        if (!($SuppressReboot))
        {
            $global:DSCMachineStatus = 1
        }
        else
        {
            New-VerboseMessage -Message 'Suppressing reboot'
        }
    }

    if (!(Test-TargetResource @PSBoundParameters))
    {
        throw New-TerminatingError -ErrorType TestFailedAfterSet -ErrorCategory InvalidResult
    }
}

<#
    .SYNOPSIS
        Tests if the SQL Server features are installed on the node.

    .PARAMETER Action
        The action to be performed. Default value is 'Install'.
        Possible values are 'Install', 'InstallFailoverCluster', 'AddNode', 'PrepareFailoverCluster', and 'CompleteFailoverCluster'

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource. Environment variables can be used in the path.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath`. Using this parameter will trigger a copy
        of the installation media to a temp folder on the target node. Setup will then be started from the temp folder on the target node.
        For any subsequent calls to the resource, the parameter `SourceCredential` is used to evaluate what major version the file 'setup.exe'
        has in the path set, again, by the parameter `SourcePath`.
        If the path, that is assigned to parameter `SourcePath`, contains a leaf folder, for example '\\server\share\folder', then that leaf
        folder will be used as the name of the temporary folder. If the path, that is assigned to parameter `SourcePath`, does not have a
        leaf folder, for example '\\server\share', then a unique guid will be used as the name of the temporary folder.

    .PARAMETER SuppressReboot
        Suppresses reboot.

    .PARAMETER ForceReboot
        Forces reboot.

    .PARAMETER Features
        SQL features to be installed.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.

    .PARAMETER InstanceID
        SQL instance ID, if different from InstanceName.

    .PARAMETER PID
        Product key for licensed installations.

    .PARAMETER UpdateEnabled
        Enabled updates during installation.

    .PARAMETER UpdateSource
        Path to the source of updates to be applied during installation.

    .PARAMETER SQMReporting
        Enable customer experience reporting.

    .PARAMETER ErrorReporting
        Enable error reporting.

    .PARAMETER InstallSharedDir
        Installation path for shared SQL files.

    .PARAMETER InstallSharedWOWDir
        Installation path for x86 shared SQL files.

    .PARAMETER InstanceDir
        Installation path for SQL instance files.

    .PARAMETER SQLSvcAccount
        Service account for the SQL service.

    .PARAMETER AgtSvcAccount
        Service account for the SQL Agent service.

    .PARAMETER SQLCollation
        Collation for SQL.

    .PARAMETER SQLSysAdminAccounts
        Array of accounts to be made SQL administrators.

    .PARAMETER SecurityMode
        Security mode to apply to the SQL Server instance.

    .PARAMETER SAPwd
        SA password, if SecurityMode is set to 'SQL'.

    .PARAMETER InstallSQLDataDir
        Root path for SQL database files.

    .PARAMETER SQLUserDBDir
        Path for SQL database files.

    .PARAMETER SQLUserDBLogDir
        Path for SQL log files.

    .PARAMETER SQLTempDBDir
        Path for SQL TempDB files.

    .PARAMETER SQLTempDBLogDir
        Path for SQL TempDB log files.

    .PARAMETER SQLBackupDir
        Path for SQL backup files.

    .PARAMETER FTSvcAccount
        Service account for the Full Text service.

    .PARAMETER RSSvcAccount
        Service account for Reporting Services service.

    .PARAMETER ASSvcAccount
       Service account for Analysis Services service.

    .PARAMETER ASCollation
        Collation for Analysis Services.

    .PARAMETER ASSysAdminAccounts
        Array of accounts to be made Analysis Services admins.

    .PARAMETER ASDataDir
        Path for Analysis Services data files.

    .PARAMETER ASLogDir
        Path for Analysis Services log files.

    .PARAMETER ASBackupDir
        Path for Analysis Services backup files.

    .PARAMETER ASTempDir
        Path for Analysis Services temp files.

    .PARAMETER ASConfigDir
        Path for Analysis Services config.

    .PARAMETER ISSvcAccount
       Service account for Integration Services service.

    .PARAMETER BrowserSvcStartupType
       Specifies the startup mode for SQL Server Browser service

    .PARAMETER FailoverClusterGroupName
        The name of the resource group to create for the clustered SQL Server instance

    .PARAMETER FailoverClusterIPAddress
        Array of IP Addresses to be assigned to the clustered SQL Server instance

    .PARAMETER FailoverClusterNetworkName
        Host name to be assigned to the clustered SQL Server instance
#>
function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [ValidateSet('Install','InstallFailoverCluster','AddNode','PrepareFailoverCluster','CompleteFailoverCluster')]
        [System.String]
        $Action = 'Install', 

        [System.String]
        $SourcePath,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [System.Boolean]
        $SuppressReboot,

        [System.Boolean]
        $ForceReboot,

        [System.String]
        $Features,

        [parameter(Mandatory = $true)]
        [System.String]
        $InstanceName,

        [System.String]
        $InstanceID,

        [System.String]
        $PID,

        [System.String]
        $UpdateEnabled,

        [System.String]
        $UpdateSource,

        [System.String]
        $SQMReporting,

        [System.String]
        $ErrorReporting,

        [System.String]
        $InstallSharedDir,

        [System.String]
        $InstallSharedWOWDir,

        [System.String]
        $InstanceDir,

        [System.Management.Automation.PSCredential]
        $SQLSvcAccount,

        [System.Management.Automation.PSCredential]
        $AgtSvcAccount,

        [System.String]
        $SQLCollation,

        [System.String[]]
        $SQLSysAdminAccounts,

        [System.String]
        $SecurityMode,

        [System.Management.Automation.PSCredential]
        $SAPwd,

        [System.String]
        $InstallSQLDataDir,

        [System.String]
        $SQLUserDBDir,

        [System.String]
        $SQLUserDBLogDir,

        [System.String]
        $SQLTempDBDir,

        [System.String]
        $SQLTempDBLogDir,

        [System.String]
        $SQLBackupDir,

        [System.Management.Automation.PSCredential]
        $FTSvcAccount,

        [System.Management.Automation.PSCredential]
        $RSSvcAccount,

        [System.Management.Automation.PSCredential]
        $ASSvcAccount,

        [System.String]
        $ASCollation,

        [System.String[]]
        $ASSysAdminAccounts,

        [System.String]
        $ASDataDir,

        [System.String]
        $ASLogDir,

        [System.String]
        $ASBackupDir,

        [System.String]
        $ASTempDir,

        [System.String]
        $ASConfigDir,

        [System.Management.Automation.PSCredential]
        $ISSvcAccount,

        [System.String]
        [ValidateSet('Automatic', 'Disabled', 'Manual')]
        $BrowserSvcStartupType,

        [Parameter(ParameterSetName = 'ClusterInstall')]
        [System.String]
        $FailoverClusterGroupName = "SQL Server ($InstanceName)",

        [Parameter(ParameterSetName = 'ClusterInstall')]
        [System.String[]]
        $FailoverClusterIPAddress,

        [Parameter(ParameterSetName = 'ClusterInstall')]
        [System.String]
        $FailoverClusterNetworkName
    )

    $parameters = @{
        SourcePath = $SourcePath
        SetupCredential = $SetupCredential
        SourceCredential = $SourceCredential
        InstanceName = $InstanceName
    }

    $getTargetResourceResult = Get-TargetResource @parameters
    New-VerboseMessage -Message "Features found: '$($getTargetResourceResult.Features)'"

    $result = $false
    if ($getTargetResourceResult.Features )
    {
        $result = $true

        foreach ($feature in $Features.Split(","))
        {
            # Given that all the returned features are uppercase, make sure that the feature to search for is also uppercase
            $feature = $feature.ToUpper();

            if(!($getTargetResourceResult.Features.Contains($feature)))
            {
                New-VerboseMessage -Message "Unable to find feature '$feature' among the installed features: '$($getTargetResourceResult.Features)'"
                $result = $false
            }
        }
    }
    
    if ($PSCmdlet.ParameterSetName -eq 'ClusterInstall')
    {
        New-VerboseMessage -Message "Clustered install, checking parameters."

        $result = $true

        Get-Variable -Name FailoverCluster* | ForEach-Object {
            $variableName = $_.Name

            if ($getTargetResourceResult.$variableName -ne $_.Value) {
                New-VerboseMessage -Message "$variableName '$($_.Value)' is not in the desired state for this cluster."
                $result = $false
            }
        }
    }

    $result
}

<#
    .SYNOPSIS
        Returns the SQL Server major version from the setup.exe executable provided in the Path parameter.

    .PARAMETER Path
        String containing the path to the SQL Server setup.exe executable.
#>
function Get-SqlMajorVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [String]
        $Path
    )

    (Get-Item -Path $Path).VersionInfo.ProductVersion.Split('.')[0]
}

<#
    .SYNOPSIS
        Returns the first item value in the registry location provided in the Path parameter.

    .PARAMETER Path
        String containing the path to the registry.
#>
function Get-FirstItemPropertyValue
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [String]
        $Path
    )

    $registryProperty = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($registryProperty)
    {
        $registryProperty = $registryProperty | Select-Object -ExpandProperty Property | Select-Object -First 1
        if ($registryProperty)
        {
            $registryPropertyValue = (Get-ItemProperty -Path $Path -Name $registryProperty).$registryProperty.TrimEnd('\')
        }
    }

    return $registryPropertyValue
}

<#
    .SYNOPSIS
        Copy folder structure using RoboCopy. Every file and folder, including empty ones are copied.

    .PARAMETER Path
        Source path to be copied.

    .PARAMETER DestinationPath
        The path to the destination.
#>
function Copy-ItemWithRoboCopy
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $DestinationPath
    )

    $robocopyExecutable = Get-Command -Name "Robocopy.exe" -ErrorAction Stop

    $robocopyArgumentSilent = '/njh /njs /ndl /nc /ns /nfl'
    $robocopyArgumentCopySubDirectoriesIncludingEmpty = '/e'
    $robocopyArgumentDeletesDestinationFilesAndDirectoriesNotExistAtSource = '/purge'

    if ([System.Version]$robocopyExecutable.FileVersionInfo.ProductVersion -ge [System.Version]'6.3.9600.16384')
    {
        Write-Verbose "Robocopy is using unbuffered I/O."
        $robocopyArgumentUseUnbufferedIO = '/J'
    }
    else
    {
        Write-Verbose 'Unbuffered I/O cannot be used due to incompatible version of Robocopy.'
    }

    $robocopyArgumentList = '{0} {1} {2} {3} {4} {5}' -f $Path,
                                                         $DestinationPath,
                                                         $robocopyArgumentCopySubDirectoriesIncludingEmpty,
                                                         $robocopyArgumentDeletesDestinationFilesAndDirectoriesNotExistAtSource,
                                                         $robocopyArgumentUseUnbufferedIO,
                                                         $robocopyArgumentSilent

    $robocopyStartProcessParameters = @{
        FilePath = $robocopyExecutable.Name
        ArgumentList = $robocopyArgumentList
    }

    Write-Verbose ('Robocopy is started with the following arguments: {0}' -f $robocopyArgumentList )
    $robocopyProcess = Start-Process @robocopyStartProcessParameters -Wait -NoNewWindow -PassThru

    switch ($($robocopyProcess.ExitCode))
    {
        {$_ -in 8, 16}
        {
            throw "Robocopy reported errors when copying files. Error code: $_."
        }

        {$_ -gt 7 }
        {
            throw "Robocopy reported that failures occured when copying files. Error code: $_."
        }

        1
        {
            Write-Verbose 'Robocopy copied files sucessfully'
        }

        2
        {
            Write-Verbose 'Robocopy found files at the destination path that is not present at the source path, these extra files was remove at the destination path.'
        }

        3
        {
            Write-Verbose 'Robocopy copied files to destination sucessfully. Robocopy also found files at the destination path that is not present at the source path, these extra files was remove at the destination path.'
        }

        {$_ -eq 0 -or $null -eq $_ }
        {
            Write-Verbose 'Robocopy reported that all files already present.'
        }
    }
}

<#
    .SYNOPSIS
        Returns the path of the current user's temporary folder.
#>
function Get-TemporaryFolder
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    return [IO.Path]::GetTempPath()
}

<#
    .SYNOPSIS
        Returns the decimal representation of an IP Addresses

    .PARAMETER IPAddress
        The IP Address to be converted
#>
function ConvertTo-Decimal
{
    [CmdletBinding()]
    [OutputType([System.UInt32])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]
        $IPAddress
    )
 
    $i = 3
    $DecimalIP = 0
    $IPAddress.GetAddressBytes() | ForEach-Object {
        $DecimalIP += $_ * [Math]::Pow(256,$i)
        $i--
    }
 
    return [UInt32]$DecimalIP
}

<#
    .SYNOPSIS
        Determines whether an IP Address is valid for a given network / subnet

    .PARAMETER IPAddress
        IP Address to be checked

    .PARAMETER NetworkID
        IP Address of the network identifier

    .PARAMETER SubnetMask
        Subnet mask of the network to be checked
#>
function Test-IPAddress
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]
        $IPAddress,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]
        $NetworkID,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]
        $SubnetMask
    )
    
    # Convert all values to decimal
    $IPAddressDecimal = ConvertTo-Decimal -IPAddress $IPAddress
    $NetworkDecimal = ConvertTo-Decimal -IPAddress $NetworkID
    $SubnetDecimal = ConvertTo-Decimal -IPAddress $SubnetMask

    # Determine whether the IP Address is valid for this network / subnet
    return (($IPAddressDecimal -band $SubnetDecimal) -eq ($NetworkDecimal -band $SubnetDecimal))
}

<#
    .SYNOPSIS
        Builds service account parameters for setup

    .PARAMETER ServiceAccount
        Credential for the service account

    .PARAMETER ServiceType
        Type of service account 
#>
function Get-ServiceAccountParameters
{
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCredential]
        $ServiceAccount,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SQL','AGT','IS','RS','AS','FT')]
        [String]
        $ServiceType
    )

    $parameters = @{}

    switch -Regex ($ServiceAccount.UserName.ToUpper())
    {
        '^(?:NT ?AUTHORITY\\)?(SYSTEM|LOCALSERVICE|LOCAL SERVICE|NETWORKSERVICE|NETWORK SERVICE)$'
        {
            $parameters = @{
                "$($ServiceType)SVCACCOUNT" = "NT AUTHORITY\$($Matches[1])"
            }
        }

        '^(?:NT SERVICE\\)(.*)$'
        {
            $parameters = @{
                "$($ServiceType)SVCACCOUNT" = "NT SERVICE\$($Matches[1])"
            }
        }

        '.*\$'
        {
            $parameters = @{
                "$($ServiceType)SVCACCOUNT" = $ServiceAccount.UserName
            }
        }

        default
        {
            $parameters = @{
                "$($ServiceType)SVCACCOUNT" = $ServiceAccount.UserName
                "$($ServiceType)SVCPASSWORD" = $ServiceAccount.GetNetworkCredential().Password
            }
        }
    }

    return $parameters
}

Export-ModuleMember -Function *-TargetResource
