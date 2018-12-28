# vSphere-MTK
The **vSphere Migration Toolkit** is a community-created and supported PowerShell module that provides a set of tools to facilitate the migration of Microsoft Windows workloads into vSphere.

## DESCRIPTION

### Background
When migrating workloads running Windows Server operating systems from a physical machine or another hypervisor into vSphere, there are several post-migration tasks that are commonly performed manually to complete the migration procedure.
This module offers a toolset to facilitate those tasks in order to reduce downtime for the services provided by the workload.

### Prerequisites

        1. Powershell 4.0
        2. PowerCLI
        3. Administrative credentials to the vSphere environment as well as within the OS of the target workload

## Available Commands

|Command|Migration Phase|Description|
|-------|---------------|---|
|**Get-IPInfo**|Pre-Migration|Collects all IP information from all network adapters, and exports them to a CSV|
|**Set-IPInfo**|Post-Migration|Injects the IP information harvested from Get-IPInfo into the migrated machine|
|**Convert-SCSItoParavirtual**|Post-Migration|Converts the SCSI controller used by a VM to the Paravirtual class|

## Changelog

__1.0.0__ First official release with three available commands: Get-IPInfo, Set-IPInfo, and Convert-SCSItoParavirtual

## NOTES

    Author: Wes Milliron

    Future releases will include
    - Get-Help information for each cmdlet
    - Support for running multiple workloads in parallel
    - Additional cmdlets, including removing absent ("ghost") hardware, etc.