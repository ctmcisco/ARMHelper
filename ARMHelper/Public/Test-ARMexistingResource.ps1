<#
.SYNOPSIS
Show if resource that are set to be deployed already exist

.DESCRIPTION
This function uses Test-AzureRmResourceGroupDeployment or Test-AzResourceGroupDeployment with debug output to find out what resources are deployed.
After that, it checks if those resources exist in Azure.
It will output the results when using complete mode or incremental mode (depending on the ARM template)

.PARAMETER ResourceGroupName
The resourcegroup where the resources would be deployed to. This resourcegroup needs to exist.

.PARAMETER TemplateFile
The path to the deploymentfile

.PARAMETER TemplateParameterFile
The path to the parameterfile

.PARAMETER Mode
The mode in which the deployment will run. Choose between Incremental or Complete.
Defaults to incremental.

.PARAMETER ThrowWhenRemoving
This switch makes the function throw when a resources would be overwritten or deleted. This can be useful for use in a pipeline.

.EXAMPLE
Test-ARMexistingResource -ResourceGroupName ArmTest -TemplateFile .\azuredeploy.json -TemplateParameterFile .\azuredeploy.parameters.json

--------
The following resources exist. Mode is set to incremental. New properties might be added:

type                                               name                                               Current ResourcegroupName
----                                               ----                                               -------------------------
Microsoft.Storage/storageAccounts                  armsta                                             armtest

.NOTES
Dynamic Parameters like in the orginal Test-AzResourcegroupDeployment-cmdlet are supported
Author: Barbara Forbes
Module: ARMHelper
https://4bes.nl
@Ba4bes
#>
Function Test-ARMExistingResource {
    [CmdletBinding(DefaultParameterSetName = "__AllParameterSets")]
    Param(
        [Parameter(
            Position = 1,
            Mandatory = $true,
            ParameterSetName = "__AllParameterSets"
        )]
        [ValidateNotNullorEmpty()]
        [string] $ResourceGroupName,

        [Parameter(
            Position = 2,
            Mandatory = $true,
            ParameterSetName = "__AllParameterSets"
        )]
        [ValidateNotNullorEmpty()]
        [string] $TemplateFile,

        [Parameter(
            ParameterSetName = 'TemplateParameterFile',
            Mandatory = $true
        )]
        [string] $TemplateParameterFile,

        [Parameter(
            ParameterSetName = 'TemplateParameterObject',
            Mandatory = $true
        )]
        [hashtable] $TemplateParameterObject,

        [parameter (
            ParameterSetName = "__AllParameterSets",
            Mandatory = $false
        )]
        [ValidateSet("Incremental", "Complete")]
        [string] $Mode = "Incremental",

        [parameter(
            ParameterSetName = "__AllParameterSets"
        )]
        [switch] $ThrowWhenRemoving
    )
    DynamicParam {
        if ($TemplateFile) {
            #create a new ParameterAttribute Object
            $OverRideParameter = New-Object System.Management.Automation.ParameterAttribute
            $OverRideParameter.Mandatory = $false
            #create an attributecollection object for the attribute we just created.
            $AttributeCollection = new-object System.Collections.ObjectModel.Collection[System.Attribute]
            $AttributeCollection.Add($OverRideParameter)
            $paramDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
            $Parameters = (Get-Content $TemplateFile | ConvertFrom-Json).parameters
            $ParameterValues = $parameters | Get-Member -MemberType NoteProperty
            ForEach ($Param in $ParameterValues) {
                $Name = $Param.Name
                $type = ($Parameters.$Name).type
                #add our paramater specifying the attribute collection
                $ExtraParam = New-Object System.Management.Automation.RuntimeDefinedParameter($Param.Name, ($Type -as [type]), $attributeCollection)

                #expose the name of our parameter

                $paramDictionary.Add($Param.Name, $ExtraParam)
            }
            return $paramDictionary
        }
    }
    process {

        #set variables
        $Parameters = @{
            ResourceGroupName = $ResourceGroupName
            TemplateFile      = $TemplateFile
            Mode              = $Mode
        }

        if (-not[string]::IsNullOrEmpty($TemplateParameterFile) ) {
            $Parameters.Add("TemplateParameterFile", $TemplateParameterFile)
        }
        if (-not[string]::IsNullOrEmpty($TemplateParameterObject) ) {
            $Parameters.Add("TemplateParameterObject", $TemplateParameterObject)
        }
        $CustomParameters = (Get-Content $TemplateFile | ConvertFrom-Json).parameters
        $CustomParameterValues = $Customparameters | Get-Member -MemberType NoteProperty
        foreach ($param in $CustomParameterValues) {
            $paramname = $param.Name
            if (-not[string]::IsNullOrEmpty($PSBoundParameters.$paramname)) {
                $Key = $paramname
                $Value = $PSBoundParameters.$paramname
                $Parameters.Add($Key, $Value)
            }
        }

        #Get the AzureModule that's being used
        $Module = Test-ARMAzureModule

        $Result = Get-ARMResource @Parameters

        if ([string]::IsNullOrEmpty($Result.Mode)) {
            Throw "Something is wrong with the output, no resources found. Please check your deployment with Get-ARMdeploymentErrorMessage"
        }
        #tell the user if de mode is complete or incremental
        Write-Output "Mode for deployment is $($Result.Mode) `n"

        $ValidatedResources = $Result.ValidatedResources
        $NewResources = [System.Collections.ArrayList]@()
        $ExistingResources = [System.Collections.ArrayList]@()
        $DeletedResources = [System.Collections.ArrayList]@()
        $OverwrittenResources = [System.Collections.ArrayList]@()
        $DifferentResourcegroup = [System.Collections.ArrayList]@()
        if ($Module -eq "Az") {
            $CheckRGResources = Get-AzResource -ResourceGroupName $ResourceGroupName
        }
        elseif ($Module -eq "AzureRM") {
            $CheckRGResources = Get-AzureRmResource -ResourceGroupName $ResourceGroupName
        }
        else {
            Throw "Something went wrong, No AzureRM of AZ module found"
        }
        foreach ($CheckRGResource in $CheckRGResources) {
            if ($ValidatedResources.Id -notcontains $CheckRGResource.ResourceId -and $Mode -eq "Complete") {
                Write-Verbose "Resource $($Resource.name) exists in the resourcegroup and mode is set to Complete"
                Write-Verbose "RESOURCE WILL BE DELETED!"
                $CheckRGResource.PSObject.TypeNames.Insert(0, 'ArmHelper.ExistingResource')
                $null = $DeletedResources.Add($CheckRGResource)
            }
        }

        foreach ($Resource in $ValidatedResources) {
            $Resourceparts = $Resource.Id.Split('/')
            if ([string]::IsNullOrEmpty($resource.type)){
            $Resource | add-member -MemberType NoteProperty -Name "Name" -Value $Resourceparts[-1]
            $resource | Add-Member -MemberType NoteProperty -Name "Type" -Value ($Resourceparts[-3] + "/" + $Resourceparts[-2])
            }
            #Give a warning that Deployments can give unexpected results
            If ($Resource.Type -eq "Microsoft.Resources/deployments") {
                Write-Warning "This command does not work for the resourcetype Microsoft.Resources/deployments. Please check $($Resource.Name) manually."
                Continue
            }
            if ($Module -eq "Az") {
                $Check = Get-AzResource -Name $Resource.name -ResourceType $Resource.type
            }
            elseif ($Module -eq "AzureRM") {
                $Check = Get-AzureRmResource -Name $Resource.name -ResourceType $Resource.type
            }
            else {
                Throw "Something went wrong, No AzureRM of AZ module found"
            }
            if ([string]::IsNullOrEmpty($Check)) {
                Write-Verbose "Resource $($Resource.name) does not exist, it will be created"
                $Resource.PSObject.TypeNames.Insert(0, 'ArmHelper.ExistingResource')
                $Resource | Add-Member -MemberType NoteProperty -Name "ResourceGroupName" -Value ($ResourceGroupName) -ErrorAction SilentlyContinue
                $null = $NewResources.Add($Resource)
            }
            else {
                if ($Check.ResourceGroupName -eq $ResourceGroupName ) {
                    if ($Result.Mode -eq "Complete") {
                        Write-Verbose "Resource $($Resource.name) already exists and mode is set to Complete"
                        Write-Verbose "RESOURCE WILL BE OVERWRITTEN!"
                        $Resource.PSObject.TypeNames.Insert(0, 'ArmHelper.ExistingResource')
                        $Resource | Add-Member -MemberType NoteProperty -Name "ResourceGroupName" -Value ($ResourceGroupName) -ErrorAction SilentlyContinue
                        $null = $OverwrittenResources.Add($Resource)
                    }
                    elseif ($Result.Mode -eq "Incremental") {
                        Write-Verbose "Resource $($Resource.name) already exists, mode is set to incremental"
                        Write-Verbose "New properties might be added"
                        $Resource.PSObject.TypeNames.Insert(0, 'ArmHelper.ExistingResource')
                        $Resource | Add-Member -MemberType NoteProperty -Name "ResourceGroupName" -Value ($ResourceGroupName) -ErrorAction SilentlyContinue
                        $null = $ExistingResources.Add($Resource)
                    }
                    else {
                        Write-Error "Resource mode for $($Resource.name) is not clear, please check manually"
                    }
                }
                else {
                    Write-Verbose "$($Resource.name) exists, but in another ResourceGroup. Deployment might fail."
                    $Resource.PSObject.TypeNames.Insert(0, 'ArmHelper.ExistingResource')
                    $Resource | Add-Member -MemberType NoteProperty -Name "ResourceGroupName" -Value ($Check.ResourceGroupName) -ErrorAction SilentlyContinue
                    $null = $DifferentResourcegroup.Add($Resource)
                }
            }
        }
        if ($NewResources.count -ne 0) {
            Write-Output "The following resources do not exist and will be created:"
            $NewResources
            Write-Output ""
        }

        if ($ExistingResources.count -ne 0) {
            Write-Output "The following resources exist. Mode is set to incremental. New properties might be added:"
            $ExistingResources
            Write-Output ""
        }

        if ($OverwrittenResources.Count -ne 0) {
            Write-Output "THE FOLLOWING RESOURCES WILL BE OVERWRITTEN! `n Resources exist and mode is complete:"
            $OverwrittenResources
            Write-Output ""
            if ($ThrowWhenRemoving) {
                Throw "Resources will be deleted or overwritten."
            }
        }

        if ($DeletedResources.Count -ne 0) {
            Write-Output "THE FOLLOWING RESOURCES WILL BE DELETED! `n Resources exist in the resourcegroup but not in the template, mode is complete:"
            $DeletedResources
            Write-Output ""
            if ($ThrowWhenRemoving) {
                Throw "Resources will be deleted or overwritten."
            }
        }
        if ($DifferentResourcegroup.Count -ne 0) {
            Write-Output "A resource of the same type and same name exists in other resourcegroup(s). This deployment might fail.`n"
            $DifferentResourcegroup
            Write-Output ""
        }
    }
}
