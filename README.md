# vSphere-MTK
vSphere Migration Toolkit

## SYNOPSIS

    When provided with a valid CSV, this script will deploy the VMs in the CSV to the VMM Cloud specified according to the provided parameters.
    The script will also rename the VHDXs to include the name of the VM, instead of just the name from the template.

## DESCRIPTION

### Prerequisites

        1. Powershell 4.0
        2. VirtualMachineManager module installed, with proper privileges to the VMM server.

### Assumptions

        1. The templates referenced from VMM include 3 VHDs; the first being the OS, second being pagefile, third being app - Edit designated sections for alterations
        2. This script assumes each 'Cloud' uses a separate vmswitch, edit the names of those virtual swithces accordingly.
        3. The combined build time of all virtual machines is less than 4 hours. The cleanup phase starts after all jobs complete, or 4 hours - whichever comes first.

## PARAMETER PathtoCSV

    Required parameter. Full or relative path to csv file that includes fields: VMName, Template, Cloud, NameofComputer,Description,VMNetwork, OS,
    CPUs, StartupMem, MinimumMem, and MaximumMem. CSV Provided in Repo

## EXAMPLE

    Usage:
    > VMDeploy.ps1 -PathtoCSV "C:\VMsToCreate.csv"

## NOTES

    Author: wmilliron
    Date: 11/3/2017

    Future releases will include
    * Improved error handling
    * Timeout increase based on number of created VMs