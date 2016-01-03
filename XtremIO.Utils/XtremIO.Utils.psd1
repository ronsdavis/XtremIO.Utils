#
# Module manifest for module 'XtremIO.Utils'
#
# Generated by: Matt Boren
#
# Generated on: 1/3/2016
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'XtremIO_UtilsMod.psm1'

# Version number of this module.
ModuleVersion = '0.9.6'

# ID used to uniquely identify this module
GUID = '89438b0b-d0b3-4444-9101-8c2a27327fc4'

# Author of this module
Author = 'Matt Boren'

# Company or vendor of this module
CompanyName = 'None'

# Copyright statement for this module
Copyright = 'None'

# Description of the functionality provided by this module
Description = 'Module with functions to interact with XtremIO management server (XMS appliance) via RESTful API'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '4.0'

# Name of the Windows PowerShell host required by this module
# PowerShellHostName = ''

# Minimum version of the Windows PowerShell host required by this module
# PowerShellHostVersion = ''

# Minimum version of Microsoft .NET Framework required by this module
# DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module
# CLRVersion = ''

# Processor architecture (None, X86, Amd64) required by this module
# ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
# RequiredModules = @()

# Assemblies that must be loaded prior to importing this module
# RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module.
# ScriptsToProcess = @()

# Type files (.ps1xml) to be loaded when importing this module
# TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
FormatsToProcess = 'XioInfo.format.ps1xml'

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
NestedModules = @('XIO_SupportingFunctions.ps1')

# Functions to export from this module
FunctionsToExport = '*'

# Cmdlets to export from this module
CmdletsToExport = '*'

# Variables to export from this module
VariablesToExport = '*'

# Aliases to export from this module
AliasesToExport = '*'

# List of all modules packaged with this module
# ModuleList = @()

# List of all files packaged with this module
FileList = 'XtremIO.Utils.psd1', 'XtremIO.Utils.init.ps1', 
               'XtremIO_UtilsMod.psm1', 'XIO_SupportingFunctions.ps1', 
               'GetXIOItem.ps1', 'NewXIOItem.ps1', 'OtherXIOMgmt.ps1', 
               'XioInfo.format.ps1xml', 'configItems.ps1'

# Private data to pass to the module specified in RootModule/ModuleToProcess
# PrivateData = ''

# HelpInfo URI of this module
# HelpInfoURI = ''

# Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
# DefaultCommandPrefix = ''

}


