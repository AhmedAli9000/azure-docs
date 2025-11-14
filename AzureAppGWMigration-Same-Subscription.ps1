<#PSScriptInfo

.VERSION 1.0.11

.GUID be3b84b4-e9c5-46fb-a050-699c68e16119

.AUTHOR Microsoft Corporation

.COMPANYNAME Microsoft Corporation

.COPYRIGHT Microsoft Corporation. All rights reserved.

.TAGS Azure, Az, ApplicationGateway, AzNetworking

.RELEASENOTES 
1.0.11
 -- Fix Resource Group Deletion Bug
 -- Script Version Check

1.0.10
 -- Signed file with changes of 1.0.9.

1.0.9
 -- Added support to provide rule priority for newly created V2 gateway request routing rule.
 -- Fixed request routing rule ordering bug introduced in 1.0.8.
#>

<#

.SYNOPSIS
AppGateway v1 -> v2 migration

.DESCRIPTION
This script will help you create a V2 sku application gateway with the same configuration as your V1 sku application gateway. 

.PARAMETER ResourceId
Application Gateway ResourceId, like "/subscriptions/<your-subscriptionId>/resourceGroups/<v1-app-gw-rgname>/providers/Microsoft.Network/applicationGateways/<v1-app-gw-name>"
.PARAMETER SubnetAddressRange
The subnet address in CIDR notation, where you want to deploy v2 application gateway (Make sure the subnet is empty or contains only application gateway standard_v2/waf_v2 sku resources). 
.PARAMETER AppGwName
Name of v2 app gateway, default will be <v1-app-gw-name>_v2
.PARAMETER AppGwResourceGroupName
Name of resource group where you want v2 application gateway resources to be created (default value will be <v1-app-gw-rgname>)
.PARAMETER SslCertificates
Comma seperated list of Ssl certificate to be attached to app gateway listeners (set using New-AzApplicationGatewaySSLCertificate command). 
Note: Passing reference to all ssl certs used in v1 gateway is required to get same configuration in v2 app gateway
.PARAMETER TrustedRootCertificates 
Comma seperated list of trusted root certificates (set using New-AzApplicationGatewayTrustedRootCertificate command). For more details refer https://aka.ms/appgwmigrationdoc
.PARAMETER PrivateIpAddress
Private Ip address to be assigned to v2 app gateway.
.PARAMETER ValidateMigration
Post migration validation by comparing ApplicationGatewayBackendHealth response.
.PARAMETER PublicIpResourceId
Public Ip Address resourceId (if already exists) can be attached to application gateway. If no input is given script will create a public ip resource for you in the same resource group
.PARAMETER EnableAutoscale
Enable autoscale configuration for app gateway v2 instances 

.EXAMPLE
$password = ConvertTo-SecureString <your-password> -AsPlainText -Force
$mySslCert1 = New-AzApplicationGatewaySslCertificate -Name "Cert01" -CertificateFile <Cert-File-Path> -Password $password
$mySslCert2 = New-AzApplicationGatewaySslCertificate -Name "Cert02" -CertificateFile <Cert-File-Path> -Password $password
.\migration.ps1 -ResourceId "/subscriptions/<your-sub-id>/resourceGroups/<your-rg>/providers/Microsoft.Network/applicationGateways/<v1AppGatewayName>" -SubnetAddressRange <CIDR like 10.0.3.0/24> -sslCert $mySslCert1,$mySslCert2

.INPUTS
String
Microsoft.Azure.Commands.Network.Models.PSApplicationGatewaySslCertificate[]
Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayTrustedRootCertificate[]

.OUTPUTS
PSApplicationGateway

.LINK
https://aka.ms/appgwmigrationdoc
https://docs.microsoft.com/en-us/azure/application-gateway/
https://docs.microsoft.com/en-us/azure/application-gateway/ssl-overview#end-to-end-ssl-with-the-v2-sku

.NOTES 
Note - Passing reference to all ssl certs used in v1 gateway is required to get same configuration in v2 app gateway
#>

#Requires -Module Az.Network
#Requires -Module Az.Compute
#Requires -Module Az.Resources
Param([Parameter(Mandatory = $True)][string] $ResourceId,
[Parameter(Mandatory = $True)][string] $SubnetAddressRange,
[string] $AppGwName,
[string] $AppGwResourceGroupName,
[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewaySslCertificate[]] $SslCertificates,
[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayTrustedRootCertificate[]] $TrustedRootCertificates,
[string] $PublicIpResourceId,
[string] $PrivateIpAddress,
[switch] $ValidateMigration,
[switch] $EnableAutoscale
)

if (!(Get-Module -ListAvailable -Name Az.Network)) 
{
    Write-Error ("You need 'Az' module to proceed. Az is a new cross-platform PowerShell module that will replace AzureRM. You can install this module by running 'Install-Module Az' in an elevated PowerShell prompt.")
    Write-Warning ("If you see error 'AzureRM.Profile already loaded. Az and AzureRM modules cannot be imported in the same session', You would need to close the current session and start new one.")
    exit
}

# Hashed PackageManagement\Get-Package
# Function Private:ScriptVersionCheck()
# {
#    $InstalledScriptVersion = (Get-InstalledScript -Name 'AzureAppGWMigration').Version
#    $LatestScriptVersion = (Find-Script -Name 'AzureAppGWMigration').Version

#    if(!$InstalledScriptVersion)
#    {
#       Write-Warning("You have manually downloaded the migration script. The stable version of this script is $LatestScriptVersion, which contains critical fixes and bugs that may not be present in the version you have installed. It is recommended to use the stable version. You can find more information about the currently installed version and how to download the stable version at https://aka.ms/migrationscriptdownload.")

#       $confirmation = Read-Host "Are you Sure You Want To Proceed? Press 'y' for continue, any other key for existing"

#       if ($confirmation -ne 'y')
#       {
#          exit;
#       }
#    }
#    else
#    {
#       if($InstalledScriptVersion -ne $LatestScriptVersion)
#       {
#           Write-Warning("You have installed the migration script version : $InstalledScriptVersion. It is recommended to use the stable version of the script : $LatestScriptVersion. This version contains critical bug fixes that may not be present in the version you are currently using. You can install the stable version by running 'UnInstall-Script -Name 'AzureAppGWMigration' -Force; Install-Script -Name 'AzureAppGWMigration' -RequiredVersion $LatestScriptVersion -Force'")

#           $confirmation = Read-Host "Are you Sure You Want To Proceed? Press 'y' for continue, any other key for existing"

#           if ($confirmation -ne 'y')
#           {
#              exit;
#           }
#       }
#    }
# }

# ScriptVersionCheck

$sw = [Diagnostics.Stopwatch]::StartNew()

#Validating resourceId
$matchResponse = $resourceId -match "/subscriptions/(.*?)/resourceGroups/"
if(!$matchResponse)
{
    Write-Warning("Invalid ResourceId format $resourceId.")
    exit
}

#Validating set-context succeess
$subscription = $matches[1]
# $context = Set-AzContext -Subscription $subscription -ErrorVariable contextFailure
if ($contextFailure)
{
    Write-Warning("Unable to set subscription $subscription in context. Please retry again")
    exit
}

$resource = Get-AzResource -ResourceId $resourceId -ErrorVariable getResourceFailure

# Validating Get-Resource
if($getResourceFailure -or !$resource)
{
    Write-Warning("Unable to get resource for $resourceId. Please retry again")
    exit
}

# $resourcegroup = $resource.ResourceGroupName
$resourcegroup = $sourceResourceGroup 
# $location = $resource.Location
$location = $destinationlocation
# $V1AppGwName = $resource.Name
$V1AppGwName = $sourceAppGwName
$appendString = "_v2"
$existingResourceIdFormat = "/resourceGroups/$resourcegroup/providers/Microsoft.Network/applicationGateways/$V1AppGwName/"
$newResourceIdFormat = "/resourceGroups/ResourceGroupNotSet/providers/Microsoft.Network/applicationGateways/ApplicationGatewayNameNotSet/"
$dict = @{}
$migrationCompleted = $false
$isNewSubnetCreated = $false
$isNewIPCreated = $false
$isNewResourceGroupCreated = $false
$pip = $null
if ( !$AppGwName )
{ 
    $AppGwName = $V1AppGwName + $appendString
}

if ( !$AppGwResourceGroupName )
{
    # $AppGwResourceGroupName = $resourcegroup
    $AppGwResourceGroupName = $destinationresourceGroupName
}
# else
# {
#     # Create resource group if doesn't exist
#     Get-AzResourceGroup -Name $AppGwResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
#     if ($notPresent)
#     {
#         $isNewResourceGroupCreated = $true
#         New-AzResourceGroup -Name $AppGwResourceGroupName -Location $location
#     }
# }

# $AppGw = Get-AzApplicationGateway -Name $V1AppGwName -ResourceGroupName $resourcegroup -ErrorVariable getAppGwResourceFailure
$AppGw = $oldAppGw 

# Validating Get-AppGwResource Failure
if($getAppGwResourceFailure -or !$AppGw)
{
    Write-Warning("Unable to get application gateway resource for $resourceId. Please retry again")
    exit
}

if ($AppGw.ProvisioningState -eq "Failed")
{
    Write-Warning ("Application gateway with provisioning state 'Failed' may result in V2 Application Gateway with failed state")
}

Write-Host "Creating Name:$AppGwName app gateway . . ."

# cleanup resources
Function Private:Cleanup()
{
    if ($newAppGw)
    {
        Remove-AzApplicationGateway -Name $newAppGw.Name -ResourceGroupName $AppGwResourceGroupName -Force
    }
    if ($isNewIPCreated)
    {
        Write-Host ("Removing IP $PublicIpResourceName")
        Remove-AzPublicIpAddress -Name $PublicIpResourceName -ResourceGroupName $AppGwResourceGroupName -Force -ErrorAction SilentlyContinue
    }
    if($isNewResourceGroupCreated)
    {
        Write-Host ("ResourceGroup $AppGwResourceGroupName is not deleted. Please clean up the resource group after verifying that resources inside resouce group are not used or not needed.")
    }
    if ($isNewSubnetCreated)
    {
        Write-Host ("Removing subnet $subnetname")
        $vnet = Remove-AzVirtualNetworkSubnetConfig -Name $subnetname -VirtualNetwork $vnet | Set-AzVirtualNetwork
    }

    Write-Host ("Resource Cleanup Finished")
    exit
}

Function Private:GetPrivateFrontendIp()
{
    if (!$PrivateIpAddress)
    {
        $SubnetStartAddress = [ipaddress]$SubnetAddressRange.Split("/")[0]
        # select an ip address beyond reserved Ip address range
        $SubnetSize = [int][math]::pow( 2, (32 - [int]$SubnetAddressRange.Split("/")[1]))
        $AddressOffset = (Get-Random -Minimum 4 -Maximum ($SubnetSize - 2))
        $IpAddressRangeToAdd = [ipaddress]"$AddressOffset"
        return New-Object System.Net.IPAddress($SubnetStartAddress.Address + $IpAddressRangeToAdd.Address)
    }
    else 
    {
        return [ipaddress]$PrivateIPAddress
    }
}

Function Private:ValidateInput()
{
    if (!$appgw -or !($appgw.sku.Tier -in "Standard","WAF","Standard_v2","WAF_v2"))
    {
        Write-Warning("Could not detect any V1 ('Standard' or 'WAF') resource as per your input parameters. Please double check input parameters.")
        exit
    }

    $Listeners = Get-AzApplicationGatewayHttpListener -ApplicationGateway $Appgw
    # ssl cert is necessary if you have 'https' enabled listeners in app gateway
    if (($Listeners |  Where-Object { $_.Protocol -match "https" }).count -GT 0 -and (($null -EQ $SslCertificates) -or ($SslCertificates.count -EQ 0)) )
    {
        Write-Warning ("Providing '-SslCertificates <cert>' is mandatory if you have 'https' listeners in your V1 ('Standard' or 'WAF') resource.")
        exit
    }

    if ($SslCertificates)
    {
        $SslCertificates | ForEach-Object { 
            if (!$_ -or ($_.GetType() -NE (New-Object -TypeName Microsoft.Azure.Commands.Network.Models.PSApplicationGatewaySslCertificate).GetType()))
            {
                Write-Error ("Invalid input - 'SslCertificates'. Expected object of type : 'Microsoft.Azure.Commands.Network.Models.PSApplicationGatewaySslCertificate' ")
                exit
            }
            else 
            {
                $_.Id = $_.Id -replace "/resourceGroups/.*/sslCertificates/",($newResourceIdFormat+"sslCertificates/")
            }
         }
    }
    
    if (!$TrustedRootCertificates -or ($TrustedRootCertificates.count -EQ 0))
    {
        $TrustedRootCertificates = (New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayTrustedRootCertificate])
    }
    else
    {
        $TrustedRootCertificates | ForEach-Object { 
            if (!$_ -or ($_.GetType() -NE (New-Object -TypeName Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayTrustedRootCertificate).GetType()))
            {
                Write-Error ("Invalid input - 'TrustedRootCertificates'. Expected object of type : 'Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayTrustedRootCertificate' ")
                exit
            }
            else 
            {
                $_.Id = $_.Id -replace "/resourceGroups/.*/trustedRootCertificates/",($newResourceIdFormat+"trustedRootCertificates/")
            }
        }
    }
}

Function Private:GetApplicationGatewaySku($gwSkuTier)
{
    if ($gwSkuTier -EQ "Standard")
    { 
        return New-AzApplicationGatewaySku -Name Standard_v2 -Tier Standard_v2
    }
    else
    {
        return New-AzApplicationGatewaySku -Name WAF_v2 -Tier WAF_v2
    }
}

Function Private:GetCapacityUnits($AppgwSku)
{
    # Min/Max Max Capacity for Autoscale
    $MinMaxCapacity = 2
    $MaxMaxCapacity = 125
    $MinCapacity = 1
    $MaxCapacity = 2
    switch($AppgwSku.Name)
    {
        {$_ -in "Standard_Small"} { $MinCapacity = [math]::floor($AppgwSku.Capacity/2); $MaxCapacity = $AppgwSku.Capacity; }
        {$_ -in "WAF_Medium","Standard_Medium"} { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(1.5*$AppgwSku.Capacity); }
        {$_ -in "WAF_Large","Standard_Large"} { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(2.5*$AppgwSku.Capacity); }
        {$_ -in "Standard_Small_V2"} { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(1.5*$AppgwSku.Capacity); }
        {$_ -in "WAF_Medium_V2","Standard_Medium_V2"} { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(2.5*$AppgwSku.Capacity); }
        {$_ -in "WAF_Large_V2","Standard_Large_V2"} { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(4*$ppgwSku.Capacity); }
        default { $MinCapacity = $AppgwSku.Capacity; $MaxCapacity = [math]::ceiling(1.5*$AppgwSku.Capacity); }
    }

    if ($MaxCapacity -GT $MaxMaxCapacity)
    {
        Write-Warning ("Your current V1 ('Standard' or 'WAF') has a large number of instances that exceed the limit for provisioning equivalently scaled V2 instances using our V1->V2 SKU conversion factors. Please consider reducing the number of instances for your V1 Application Gateway/WAF resource, or contact Azure Support to increase your subscription limits.")
        exit
    }
    elseif ($MaxCapacity -LT $MinMaxCapacity)
    {
        $MaxCapacity = $MinMaxCapacity
    }

    return $MinCapacity, $MaxCapacity
}

Function Private:IsSslCertificateMatch($newSslCert, $existingSslCert)
{
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 ([System.Convert]::FromBase64String($newSslCert.Data),$newSslCert.Password,4)
    $certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certCollection.Import([System.Convert]::FromBase64String($existingSslCert.PublicCertData))
    if (($certCollection | Where-Object { $_.Equals($cert) }).Count -GT 0)
    {
        return $true
    }
    else 
    {
        return $false
    }
}

$AttachVmNetworkInterface = {
    param($nicName, $rgname, $BackendPool)
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    if ($nic)
    {
        $nicipconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic
        $BackendPoolToAdd = New-AzApplicationGatewayBackendAddressPool -Name $BackendPool.Name
        $BackendPoolToAdd.Id = $BackendPool.id
        $nicipconfig | ForEach-Object { if(!$_.ApplicationGatewayBackendAddressPools.id.Contains($BackendPoolToAdd.id)) {$_.ApplicationGatewayBackendAddressPools.Add($BackendPoolToAdd) } }
        $retryCount = 0
        do
        {
            Start-Sleep -s ($retryCount*5)
            $newnic = Set-AzNetworkInterface -NetworkInterface $nic
            $retryCount++
        }while(($retryCount -LT 3) -and !$newnic)

        if($newnic)
        {
            Write-Host("VM Nic '$($nicName)' was added to backend pool.")
            return $true
        }
    }
    Write-Error("VM Nic '$($nicName)' could not be successfully added to the backend pool. Please retry the script after some time")
    return $false
}

$AttachVmssNetworkInterface = {
    param($vmssName, $nicList, $rgname, $BackendPoolToAdd, $Instances)
    $nicList = $nicList | Select-Object -Unique
    $Instances = $Instances | Select-Object -Unique
    $vmss = Get-AzVmss -VMScaleSetName $vmssName -ResourceGroupName $rgname
    $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations `
        | Where-Object { $_.Name -in $nicList }`
        | Select-Object -ExpandProperty IpConfigurations | ForEach-Object { if(!$_.ApplicationGatewayBackendAddressPools.id.Contains($BackendPoolToAdd.id)) { $_.ApplicationGatewayBackendAddressPools.Add($BackendPoolToAdd.id) } }
    Update-AzVmss -VirtualMachineScaleSet $vmss -Name $vmssName -ResourceGroupName $rgname -ErrorVariable errorDetails
    if ($errorDetails)
    {
        Write-Error ("Failed to migrate backend pool '$($BackendPoolToAdd.Name)'")
        return $false
    }
    
    Write-Host("Virtual machine scale set '$($vmssName)' was added to backend pool.")
    if (!$errorDetails -and ($vmss.UpgradePolicy.Mode -EQ "Manual") )
    {
        Write-Host ("Upgrading all the instances of '$($vmssName)' for this change to work.")
        foreach($instance in $Instances){
            $updateStatus = Update-AzVmssInstance -ResourceGroupName $rgname -VMScaleSetName $vmssName -InstanceId $instance
            if($updateStatus.Error)
            {
                Write-Warning "Failed to update instance : ", $instance, "in vmss : ", $vmssName, ". Users will need to manually upgrade their vmss instances, or as per their vmss upgrade policy"
            }
        }
        return $true
    }
    return $true
}

ValidateInput
Write-Host ("Input parameters validated")
try{
    #define sku & autoscale
    $sku = GetApplicationGatewaySku($AppGw.Sku.Tier)
    $capacity = GetCapacityUnits($AppGw.Sku)
    if ($enableAutoscale)
    {   
        # $autoscaleConfig = New-AzApplicationGatewayAutoscaleConfiguration -MinCapacity $capacity[0] -MaxCapacity $capacity[1]
        $autoscaleConfig = New-AzApplicationGatewayAutoscaleConfiguration -MinCapacity  $newautoscaleConfigMin -MaxCapacity  $newautoscaleConfigMAX 

    }
    else
    {
        $sku.Capacity = $capacity[1]
    }
    
    # # create subnet with appropiate nsg
    # $GatewayConfig = Get-AzApplicationGatewayIPConfiguration -ApplicationGateway $AppGw
    # $matchResponse = $GatewayConfig.subnet.id -match "/resourceGroups/(.*?)/.*/virtualNetworks/(.*?)/subnets/(.*)"

    # $vnetname = $matches[2]
    $vnetname = $destinationvnetName

    $vnet = Get-AzvirtualNetwork -Name $vnetname -ResourceGroupName $destinationRGforVnet 

    # if(!$vnet)
    # {
    #     Write-Warning ("Vnet $vnetname associated with $resourceId is not found. This is not expected. Please try again later.")
    #     return
    # }

    # $V1Subnet = Get-AzVirtualNetworkSubnetConfig -Name $matches[3] -VirtualNetwork $vnet

    # if(!$V1Subnet)
    # {
    #     Write-Warning ("Subnet associated with $resourceId is not found. This is not expected. Please try again later.")
    #     return
    # }

    # $agv2Subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet | Where-Object { $_.AddressPrefix -Match $SubnetAddressRange }

    # if( $null -eq $agv2Subnet )
    # {
    #     $subnetname = $AppGwName + "Subnet"
    #     $vnet = Add-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $SubnetAddressRange -VirtualNetwork $vnet -NetworkSecurityGroupId $V1Subnet.NetworkSecurityGroup.Id
    #     $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        
    #     if (!$vnet)
    #     {
    #         Write-Warning ("Please check if you have provided the correct SubnetAddressRange")
    #         return
    #     }

    #     $agv2Subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetname -VirtualNetwork $vnet
    #     $isNewSubnetCreated = $true
    #     Write-Host ("Created Subnet $($agv2Subnet.Name) for V2 Application Gateway / WAF. Address Prefix : $SubnetAddressRange")
    # }

    # if (!$agv2Subnet)
    # {
    #     Write-Warning ("Failed to create Subnet. This might happen if VNet resource is in failed state. Please correct that and retry execution")
    #     return
    # }
    # else
    # {
    #     Write-Host ("Using Subnet: $($agv2Subnet.Name)")
    # }
    # $agv2Subnet = $agSubnetConfig
    $agv2Subnet = $subnetnew

    # Create FrontendIpConfig
    if ($PublicIpResourceId)
    {
        $PublicIpResource = Get-AzResource -ResourceId $PublicIpResourceId -ErrorAction SilentlyContinue
        if($PublicIpResource)
        {
            $PublicIpResourceName = $PublicIpResource.Name
            $matchResponse = $PublicIpResourceId -match "/resourceGroups/(.*?)/providers"
            $pip = Get-AzPublicIpAddress -Name $PublicIpResourceName -ResourceGroupName $matches[1] -ErrorAction SilentlyContinue

            if(!$pip)
            {
                Write-Warning ("Failed to get Public Ip Resource with name $PublicIpResourceName. Please ensure that provided Public Ip resource exists")
                return
            }
        }
        else
        {
            Write-Warning ("Failed to get Public Ip Resource with Id $PublicIpResourceId. Please ensure that provided Public Ip resource exists")
            return
        }
    }

    if ( $null -eq  $pip )
    {
        $PublicIpResourceName = $AppGwName + "-IP"
        
        #Verify that public IP doesn't exist
        $getPip = Get-AzPublicIpAddress -ResourceGroupName $AppGwResourceGroupName -name $PublicIpResourceName -ErrorAction SilentlyContinue | Out-Null

        if($getPip)
        {
            Write-Warning ("Public Ip Resource with Id $($getPip.Id) already exists. Please try again after deleting this public IP or providing an explicit public Ip Resource using PublicIpResourceId parameter")
            return
        }

        $pip = New-AzPublicIpAddress -ResourceGroupName $AppGwResourceGroupName -name $PublicIpResourceName -location $location -AllocationMethod "Static" -Sku Standard -Force
        $isNewIPCreated = $true
    }

    $fip = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayFrontendIPConfiguration]
    $fp = (Get-AzApplicationGatewayFrontendIPConfig -ApplicationGateway $AppGw | Where-Object { $_.PublicIPAddress -NE $null })

    if ($fp)
    {
        if ($fp.count -NE 1)
        {
            Write-Error ("Multiple Public FrontendIP are not supported for AppGw v2.")
            exit
        }

        $fipName = $fp.Name
    }
    else 
    {
        $fipName = $AppGwName + "PublicFrontendIPConfig"
    }
    # Compulsary create public frontend ip config in case of v2
    $fip.Add((New-AzApplicationGatewayFrontendIPConfig -Name $fipName -PublicIPAddress $pip))
    $fp | ForEach-Object { $dict[$_.Id] = $fip[0] }
    # Create private frontend ip config only if it is present in v1 also
    $fp = (Get-AzApplicationGatewayFrontendIPConfig -ApplicationGateway $AppGw | Where-Object { $_.PublicIPAddress -EQ $null })
    if ($fp)
    {
        $fip.Add((New-AzApplicationGatewayFrontendIPConfig -Name $fp.Name -PrivateIPAddress $(GetPrivateFrontendIp).IPAddressToString -Subnet $agv2Subnet))
        $dict[$fp.Id] = $fip[1]
    }

    if (!$fip)
    {
        Write-Warning ("Failed to create FrontendIpConfig. This should not have happened ideally. Please retry execution after sometime.")
        return
    }
    else
    {
        Write-Host ("Created FrontendIpConfiguration")
    }

    # Create Frontend ports
    $FrontEndPorts = Get-AzApplicationGatewayFrontendPort  -ApplicationGateway $AppGw 
    $FrontEndPorts | ForEach-Object {$dict[$_.Id] = $_;$_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }

    # Create gatewayIpConfig
    $GatewayConfig = Get-AzApplicationGatewayIPConfiguration -ApplicationGateway $AppGw
    $gwIPconfig = New-AzApplicationGatewayIPConfiguration -Name $GatewayConfig.Name -Subnet $agv2Subnet
    if (!$gwIPconfig)
    {
        Write-Warning ("Failed to create GatewayIpConfig. This should not have happened ideally. Please retry execution after sometime.")
        return
    }
    else
    {
        Write-Host ("Created GatewayIpConfiguration")
    }

    # Create probes
    $probes = Get-AzApplicationGatewayProbeConfig -ApplicationGateway $appgw
    $probes | ForEach-Object { $dict[$_.Id] = $_; $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }
    Write-Host ("Created Health Probes")

    # Create BackendPools
    $BackendPools = Get-AzApplicationGatewayBackendAddressPool -ApplicationGateway $AppGw
    $BackendPools | ForEach-Object {$dict[$_.Id] = $_; $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }
    Write-Host ("Created Backend Pool")

    # Backend http settings
    $SettingsList  = Get-AzApplicationGatewayBackendHttpSetting -ApplicationGateway $AppGw
    $SettingsList | ForEach-Object { 
        $_.AuthenticationCertificates = $null
        if ($_.Protocol -EQ "https")
        {
            $_.TrustedRootCertificates = $TrustedRootCertificates
            if (($TrustedRootCertificates.Count -GT 0) -and !$_.HostName -and ($_.PickHostNameFromBackendAddress -EQ $False))
            {
                Write-Warning ("For V2 sku, if trusted root cert is provided, ensure that either pickhostnamefrombackendaddress or hostname is provided")
                $hostname = Read-Host -Prompt 'Please Input Hostname for $_.Name BackendHttpSetting'
                $_.HostName = $hostname
            }
        }
        if($_.Probe -and $dict.ContainsKey($_.Probe.Id)) { $_.Probe = $dict[$_.Probe.Id]; }
        $dict[$_.Id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }
    Write-Host ("Created Backend HttpSettings")

    # Ssl Certs
    $existingSslCertificates = Get-AzApplicationGatewaySslCertificate -ApplicationGateway $appgw
    foreach ($certA in $existingSslCertificates) { 
        $flag = $false;
        $dict[$certA.Id] = $SslCertificates[0].Id
        foreach($certB in $SslCertificates) {
            if(IsSslCertificateMatch $certB $certA)
            {
                $dict[$certA.Id] = $certB.id
                $flag = $true
                break
            }
        }
        if($flag -eq $false)
        {
            Write-Warning ("No ssl certificate provided for '$($certA.Name)'. Please ensure all SSL certificates used in V1 ('Standard' or 'WAF') resource are included.")
        }
    }

    # Create Listeners
    $v2listener = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayHttpListener]
    $Listeners = Get-AzApplicationGatewayHttpListener -ApplicationGateway $Appgw
    $Listeners | ForEach-Object {
        $command = "New-AzApplicationGatewayHttpListener -Name $($_.Name) -Protocol $($_.Protocol) -FrontendPortId $($dict[$_.FrontendPort.Id].id) -FrontendIpConfigurationId $($dict[$_.FrontendIpConfiguration.Id].id) -RequireServerNameIndication $($_.RequireServerNameIndication) ";`
        if ($_.HostName)
        {
            $command += " -Hostname $($_.HostName)"
        }
        if ($_.Protocol -EQ "https")
        {
            if ($dict.ContainsKey($_.SslCertificate.Id))
            {
                $command = $command + " -SslCertificateId $($dict[$_.SslCertificate.Id])"
            }
            else 
            {
                $command = $command + " -SslCertificateId $($SslCertificates[0].Id)"
            }
        }
        $z = Invoke-Expression $command;
        if ($z)
        {
            $customError = Get-AzApplicationGatewayHttpListenerCustomError -HttpListener $_
            if ($customError)
            {
                $z.CustomErrorConfigurations = $customError
            }

            $v2listener.Add($z);
            $dict[$_.id] = $z;
        }
    }
    if ($v2listener.count -NE $listeners.count )
    {
        Write-Warning ("Failed to create Listeners. Please check you have given correct inputs and retry.")
        return
    }
    else
    {
        Write-Host ("Created Listeners")
    }

    # RedirectionConfig
    $RedirectConfig = Get-AzApplicationGatewayRedirectConfiguration -ApplicationGateway $AppGw;
    $RedirectConfig | ForEach-Object { 
        if ($_.TargetListener)
        {
            $_.TargetListener.Id = $dict[$_.TargetListener.Id].id
        }
        $dict[$_.id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }

    # Url path maps
    $urlpath = Get-AzApplicationGatewayUrlPathMapConfig -ApplicationGateway $appgw
    $urlpath | ForEach-Object { 
        $_.PathRules | ForEach-Object {
            if ($_.BackendAddressPool)
            {
                $_.BackendAddressPool.id = $dict[$_.BackendAddressPool.id].id;
            }
            if ($_.RedirectConfiguration)
            {
                $_.RedirectConfiguration.id = $dict[$_.RedirectConfiguration.id].id;
            }
            if ($_.BackendHttpSettings)
            {
                $_.BackendHttpSettings.id = $dict[$_.BackendHttpSettings.id].id;
            }
        }
        
        if ($_.DefaultBackendAddressPool)
        {
            $_.DefaultBackendAddressPool.Id = $dict[$_.DefaultBackendAddressPool.Id].id
        }
        if ($_.DefaultBackendHttpSettings)
        {
            $_.DefaultBackendHttpSettings.Id = $dict[$_.DefaultBackendHttpSettings.Id].id
        }
        if($_.DefaultRedirectConfiguration)
        {
            $_.DefaultRedirectConfiguration.Id = $dict[$_.DefaultRedirectConfiguration.Id].id
        }
        $dict[$_.Id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }




# Request Routing Rules  V 2.0 after editing for accross tenant / subscription but its using also for the same subscription scenarion and you also use the orginal block from the original microsoft script.
$Rules = Get-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $AppGW
$v2Rules = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayRequestRoutingRule]
$priority = 100
$Rules | ForEach-Object {
    if($dict.ContainsKey($_.HttpListener.Id))
    {
        $ruleName = $_.Name
        $ruleType = $_.RuleType
        $httpListenerId = $dict[$_.HttpListener.Id].id
        $backendHttpSettingsId = $null
        $backendAddressPoolId = $null
        $redirectConfigurationId = $null
        $urlPathMapId = $null

        if ($_.BackendHttpSettings -and $dict.ContainsKey($_.BackendHttpSettings.Id))
        {
            $backendHttpSettingsId = $dict[$_.BackendHttpSettings.Id].id
            $backendAddressPoolId = $dict[$_.BackendAddressPool.Id].id
        }
        elseif ($_.RedirectConfiguration.Id -and $dict.ContainsKey($_.RedirectConfiguration.Id))
        {
            $redirectConfigurationId = $dict[$_.RedirectConfiguration.Id].id
        }  
        elseif ($_.UrlPathMap.Id -and $dict.ContainsKey($_.UrlPathMap.Id))
        {
            $urlPathMapId = $dict[$_.UrlPathMap.Id].id
        }
        else {
            Write-Error "No rule can be created for $ruleName"
            return  # Skip processing this rule
        }

        # Construct the parameters for the New-AzApplicationGatewayRequestRoutingRule cmdlet
        $params = @{
            Name = $ruleName
            RuleType = $ruleType
            HttpListenerId = $httpListenerId
            Priority = $priority
        }
        if ($backendHttpSettingsId -ne $null) {
            $params.Add("BackendHttpSettingsId", $backendHttpSettingsId)
            $params.Add("BackendAddressPoolId", $backendAddressPoolId)
        }
        elseif ($redirectConfigurationId -ne $null) {
            $params.Add("RedirectConfigurationId", $redirectConfigurationId)
        }
        elseif ($urlPathMapId -ne $null) {
            $params.Add("UrlPathMapId", $urlPathMapId)
        }

        # Create the new rule using splatting
        $newRule = New-AzApplicationGatewayRequestRoutingRule @params

        # Add the new rule to the list of updated rules
        $v2Rules.Add($newRule)

        # Updating Rule Priority
        $priority += 50
    }
}


        # # Request Routing Rules   V 1.0 before accross tenant / subscription
    # $Rules = Get-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $AppGW
    # $v2Rules = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayRequestRoutingRule]
    # $priority = 100
    # $Rules | ForEach-Object {
    #     if($dict.ContainsKey($_.HttpListener.Id))
    #     {
    #         $command = "New-AzApplicationGatewayRequestRoutingRule -Name $($_.Name) -RuleType $($_.RuleType) -HttpListenerId $($dict[$_.HttpListener.Id].id) -Priority $($priority)";
    #         if ($_.BackendHttpSettings -and $dict.ContainsKey($_.BackendHttpSettings.Id))
    #         {
    #             $command += " -BackendHttpSettingsId $($dict[$_.BackendHttpSettings.Id].id) -backendAddressPoolId $($dict[$_.BackendAddressPool.Id].id)";
    #         }
    #         elseif ($_.RedirectConfiguration.Id -and $dict.ContainsKey($_.RedirectConfiguration.Id))
    #         {
    #             $command += " -RedirectConfigurationId $($dict[$_.RedirectConfiguration.Id].id)"
    #         }  
    #         elseif ($_.UrlPathMap.Id -and $dict.ContainsKey($_.UrlPathMap.Id))
    #         {
    #             $command += " -UrlPathMapId $($dict[$_.UrlPathMap.Id].id)"
    #         }
    #         else {Write-Error "No rule can be created for", $_.Name;}
    #         $z = Invoke-Expression ($command);
    #         if ($z)
    #         {
    #             $v2rules.Add($z);

    #             # Updating Rule Priority
    #             $priority += 50
    #         }
    #     }
    # }

    if ($v2Rules.count -NE $rules.count )
    {
        Write-Warning ("Failed to create Request routing rules. Please check you have given correct input and retry. Please report if the problem continues.")
        return
    }
    else
    {
        Write-Host ("Created Request Routing Rules")
    }

    # AppGateway Custom Error Config
    $customError = Get-AzApplicationGatewayCustomError -ApplicationGateway $appgw

    $sslpolicy = Get-AzApplicationGatewaySslPolicy -ApplicationGateway $AppGw
    $wafConfig = Get-AzApplicationGatewayWebApplicationFirewallConfiguration -ApplicationGateway $AppGw
    if (!$appgw.Tag) { $appgw.Tag = @{} }
    # $appgw.Tag.Add("MigratedBy", "AzureAppGWMigrationScript")
    $appgw.Tag.Add("MigratedBy", "AhmedAli-GBG")
    $appgw.Tag.Add("MigratedFrom", $AppGw.Name)

    #Verify that AppGw of same name doesn't exist
    # Original Command
    # $getAppGw = Get-AzApplicationGateway -Name $appgwname -ResourceGroupName $AppGwResourceGroupName
    # Hashed as cant supress the error if couldn`t get the app gw
    # $getAppGw = Get-AzApplicationGateway -Name $appgwname -ResourceGroupName $destinationresourceGroupName -WarningAction SilentlyContinue

    # if($getAppGw)
    # {
    #     Write-Warning ("AppGw with name $appgwname and resource group name $destinationresourceGroupName already exists. Please provide correct parameters to the script.")
    #     return
    # }else {
    #     Write-Host -ForegroundColor Green "`nGet-AzApplicationGateway validating that there is no AppGw with name $appgwname and resource group name $destinationresourceGroupName already exists"
    # }





# WAF Policy

########################################################
# Start of WAF Policy #######################################################
########################################################

  # Retrieve the WAF policy ID associated with the old Application Gateway
  $wafPolicyId = $oldAppGw.FirewallPolicy.Id
  # Extract WAF Policy Name from the waf Policy Id
  $wafPolicynameforcreation = ($wafPolicyId -split '/')[8]
  $wafpolicyresourcegroup = ($wafPolicyId -split '/')[4]
 
  # Get WAF Policy to use it in deploying
  if ($null -ne $wafPolicyId ) {
   $wafPolicy = Get-AzApplicationGatewayFirewallPolicy -Name $wafPolicynameforcreation -ResourceGroupName $wafpolicyresourcegroup
   Write-Host -ForegroundColor Green "`nFound WAF Policy 'Same Subscription scenario'."
 }else {
 Write-Host -ForegroundColor Yellow "`nNo WAF Policy 'Same Subscription scenario'."
 } 
 
 # Original Block
 if ($null -eq $wafPolicyId) {
  Write-Host -ForegroundColor Green "`nCreating WAF Policy..."
   $policy = New-AzApplicationGatewayFirewallPolicySetting -Mode "Detection"
 
   # Create WAF Policy
    Write-Host -ForegroundColor Green "`nEnter WAF Policy name e.g. WAFPolicy: "
    $wafpolictname = Read-Host
 $wafPolicy = New-AzApplicationGatewayFirewallPolicy -Name $wafpolictname -ResourceGroup $destinationresourceGroupName -Location $destinationlocation  -PolicySetting $policy
 
 # Check if the WAF Policy was created successfully
 if ($wafPolicy -ne $null) {
   Write-Host -ForegroundColor Green "WAF Policy '$($wafPolicy.Name)' created successfully."
   $wafPolicy
 } else {
   Write-Host -ForegroundColor Red "Failed to create WAF Policy."
   # You may add additional error handling or exit the script here if necessary
 }
}

Write-Host ""
Write-Host ""
# WAF Policy 'Accross Subscription scenario'.
if ($changesubscription -eq 'y') {
    Write-Host -ForegroundColor Green "`nCalling 'Accross Subscription scenario'..."
    Write-Host -ForegroundColor Yellow "`nSelect an existing WAF Policy or cancel to create new one."
    Write-Host -ForegroundColor Yellow "`WAF Policy must be in same destination subscription and destination location."
    Read-Host "Press enter to continue"
$wafPolicy = (Get-AzApplicationGatewayFirewallPolicy | Out-GridView -Title "Select an existing WAF Policy or cancel to create new one" -PassThru)
while ([string]::IsNullOrWhiteSpace($wafPolicy)) {
    Write-Host -ForegroundColor Yellow "Cancelled or no existing WAF Policies has been founded."
    sleep 2
    Write-Host -ForegroundColor Green "`nCreating WAF Policy..."
    $policy = New-AzApplicationGatewayFirewallPolicySetting -Mode "Detection"
       
    # Create WAF Policy
       Write-Host -ForegroundColor Green "`nEnter WAF Policy name e.g. WAFPolicy: "
       $wafpolictname = Read-Host
    $wafPolicy = New-AzApplicationGatewayFirewallPolicy -Name $wafpolictname -ResourceGroup $destinationresourceGroupName -Location $destinationlocation  -PolicySetting $policy
   
    if ([string]::IsNullOrWhiteSpace($wafPolicy)) {
        Write-Host ""
        Write-Host -ForegroundColor Red "`nError: Resource Group cannot be empty. Please enter a valid value."
    }
  }
} 
  

 ########################################################
 # End of WAF Policy #######################################################
 ########################################################





















    # create app gateway
    $command = 'New-AzApplicationGateway -Name $appgwname -ResourceGroupName $AppGwResourceGroupName -Location $location -Sku $(Select-Object -InputObject $sku) -GatewayIPConfigurations $(Select-Object -InputObject $gwipconfig) -FrontendIpConfigurations $(Select-Object -InputObject $fip) '
    $command += ' -FrontendPorts $(Select-Object -InputObject $FrontEndPorts) -BackendAddressPools $(Select-Object -InputObject $BackendPools) -BackendHttpSettingsCollection $(Select-Object -InputObject $SettingsList) -HttpListeners $(Select-Object -InputObject $v2listener) -RequestRoutingRules $(Select-Object -InputObject $v2rules) '
    $command += ' -Tag $appgw.Tag -Force'
    if ($enableAutoscale)
    { $command += ' -AutoScaleConfiguration $(Select-Object -InputObject $autoscaleConfig)' }
    if ($appgw.EnableHttp2)
    { $command += ' -EnableHttp2 ' }
    if ($TrustedRootCertificates)
    { $command += ' -TrustedRootCertificate $TrustedRootCertificates'}
    if($urlpath.Count -gt 0)
    { $command += ' -UrlPathMaps $($urlpath)' }
    if($probes.Count -gt 0)
    { $command += ' -Probes $(Select-Object -InputObject $probes)' }
    if($RedirectConfig.Count -gt 0)
    { $command += ' -RedirectConfigurations $(Select-Object -InputObject $RedirectConfig)' }
    if ($SslCertificates.Count -gt 0 )
    { $command += ' -SslCertificates $(Select-Object -InputObject $SslCertificates)' }
    if ($sslpolicy)
    {   $command += ' -SslPolicy $(Select-Object -InputObject $sslpolicy) ' }
    if($wafConfig)
    {   $command += ' -WebApplicationFirewallConfiguration $wafConfig' }
    if ($customError)
    {   $command += ' -CustomErrorConfiguration $customError' }
    if($appgw.Zones.Count -GT 0)
    {
        $command += ' -Zone $appgw.Zones'
    }
    if ($wafPolicy) {
        $command += ' -FirewallPolicy $wafPolicy'
    }

    Write-Warning("Creating new V2 Application Gateway / WAF may take up to ~7mins. Please wait for the command to complete.")
    $newAppGw = Invoke-Expression ($command)

    if ( $newAppGw )
    {
        Write-Host ("Successfully created V2 Application Gateway / WAF, Name : $($newAppGw.Name),`
         PublicIPAddress : $($pip.IpAddress),`
         Subnet Name (Prefix) : $($agv2Subnet.Name) ( $($agv2Subnet.AddressPrefix) )") 
    }
    else
    {
        Write-Error ("Creation of V2 Application Gateway / WAF failed. Please retry after sometime. Please contact Azure Support if error persists after several retries.")
        return
    }

    # For Virtual Machine (VM) / Virtual Machine Scale Set (VMSS) as backend,
    # set VM/VMSS NIC to point to application gateway backend pool
    $ListOfNicsToAttachToV2 = @{}
    $BackendPools | ForEach-Object {
        if ($_.BackendIpConfigurations)
        {
            $BackendPoolToAdd = Get-AzApplicationGatewayBackendAddressPool -Name $_.Name -ApplicationGateway $newAppGw
            $_.BackendIpConfigurations | ForEach-Object {
                if ($_.Id -match "/resourceGroups/(.*?)/providers/Microsoft.Network/networkInterfaces/(.*?)/ipconfigurations/" )
                {
                    $key = "VM/$($matches[1])/$($matches[2])"
                    $obj = @{
                        type = "VM"
                        resourceGroup = $matches[1]
                        nicname = $matches[2]
                        backendpool = $BackendPoolToAdd
                    }
                    $ListOfNicsToAttachToV2[$key] = $obj
                }
                elseif ($_.Id -match "/resourceGroups/(.*?)/providers/Microsoft.Compute/virtualMachineScaleSets/(.*?)/virtualMachines/(.*?)/networkInterfaces/(.*?)/ipConfigurations/")
                {
                    $key = "VMSS/$($matches[1])/$($matches[2])"
                    if(!$ListOfNicsToAttachToV2.ContainsKey($key))
                    {
                        $obj = @{
                            type = "VMSS"
                            resourceGroup = $matches[1]
                            vmssname = $matches[2]
                            nicList = @($matches[4])
                            instances = @($matches[3])
                            backendpool = $BackendPoolToAdd
                        }
                        $ListOfNicsToAttachToV2[$key] = $obj
                    }
                    else
                    {
                        $ListOfNicsToAttachToV2[$key].nicList += $matches[4]
                        $ListOfNicsToAttachToV2[$key].instances += $matches[3]
                    }
                }
                else
                {
                    Write-Error ("Unsupported backend address pool config for '$($BackendPoolToAdd.Name)', could not be migrated.")
                }
            }
        }
    }

    $jobs = @()
    $ListOfNicsToAttachToV2.Values | ForEach-Object { 
        if ($_.type -eq "VM")
        {
            $jobs += Start-Job -ScriptBlock $AttachVmNetworkInterface -ArgumentList ($_.nicname, $_.resourceGroup, $_.backendpool)
        }
        else
        {
            $jobs += Start-Job -ScriptBlock $AttachVmssNetworkInterface -ArgumentList @($_.vmssname, $_.nicList, $_.resourceGroup, $_.backendpool, $_.instances)
        }
    }
    if ($jobs)
    {
        Write-Host "Attaching backend pool VM/VMSS NICs to v2 application gateway"
        Wait-Job -Job $jobs | Out-Null
        $jobResponses = Receive-Job -Job $jobs
        if (($jobResponses | Where-Object { $_ -eq $false }).count -NE 0)
        {
            Write-Error ("Could not sucessfully configure VM/VMSS in backend pool. Please retry the script after some time.") 
            exit
        }
    }

    $sw.Stop()
    $migrationCompleted = $true
    if ($validateMigration)
    {
        # compare backend health for v1 and v2 app gateway
        $x = Get-AzApplicationGatewayBackendHealth -Name $V1AppGwName -ResourceGroupName $resourcegroup
        $y = Get-AzApplicationGatewayBackendHealth -Name $AppGwName -ResourceGroupName $AppGwResourceGroupName
        for ($i = 0; $i -lt $x.BackendAddressPools.Count; $i++) {
            $x1 = $x.BackendAddressPools[$i].BackendHttpSettingsCollection
            $y1 = $y.BackendAddressPools[$i].BackendHttpSettingsCollection
            $dict = @{}
            for ($j = 0; $j -lt $x1.Count; $j++) {
                $x1[$j].Servers | ForEach-Object { $dict[$_.Address] = $_.Health }
                $y1[$j].Servers | ForEach-Object { 
                    if ($_.Health -EQ $dict[$_.Address]) {
                        Write-Host ("Backend Health reported equal for - $($_.Address) ")
                    }
                    else {
                        Write-Warning ("Backend Health reported difference for - $($_.Address), v1 - $($dict[$_.Address]), v2 - $($_.health)")
                    }
                }
            }
        }
    }
    
    return $newAppGw
}
catch [Exception]
{
    Write-Output $_.Exception | format-list -force
}
finally
{
    if ($migrationCompleted -EQ $false)
    {
        cleanup
        Cleanuppreparation
    }
    else 
    {
        Write-Host -ForegroundColor Green ("V1/V2 APP GW Migration/Cloning Complete. TimeTaken : $($sw.Elapsed.TotalSeconds) seconds")
    }
}
# SIG # Begin signature block
# MIInxAYJKoZIhvcNAQcCoIIntTCCJ7ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDFzl8gS0zLkkMI
# Zi/Tu2tCf9lx9dOgdbiQCPiuLfwTs6CCDXYwggX0MIID3KADAgECAhMzAAADTrU8
# esGEb+srAAAAAANOMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjMwMzE2MTg0MzI5WhcNMjQwMzE0MTg0MzI5WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDdCKiNI6IBFWuvJUmf6WdOJqZmIwYs5G7AJD5UbcL6tsC+EBPDbr36pFGo1bsU
# p53nRyFYnncoMg8FK0d8jLlw0lgexDDr7gicf2zOBFWqfv/nSLwzJFNP5W03DF/1
# 1oZ12rSFqGlm+O46cRjTDFBpMRCZZGddZlRBjivby0eI1VgTD1TvAdfBYQe82fhm
# WQkYR/lWmAK+vW/1+bO7jHaxXTNCxLIBW07F8PBjUcwFxxyfbe2mHB4h1L4U0Ofa
# +HX/aREQ7SqYZz59sXM2ySOfvYyIjnqSO80NGBaz5DvzIG88J0+BNhOu2jl6Dfcq
# jYQs1H/PMSQIK6E7lXDXSpXzAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUnMc7Zn/ukKBsBiWkwdNfsN5pdwAw
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwMDUxNjAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAD21v9pHoLdBSNlFAjmk
# mx4XxOZAPsVxxXbDyQv1+kGDe9XpgBnT1lXnx7JDpFMKBwAyIwdInmvhK9pGBa31
# TyeL3p7R2s0L8SABPPRJHAEk4NHpBXxHjm4TKjezAbSqqbgsy10Y7KApy+9UrKa2
# kGmsuASsk95PVm5vem7OmTs42vm0BJUU+JPQLg8Y/sdj3TtSfLYYZAaJwTAIgi7d
# hzn5hatLo7Dhz+4T+MrFd+6LUa2U3zr97QwzDthx+RP9/RZnur4inzSQsG5DCVIM
# pA1l2NWEA3KAca0tI2l6hQNYsaKL1kefdfHCrPxEry8onJjyGGv9YKoLv6AOO7Oh
# JEmbQlz/xksYG2N/JSOJ+QqYpGTEuYFYVWain7He6jgb41JbpOGKDdE/b+V2q/gX
# UgFe2gdwTpCDsvh8SMRoq1/BNXcr7iTAU38Vgr83iVtPYmFhZOVM0ULp/kKTVoir
# IpP2KCxT4OekOctt8grYnhJ16QMjmMv5o53hjNFXOxigkQWYzUO+6w50g0FAeFa8
# 5ugCCB6lXEk21FFB1FdIHpjSQf+LP/W2OV/HfhC3uTPgKbRtXo83TZYEudooyZ/A
# Vu08sibZ3MkGOJORLERNwKm2G7oqdOv4Qj8Z0JrGgMzj46NFKAxkLSpE5oHQYP1H
# tPx1lPfD7iNSbJsP6LiUHXH1MIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGaQwghmgAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAANOtTx6wYRv6ysAAAAAA04wDQYJYIZIAWUDBAIB
# BQCggbAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIKL7AX/NU28G72hCFXSDrVkN
# 2z7mY04nAz297f4Nk7ZhMEQGCisGAQQBgjcCAQwxNjA0oBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEcgBpodHRwczovL3d3dy5taWNyb3NvZnQuY29tIDANBgkqhkiG9w0B
# AQEFAASCAQCR0s4nErLrcR0C7AXNRG1KNi7Q5w3U8RJPksWQjC29Gr4qWp/20+3K
# 6maYDTl548AjVYKrS5uzwuA/sKdZKjlmunpUVg+szjxPKVHTdIlWm7PEHjdgm0Xk
# 2J/zETxbLmyznXghH3ArAqEu3ED9sfk6XMnaFOGvbNWQeQycqoPIB6AfuNcG/zIS
# 05b0hK0WXrQPku21R2tGK+oHNIyv1gt6sAEMRxgHQnFy16z4SB12QHVOCDCy5b0F
# J5Akuh5IqoTAAZtILUrh1K1D5uUohSLd6OrhRCyK/N8u7X2XeLn/+W0VNoI3WzI6
# PuGFrz5Ie8nIPwdFSE0FCU2O+WSiK8oQoYIXLDCCFygGCisGAQQBgjcDAwExghcY
# MIIXFAYJKoZIhvcNAQcCoIIXBTCCFwECAQMxDzANBglghkgBZQMEAgEFADCCAVkG
# CyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZI
# AWUDBAIBBQAEIF9yVBvWfTFKr6kQIiNptbMX0gyFjgPn4WtacuGKiiD+AgZkyYnz
# vAAYEzIwMjMwODA4MTEzNTExLjY5NFowBIACAfSggdikgdUwgdIxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJ
# cmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhhbGVzIFRTUyBF
# U046MkFENC00QjkyLUZBMDExJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFNlcnZpY2WgghF7MIIHJzCCBQ+gAwIBAgITMwAAAbHKkEPuC/ADqwABAAABsTAN
# BgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0y
# MjA5MjAyMDIxNTlaFw0yMzEyMTQyMDIxNTlaMIHSMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBP
# cGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjJBRDQt
# NEI5Mi1GQTAxMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNl
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAhqKrPtXsG8fsg4w8R4Mz
# ZTAKkzwvEBQ94ntS+72rRGIMF0GCyEL9IOt7f9gkGoamfbtrtdY4y+KIFR8w19/n
# U3EoWhJfrYamrfpgtFmTaE3XCKCsI7rnrPmlVOMmndDyN1gAlfeu4l5rdxx9ODEC
# BPdS/+w/jDT7JkBhrYllqVXcwGAgWLdXAoUDgKVByv5XhKkbOrPx9qppuZjKm4nf
# lmfwb/bTWkA3aMMQ67tBoMLSsbIN3BJNWZdwczjoQVXo3YXr2fB+PYNmHviCcDUM
# Hs0Vxmf7i/WSpBafsDMEn6WY7G8qtRGVX+7X0zDVg/7NVDLMqfn/iv++5hJGP+2F
# mv4WZkBS1MBpwvOi4EQ25pIG45jWTffR4ynyed1I1SxSOP+efuBx0WrN1A250lv5
# fGZHCL0vCMDT/w+U6wpNnxfDoQRY9Ut82iNK5alkxNozPP/DNI+nknTaSliaR2Xn
# SXDIZEs7lfuJYg0qahfJJ1CZF2IYxOS9FK1crEigSb8QnEJoj6ThLf4FYpYLTsRX
# lPdQbvBsVvgt++BttooznwfK0DKMOc718SLS+unwkVO0aF23CEQSStoy0ZW34K+c
# bRmUfia+k9E+4luoTnT17oKqYfDNO5Rk8UwVa8mfh8+/R3fZaz2O/ZhiYT/RZHV9
# Quz5PHGlaCfXPQ8A6zFJlE8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBT0m2eR7w2t
# hIr18WehUTSmvQ45kzAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBf
# BgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L2NybC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmww
# bAYIKwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEA2Oc3kmql5VKE
# itAhoBCc1U6/VwMSYKQPqhC59f00Y5fbwnD+B2Qa0wnJqADSVVu6bBCVrks+EGbk
# uMhRb/lpiHNKVnuXF4PKTDnvCnYCqgwAmbttdxe0m38fJpGU3fmECEFX4OYacEhF
# wTkLZtIUVjdqwPnQpRII+YqX/Q0Vp096g2puPllSdrxUB8xIOx3F7LGOzyv/1Wmr
# LyWAhUGpGte0W3qfX4YWkn7YCM+yl887tj5j+jO/l1MRi6bl4MsN0PW2FCYeRbyz
# QEENsg5Pd351Z08ROR/nR8z+cAuQwR29ijaDKIms5IbRr1nZL/qZskFSuCuSA+nY
# eMuTJxHg2HCXrt6ECFbEkYoPaBGTzxPYopcuJEcChhNlWkduCRguykEsmz0LvtmS
# 7Fe68g4Zoh3sQkIE5VEwnKC3HwVemhK7eNYR1q7RYExfGFUDMQdO7tQpbcPD4oaB
# btFGWGu3nz1IryWs9K88zo8+eoQV/o9SxNU7Rs6TMqcLdM6C6LgmGVaWKKC0S2DV
# KU8zFx0y5z25h1ZJ7X/Zhaav1mtXVG6+lJIq8ktJgOU5/pomumdftgosxGjIp3NO
# Ry9fDUll+KQl4YmN9GzZxPYkhuI0QYriLmytBtUK+AK91hURVldVbUjP8sksr1ds
# iQwyOYQIkSxrTuhp0pw7h5329jphgEYwggdxMIIFWaADAgECAhMzAAAAFcXna54C
# m0mZAAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZp
# Y2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMy
# MjVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51
# yMo1V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY
# 6GB9alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9
# cmmvHaus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN
# 7928jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDua
# Rr3tpK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74
# kpEeHT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2
# K26oElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5
# TI4CvEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZk
# i1ugpoMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9Q
# BXpsxREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3Pmri
# Lq0CAwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUC
# BBYEFCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJl
# pxtTNRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9y
# eS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUA
# YgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# 1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIw
# MTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/yp
# b+pcFLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulm
# ZzpTTd2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM
# 9W0jVOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECW
# OKz3+SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4
# FOmRsqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3Uw
# xTSwethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPX
# fx5bRAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVX
# VAmxaQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGC
# onsXHRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU
# 5nR0W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEG
# ahC0HVUzWLOhcGbyoYIC1zCCAkACAQEwggEAoYHYpIHVMIHSMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJl
# bGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNO
# OjJBRDQtNEI5Mi1GQTAxMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBT
# ZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDtZLG+pANsDu/LLr1OfTA/kEbHK6CBgzCB
# gKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBBQUA
# AgUA6HyZmDAiGA8yMDIzMDgwODE4MzgxNloYDzIwMjMwODA5MTgzODE2WjB3MD0G
# CisGAQQBhFkKBAExLzAtMAoCBQDofJmYAgEAMAoCAQACAgNgAgH/MAcCAQACAhFJ
# MAoCBQDofesYAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAI
# AgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQEFBQADgYEAPxExMgH5IGHI
# WTGOOARpWpoDcyy8oIVRtN9yVNnM0wGc9Fo4hMNFtHLNnua38sc1xFRF6AqPVvyE
# n80RmU40l8//SkKb1hCtUigFi2yi8KPlA7AEqCL3gHh0rTAZ2SyllNCXprfYzCLv
# 4nEPxsonG6yUGtJp4EsG8wtnAze4UbcxggQNMIIECQIBATCBkzB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAbHKkEPuC/ADqwABAAABsTANBglghkgB
# ZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3
# DQEJBDEiBCA3wl7shnxBk2TVlAaRw8EY5KQ7DLIobgtq8efVyGSnHjCB+gYLKoZI
# hvcNAQkQAi8xgeowgecwgeQwgb0EIIPtDYsUW9+p4OjL2Cm7fm3p1h6usM7RwxOU
# 4iibNM9sMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMA
# AAGxypBD7gvwA6sAAQAAAbEwIgQg1MXR35vtL9wHZel/WGqo5x8yNJ70VqSflwdT
# gUvbO2EwDQYJKoZIhvcNAQELBQAEggIANw2ULRAsZABv4dVhom2Bui82cyGfq/eE
# 1tuXTivDhktw00Nbua0tfGqoHXn0Wr/Ffpiutgyu7Cel5u9OdKhxAlJNrarqwRwE
# i/epIL6amTwMRAiI2iU+dSjhSHT3gjwuGhFdWVhbcOkcGqbWBWWBCVo1DJOleS+T
# 4Wr/axVF97hY9bAbne8QzZlyNzAV1gHu8aiiSAl3S7zsGvyI8nrYY+6vZWqkob9J
# rw7iRsoKcEKbP3vW81dkc3TQwWSsIdkv+Cy2i+lLM1xF+0aM0cpgBBKNf8R+eXCt
# 7wRS0ec93vD0EbLTP0Hj2fS17LFMy/scqFPqEkLL124mZ/kjEBi8H9ym5BjGznb6
# cMBkeiPHg7O3JSExGNZkbmxN+EdTnVdW6ol+9dv648Ce/4TLTRUaZOdEbsNkQHtU
# pu0g+CyRPtlbqkBQ2L3I4x0gsen6CpcHOeXDc2FptdKiNbAYOtPbBGKtkI/xDM7p
# M9FZxOyOT0sDFlQbTKPihn8LDG+oqjQlzoeZCYjpoZ6G6ZQSpvdCcuTVEYe8wMw1
# E8Ezhph6fzMhZEBkRpLCn6vosMigYQCQQWJ54NywMXNBGop3aNI5Rn9uuNFkP+74
# PLiqxzW4HRua6/B/wQPR3RuULpt/EEGVFM4mCWBa/pmC81SAkdXX280+744t1GuZ
# hZuHlHyfxMU=
# SIG # End signature block
