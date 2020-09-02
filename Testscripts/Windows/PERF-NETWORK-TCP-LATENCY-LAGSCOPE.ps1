# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param([object] $AllVmData, [object] $CurrentTestData)

function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        # role-0 vm is considered as the client-vm
        # role-1 vm is considered as the server-vm
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "role-0") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "role-1") {
                $noServer = $false
                $serverVMData = $vmData
            }
        }
        if ($noClient -or $noServer) {
            Throw "Client or Server VM not defined. Be sure that the SetupType has 2 VMs defined"
        }

        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by LISAv2 Automation" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./perf_lagscope.sh &> lagscopeConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartLagscopeTest.sh" $myString
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\StartLagscopeTest.sh" -username "root" -password $password -upload
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
        $testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartLagscopeTest.sh" -RunInBackground
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 lagscopeConsoleLogs.txt"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/tmp/lagscope-n*-output.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "Latency-*.csv"

        $testSummary = $null
        $lagscopeReportLog = Get-Content -Path "$LogDir\lagscope-n*-output.txt"
        Write-LogInfo $lagscopeReportLog
        #endregion

        try {
            $matchLine= (Select-String -Path "$LogDir\lagscope-n*-output.txt" -Pattern "Average").Line
            $minimumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[1]
            $maximumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[3]
            $averageLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[5]

            $currentTestResult.TestSummary += New-ResultSummary -testResult $minimumLat -metaData "Minimum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $currentTestResult.TestSummary += New-ResultSummary -testResult $maximumLat -metaData "Maximum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $currentTestResult.TestSummary += New-ResultSummary -testResult $averageLat -metaData "Average Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        } catch {
            $currentTestResult.TestSummary += New-ResultSummary -testResult "Error in parsing logs." -metaData "LAGSCOPE" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        }
        elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job is completed but VM is reporting that test is still running. Please check $LogDir\ConsoleLogs.txt"
            Write-LogInfo "Contents of summary.log : $testSummary"
            $testResult = "PASS"
        }
        Write-LogInfo "Test result : $testResult"
        Write-LogInfo "Test Completed"

        if ($testResult -eq "PASS") {
            Write-LogInfo "Generating the performance data for database insertion"
            $properties = Get-VMProperties -PropertyFilePath "$LogDir\VM_properties.csv"
            $testDate = $(Get-Date -Format yyyy-MM-dd)
            if ($currentTestData.SetupConfig.Networking -imatch "SRIOV") {
                $dataPath = "SRIOV"
            } else {
                $dataPath = "Synthetic"
            }

            $histogramFlag = $false
            foreach ($line in $lagscopeReportLog) {
                # From the line 'Interval(usec)  Frequency', we begin to collect the histogram data
                if ($line -imatch "Interval\(usec\)") {
                    $histogramFlag = $true
                    continue;
                }
                if ($histogramFlag -eq $false) {
                    continue;
                }
                $interval = ($line.Trim() -replace '\s+',' ').Split(" ")[0]
                $frequency = ($line.Trim() -replace '\s+',' ').Split(" ")[1]
                if (($interval -match "^\d+$") -and ($frequency -match "^\d+$") -and ($interval -ne "0")) {
                    $resultMap = @{}
                    if ($properties) {
                        $resultMap["GuestDistro"] = $properties.GuestDistro
                        $resultMap["HostOS"] = $properties.HostOS
                        $resultMap["KernelVersion"] = $properties.KernelVersion
                    }
                    $resultMap["HostType"] = "Azure"
                    $resultMap["HostBy"] = $CurrentTestData.SetupConfig.TestLocation
                    $resultMap["GuestOSType"] = "Linux"
                    $resultMap["GuestSize"] = $clientVMData.InstanceSize
                    $resultMap["IPVersion"] = "IPv4"
                    $resultMap["ProtocolType"] = "TCP"
                    $resultMap["TestCaseName"] = $global:GlobalConfig.Global.$TestPlatform.ResultsDatabase.testTag
                    $resultMap["TestDate"] = $testDate
                    $resultMap["LISVersion"] = "Inbuilt"
                    $resultMap["DataPath"] = $dataPath
                    $resultMap["MaxLatency_us"] = [Decimal]$maximumLat
                    $resultMap["AverageLatency_us"] = [Decimal]$averageLat
                    $resultMap["MinLatency_us"] = [Decimal]$minimumLat
                    #Percentile Values are not calculated yet. will be added in future
                    $resultMap["Latency95Percentile_us"] = 0
                    $resultMap["Latency99Percentile_us"] = 0
                    $resultMap["Interval_us"] = [int]$interval
                    $resultMap["Frequency"] = [int]$frequency
                    $currentTestResult.TestResultData += $resultMap
                }
            }
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult
}

Main