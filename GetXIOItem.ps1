<#	.Description
	Function to get XtremIO item info using REST API with XtremIO XMS appliance; Apr 2014, Matt Boren.  Tries to do some auto-detection of the API version (and, so, the URIs to use) by determining on which port the XMS appliance is listening for API requests.  There was a change from v2.2.2 to v2.2.3 of the XMS appliances in which they stopped listening on the non-SSL port 42503, and began listening on 443.
	.Example
	Get-XIOItemInfo -ComputerName somexmsappl01.dom.com
	Request info from XMS appliance "somexmsappl01" and return an object with the "cluster" info for the logical storage entity defined on the array
	.Example
	Get-XIOItemInfo -ComputerName somexmsappl01.dom.com -ItemType initiator
	Return some objects with info about the defined intiators on the given XMS appliance
	.Example
	Get-XIOItemInfo -ComputerName somexmsappl01.dom.com -ItemType volume
	Return objects with info about each LUN mapping on the XMS appliance
	.Example
	Get-XIOItemInfo -ComputerName somexmsappl01.dom.com -ItemType cluster -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOItemInfo {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to which to connect
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName_arr,
		## Item type for which to get info; currently supported types:
		##   for all API versions:                "cluster", "initiator-group", "initiator", "lun-map", target-group", "target", "volume"
		##   and, for API versions 2.2.3 and up:  "brick", "snapshot", "ssd", "storage-controller", "xenv"
		##   and, for API versions 2.4 and up:    "data-protection-group", "event", "ig-folder", "volume-folder"
		[parameter(ParameterSetName="ByComputerName")]
		[ValidateSet("cluster", "data-protection-group", "event", "ig-folder", "initiator-group", "initiator", "lun-map", "target-group", "target", "volume", "volume-folder", "brick", "snapshot", "ssd", "storage-controller", "xenv")]
		[string]$ItemType_str = "cluster",
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Additional parameters to use in the REST call (like those used to return a subset of events instead of all)
		[ValidateScript({$_ -match "^/\?.+"})][string]$AdditionalURIParam,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

<#  items to populate in begin:
## Credential for connecting to XMS appliance; if a credential has been encrypted and saved, this will automatically use that credential
[System.Management.Automation.PSCredential]$Credential = $(_Find-CredentialToUse),
## Port to use for API call (if none, will try to autodetect proper port; may be slightly slower due to port probe activity)
[parameter(ParameterSetName="ByComputerName")][int]$Port_int,
## switch: Trust all certs?  Not necessarily secure, but can be used if the XMS appliance is known/trusted, and has, say, a self-signed cert
[switch]$TrustAllCert_sw,

remove:
## Authentication type; default is "basic"
[ValidateSet("basic")][string]$AuthType_str = "basic",

#>

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## get the XIO connections to use
		$arrXioConnectionsToUse = Get-XioConnectionsToUse -ComputerName $(
			Switch ($PSCmdlet.ParameterSetName) {
				"ByComputerName" {$ComputerName_arr; break}
				"SpecifyFullUri" {([System.Uri]($URI_str)).DnsSafeHost; break}
			})
	} ## end begin

	Process {
		## iterate through the list of $arrXioConnectionsToUse
		$arrXioConnectionsToUse | Foreach-Object {
			$oThisXioConnection = $_
			$arrDataHashtablesForGettingXioInfo = @()
			## if full URI specified, use it to populate hashtables for getting XIO info
			if ($PSCmdlet.ParameterSetName -eq "SpecifyFullUri") {
				## get the plural item type from the URI (the part of the URI after "/types/")
				$strItemType_plural = Get-ItemTypeFromURI -URI $URI_str
				$arrDataHashtablesForGettingXioInfo += @{
					## the computer name, to be used for a value in the return object
					ComputerName = ([System.Uri]($URI_str)).DnsSafeHost
					arrHrefsToGetItemsInfo = $URI_str
				} ## end hashtable
			} ## end if
			## else, specifying computer name and some other attributes (not full URI)
			else {
				## from the param value, make the plural form (the item types in the API are all plural; adding "s" here to the singular form used for valid param values, the singular form being the standard for PowerShell-y things)
				$strItemType_plural = "${ItemType_str}s"
				## the base portion of the REST command to issue
				$strRestCmd_base = "/types/$strItemType_plural"

				## this XMS appliance name
				$strThisXmsName = $oThisXioConnection.ComputerName

				## if the item type is "event"
				if ($ItemType_str -eq "event") {
					## REST command to use (with URIParams added, if any)
					$strRestCommandWithAnyAddlParams = if ($PSBoundParameters.ContainsKey("AdditionalURIParam")) {"$strRestCmd_base$AdditionalURIParam"} else {$strRestCmd_base}
					## populate the array of hashtables for getting XIO info with just one computername/HREF hashtable
					$arrDataHashtablesForGettingXioInfo += @{
						ComputerName = $strThisXmsName
						arrHrefsToGetItemsInfo = New-XioApiURI -ComputerName $strThisXmsName -RestCommand $strRestCommandWithAnyAddlParams
					} ## end hashtable
				} ## end if
				## do all the necessary things to populate $arrDataHashtablesForGettingXioInfo with individual XIO item's HREFs
				else { ## making arrDataHashtablesForGettingXioInfo
					## for this XMS appliance name, get a hashtable with computer name and HREFs for which to get info obj
					$hshParamsForGetXioInfo_allItemsOfThisType = @{
						Credential = $oThisXioConnection.Credential
						ComputerName_str = $strThisXmsName
						RestCommand_str = "$strRestCmd_base"
						Port_int = $oThisXioConnection.Port
						TrustAllCert_sw = $oThisXioConnection.TrustAllCert
					} ## end hsh
					## the base info for all items of this type known by this XMS appliance (href & name pairs)
					## the general pattern:  the property returned is named the same as the item type
					#   however, not the case with volume-folders and ig-folders:  the property is "folders"; so, need to use "folders" if either of those two types are used here
					$strPropertyNameToAccess = Switch ($strItemType_plural) {
													{"volume-folders","ig-folders" -contains $_} {"folders"; break}
													default {$strItemType_plural}
												} ## end switch
					## get the HREF->Name objects for this type of item
					$arrKnownItemsOfThisTypeHrefInfo = (Get-XIOInfo @hshParamsForGetXioInfo_allItemsOfThisType).$strPropertyNameToAccess

					## get the API Hrefs for getting the detailed info for the desired items (specified items, or all items of this type)
					$arrHrefsToGetItemsInfo_thisXmsAppl =
						## if particular initiator names specified, get just the hrefs for those
						if ($PSBoundParameters.ContainsKey("Name_arr")) {
							$Name_arr | Select-Object -Unique | Foreach-Object {
								$strThisItemNameToGet = $_
								## if any of the names are like the specified name, add those HREFs to the array of HREFs to get
								if ( (($arrKnownItemsOfThisTypeHrefInfo | Foreach-Object {$_.Name}) -like $strThisItemNameToGet | Measure-Object).Count -gt 0 ) {
									($arrKnownItemsOfThisTypeHrefInfo | Where-Object {$_.Name -like $strThisItemNameToGet}).href
								} ## end if
								else {Write-Verbose "$strLogEntry_ToAdd No '$ItemType_str' item of name '$_' found on '$strThisXmsName'. Valid item name/type pair?"}
							} ## end foreach-object
						} ## end if
						## else, getting all initiators known; get all the hrefs
						else {$arrKnownItemsOfThisTypeHrefInfo | Foreach-Object {$_.href}} ## end else

					## if there are HREFs from which to get info, add new hashtable to the overall array
					if (($arrHrefsToGetItemsInfo_thisXmsAppl | Measure-Object).Count -gt 0) {
						$arrDataHashtablesForGettingXioInfo += @{
							ComputerName = $strThisXmsName
							## HREFs to get are the unique HREFs (depending on the -Name value provided, user might have made overlapping matches)
							arrHrefsToGetItemsInfo = $arrHrefsToGetItemsInfo_thisXmsAppl | Select-Object -Unique
						} ## end hashtable
					} ## end if
				} ## end else "making arrDataHashtablesForGettingXioInfo"
			} ## end else "not full URI"

			## if there are hrefs from which to get item info, do so for each
			if ($arrDataHashtablesForGettingXioInfo) {
				#Write-Debug "$strLogEntry_ToAdd Soon to make custom objects from Get-XIOInfo returns; num arrays to contact: '$(($arrDataHashtablesForGettingXioInfo | Measure-Object).Count)'"
				foreach ($hshDataForGettingInfoFromThisXmsAppl in $arrDataHashtablesForGettingXioInfo) {
					$hshDataForGettingInfoFromThisXmsAppl.arrHrefsToGetItemsInfo | Foreach-Object {
						## make the params hash for this item
						$hshParamsForGetXioInfo_thisItem = @{
							Credential = $oThisXioConnection.Credential
							URI_str = $_
						} ## end hsh
						$hshParamsForGetXioInfo_thisItem["TrustAllCert_sw"] = $oThisXioConnection.TrustAllCert
						## call main Get-Info function with given params, getting a web response object back
						$oResponseCustObj = Get-XIOInfo @hshParamsForGetXioInfo_thisItem

						if ($ReturnFullResponse_sw) {$oResponseCustObj} else {
							## FYI:  for all types except Events, $oResponseCustObj is an array of items whose Content property is a PSCustomObject with all of the juicy properties of info
							##   for type Events, $oResponseCustObj is one object with an Events property, which is an array of PSCustomObject
							$oResponseCustObj | Foreach-Object {
								$oThisResponseObj = $_
								## the URI of this item (or of all of the events, if this item type is "events", due to the difference in the way event objects are returned from API)
								$strUriThisItem = ($oThisResponseObj.Links | Where-Object {$_.Rel -eq "Self"}).Href
								## FYI:  name of the property of the response object that holds the details about the XIO item is "Content" for nearly all types, but "events" for event type
								## if the item type is events, access the "events" property of the response object; else, access the "Content" property
								$(if ($strItemType_plural -eq "events") {$oThisResponseObj.$strItemType_plural} else {$oThisResponseObj."Content"}) | Foreach-Object {
									$oThisResponseObjectContent = $_
									## make a new object with some juicy info (and a new property for the XMS "computer" name used here)
									$oObjToReturn = _New-Object_fromItemTypeAndContent -argItemType $strItemType_plural -oContent $oThisResponseObjectContent |
										## add ComputerName property
										Add-Member -Name "ComputerName" -MemberType NoteProperty -Value $hshDataForGettingInfoFromThisXmsAppl["ComputerName"] -PassThru |
										## add a URI property that uniquely identifies this object
										Add-Member -Name "Uri" -MemberType NoteProperty -Value $strUriThisItem -PassThru
									## add a TypeName to the TypeNames collection; this is for use by PS custom formatting; ref: http://msdn.microsoft.com/en-us/library/system.management.automation.psobject.typenames%28v=vs.85%29.aspx
									$oObjToReturn.PSObject.TypeNames.Insert(0, "XioItemInfo.$((Get-Culture).TextInfo.ToTitleCase($strItemType_plural.TrimEnd('s').ToLower()))")
									## return the object
									return $oObjToReturn
								} ## end foreach-object
							} ## end foreach-object
						} ## end else
					} ## end foreach-object
				} ## end foreach
			} ## end if
		} ## end foreach-object
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO brick info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOBrick
	Request info from current XMS connection and return an object with the "brick" info for the logical storage entity defined on the array
	.Example
	Get-XIOBrick X3
	Get the "brick" named X3
	.Example
	Get-XIOBrick -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOBrick {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Brick])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "brick"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO cluster info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOCluster
	Request info from current XMS connection and return an object with the "cluster" info for the logical storage entity defined on the array
	.Example
	Get-XIOCluster myCluster
	Get the "cluster" named myCluster
	.Example
	Get-XIOCluster -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOCluster {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Cluster])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "cluster"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO data-protection-group info using REST API from XtremIO XMS appliance
	.Example
	Get-XIODataProtectionGroup
	Request info from current XMS connection and return an object with the "data-protection-group" info for the logical storage entity defined on the array
	.Example
	Get-XIODataProtectionGroup X[34]-DPG
	Get the "data-protection-group" objects named X3-DPG and X4-DPG
	.Example
	Get-XIODataProtectionGroup -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIODataProtectionGroup {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "data-protection-group"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO initiator info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOInitiator
	Request info from current XMS connection and return an object with the "initiator" info for the logical storage entity defined on the array
	.Example
	Get-XIOInitiator mysvr-hba*
	Get the "initiator" objects whose name are like mysvr-hba*
	.Example
	Get-XIOInitiator -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiator {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Initiator])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "initiator"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO initiator group info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOInitiatorGroup
	Request info from current XMS connection and return an object with the "initiator group" info for the logical storage entity defined on the array
	.Example
	Get-XIOInitiatorGroup whatchamacallit
	Get the "initiator group" named whatchamacallit
	.Example
	Get-XIOInitiatorGroup -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiatorGroup {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "initiator-group"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO initiator group folder info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOInitiatorGroupFolder
	Request info from current XMS connection and return an object with the "initiator group folder" info for the logical storage entity defined on the array
	.Example
	Get-XIOInitiatorGroupFolder /someVC/someCluster
	Get the "initiator group folder" named /someVC/someCluster
	.Example
	Get-XIOInitiatorGroupFolder -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiatorGroupFolder {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "ig-folder"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO LUN map info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOLunMap
	Request info from current XMS connection and return an object with the "LUN map" info for the logical storage entity defined on the array
	.Example
	Get-XIOLunMap -Volume myVolume0
	Get the "LUN map" objects for volume myVolume0
	.Example
	Get-XIOLunMap -InitiatorGroup someig* -Volume *2[23]
	Get the "LUN map" objects for initator groups with names like someig* and whose volume names end with 22 or 23
	.Example
	Get-XIOLunMap -HostLunId 21,22
	Get the "LUN map" objects defined with LUN IDs 21 or 22
	.Example
	Get-XIOLunMap -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOLunMap {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Volume name(s) for which to get LUN mapping info (or, all volumes' mappings if no name specified here)
		[parameter(ParameterSetName="ByComputerName")][string[]]$Volume,
		## Specific initiator group for which to get LUN mapping info; if not specified, return all
		[parameter(ParameterSetName="ByComputerName")][string[]]$InitiatorGroup,
		## LUN ID on which to filter returned LUN mapping info; if not specified, return all
		[parameter(ParameterSetName="ByComputerName")][int[]]$HostLunId,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "lun-map"
		## initialize new hashtable to hold params for Get-XIOItemInfo call
		$hshParamsForGetXioItemInfo = @{ItemType = $ItemType_str}
	} ## end begin

	Process {
		## get the params for Get-XIOItemInfo (exclude some choice params)
		$PSBoundParameters.Keys | Where-Object {"Volume","InitiatorGroup","HostLunId" -notcontains $_} | Foreach-Object {$hshParamsForGetXIOItemInfo[$_] = $PSBoundParameters[$_]}
		## call the base function to get the given item
		$arrItemsToReturn = Get-XIOItemInfo @hshParamsForGetXioItemInfo
		## if the Volume was specified, return just LUN mappings involving that volume
		if ($PSBoundParameters.ContainsKey("Volume")) {$arrItemsToReturn = $arrItemsToReturn | Where-Object {$oThisItem = $_; ($Volume | Where-Object {$oThisItem.VolumeName -like $_}).Count -gt 0}}
		## if the InitiatorGroup was specified, return just LUN mappings involving that InitiatorGroup
		if ($PSBoundParameters.ContainsKey("InitiatorGroup")) {$arrItemsToReturn = $arrItemsToReturn | Where-Object {$oThisItem = $_; ($InitiatorGroup | Where-Object {$oThisItem.InitiatorGroup -like $_}).Count -gt 0}}
		## if the InitiatorGroup was specified, return just LUN mappings involving that InitiatorGroup
		if ($PSBoundParameters.ContainsKey("HostLunId")) {$arrItemsToReturn = $arrItemsToReturn | Where-Object {$HostLunId -contains $_.LunId}}
		return $arrItemsToReturn
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO snapshot info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOSnapshot
	Request info from current XMS connection and return an object with the "snapshot" info for the logical storage entity defined on the array
	.Example
	Get-XIOSnapshot -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOSnapshot {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Snapshot])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "snapshot"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO SSD info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOSsd
	Request info from current XMS connection and return an object with the "SSD" info for the logical storage entity defined on the array
	.Example
	Get-XIOSsd wwn-0x500000000abcdef0
	Get the "SSD" named wwn-0x500000000abcdef0
	.Example
	Get-XIOSsd -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOSsd {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Ssd])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "ssd"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO storage controller info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOStorageController
	Request info from current XMS connection and return an object with the "storage controller" info for the logical storage entity defined on the array
	.Example
	Get-XIOStorageController X3-SC1
	Get the "storage controller" named X3-SC1
	.Example
	Get-XIOStorageController -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOStorageController {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "storage-controller"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO target info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOTarget
	Request info from current XMS connection and return an object with the "target" info for the logical storage entity defined on the array
	.Example
	Get-XIOTarget *fc[12]
	Get the "target" objects with names ending in "fc1" or "fc2"
	.Example
	Get-XIOTarget -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOTarget {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Target])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "target"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO target group info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOTargetGroup
	Request info from current XMS connection and return an object with the "target group" info for the logical storage entity defined on the array
	.Example
	Get-XIOTargetGroup Default
	Get the "target group" named Default
	.Example
	Get-XIOTargetGroup -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOTargetGroup {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "target-group"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO volume info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOVolume
	Request info from current XMS connection and return an object with the "volume" info for the logical storage entity defined on the array
	.Example
	Get-XIOVolume someTest02
	Get the "volume" named someTest02
	.Example
	Get-XIOVolume -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOVolume {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Volume])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "volume"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO volume folder info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOVolumeFolder
	Request info from current XMS connection and return an object with the "volume folder" info for the logical storage entity defined on the array
	.Example
	Get-XIOVolumeFolder /myBigVols
	Get the "volume folder" named /myBigVols
	.Example
	Get-XIOVolumeFolder -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOVolumeFolder {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "volume-folder"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO XEnv info using REST API from XtremIO XMS appliance
	.Example
	Get-XIOXenv
	Request info from current XMS connection and return an object with the "XEnv" info for the logical storage entity defined on the array
	.Example
	Get-XIOXenv X3-SC1-E1,X3-SC1-E2
	Get the "XEnv" items namedX3-SC1-E1 and X3-SC1-E2
	.Example
	Get-XIOXenv -ComputerName somexmsappl01.dom.com -ReturnFullResponse
	Return PSCustomObjects that contain the full data from the REST API response (helpful for looking at what all properties are returned/available)
	.Outputs
	PSCustomObject
#>
function Get-XIOXenv {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.XEnv])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri")]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][string]$URI_str
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "xenv"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOItemInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get XtremIO event info using REST API from XtremIO XMS appliance.
	Note about -Start and -End parameters:  via the XIO API, the search is performed starting with the most recent event ang working back through time.  So, to get events from a month ago, one may need to specify and -End value that is (a month ago plus a few days), depending on how many events have occurred. For instance, if -Start is a date of one month ago, and -Limit is 10, this will return the 10 most recent events from _now_ (starting from now, working backwards), not the first 10 events that happened _after_ the -Start value of one month ago.  This is a bit quirky, but one can adjust -Start, -End, -Limit, etc. params to eventually get the events for the desired range.
	.Example
	Get-XIOEvent
	Request info from current XMS connection and return event info
	.Example
	Get-XIOEvent -ComputerName somexmsappl01.dom.com -Limit ([System.Int32]::MaxValue)
	Request info from XMS connection "somexmsappl01" only and return objects with the event info, up to the given number specified by -Limit
	.Example
	Get-XIOEvent -Start (Get-Date).AddMonths(-1) -End (Get-Date).AddMonths(-1).AddDays(1)
	Request info from current XMS connection and return event info from one month ago for one day's amount of time (up to the default limit returned)
	.Example
	Get-XIOEvent -Severity major
	Request info from current XMS connection and return event info for all events of severity "major"
	.Example
	Get-XIOEvent -EntityType StorageController
	Request info from current XMS connection and return event info for all events involving entity of type StorageController
	.Example
	Get-XIOEvent -EntityType StorageController -SearchText level_3_warning
	Request info from current XMS connection and return event info for all events involving entity of type StorageController with string "level_3_warning" in the event
	.Outputs
	PSCustomObject
#>
function Get-XIOEvent {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.Event])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Maximum number of events to retrieve per XMS connection. Default is 50
		[int]$Limit = 50,
		## Datetime of earliest event to return. Can be an actual System.DateTime object, or a string that can be cast to a DateTime, like "27 Dec 1943 11am"
		[System.DateTime]$Start,
		## Datetime of most recent event to return. Can be an actual System.DateTime object, or a string that can be cast to a DateTime, like "Jun 02 1992, 5:30:00"
		[System.DateTime]$End,
		## Severity of event to retrieve; one of 'information', 'major', 'critical', 'minor'
		[ValidateSet('information', 'major', 'critical', 'minor')]
		[ValidateScript({'information', 'major', 'critical', 'minor' -ccontains $_})][string]$Severity,
		## Category of event to retrieve; one of 'audit', 'state_change', 'hardware', 'activity', 'security', 'lifecycle', 'software'
		[ValidateSet('audit', 'state_change', 'hardware', 'activity', 'security', 'lifecycle', 'software')]
		[ValidateScript({'audit', 'state_change', 'hardware', 'activity', 'security', 'lifecycle', 'software' -ccontains $_})][string]$Category,
		## Text for which to search in events. Short little string
		[ValidateLength(0,32)][string]$SearchText,
		## Entity type for which to get events; one of 'BatteryBackupUnit', 'Cluster', 'DAE', 'DAEController', 'DAEPSU', 'IGFolder', 'InfinibandSwitch', 'InfinibandSwitchPSU', 'Initiator', 'InitiatorGroup', 'LocalDisk', 'SSD', 'StorageController', 'StorageControllerPSU', 'Target', 'Volume', 'VolumeFolder', 'X-Brick'
		[ValidateScript({'BatteryBackupUnit','Cluster','DAE','DAEController','DAEPSU','IGFolder','InfinibandSwitch','InfinibandSwitchPSU','Initiator','InitiatorGroup','LocalDisk','SSD','StorageController','StorageControllerPSU','Target','Volume','VolumeFolder','X-Brick' -ccontains $_})]
		[ValidateSet('BatteryBackupUnit','Cluster','DAE','DAEController','DAEPSU','IGFolder','InfinibandSwitch','InfinibandSwitchPSU','Initiator','InitiatorGroup','LocalDisk','SSD','StorageController','StorageControllerPSU','Target','Volume','VolumeFolder','X-Brick')]
		[string]$EntityType,
		## switch:  Return full response object from API call?  (instead of PSCustomObject with choice properties)
		[switch]$ReturnFullResponse_sw
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOItemInfo
		$ItemType_str = "event"
		## params for URI filtering:  entity, limit, severity, from-date-time, to-date-time, category, free-text
		## hashtable to "translate" between PowerShell cmdlet parameter name and the API filter parameter name
		$hshCmdletParamNameToXIOAPIParamNameMapping = @{EntityType = "entity"; Limit = "limit"; Severity = "severity"; Start = "from-date-time"; End = "to-date-time"; Category = "category"; SearchText = "free-text"}
		## array of Parameter names for this cmdlet that can be added to a URI param string as name=value pairs (don't need special formatting like dates or something)
		$arrCmdletParamNamesForNameValuePairs = "Category","EntityType","SearchText","Severity"
		## array of URI parameter "pieces" (like 'name=value') to use for filtering
		$arrUriParamPiecesToAdd = @("limit=$Limit")
		$PSBoundParameters.GetEnumerator() | Where-Object {$arrCmdletParamNamesForNameValuePairs -contains $_.Key} | Foreach-Object {
			$arrUriParamPiecesToAdd += ("{0}={1}" -f $hshCmdletParamNameToXIOAPIParamNameMapping[$_.Key], (Convert-UrlEncoding $_.Value).ConvertedString)
		} ## end foreach-object
		## add start/end date filters, if any
		"Start", "End" | Foreach-Object {
			$strThisCmdletParamName = $_
			if ($PSBoundParameters.ContainsKey($strThisCmdletParamName)) {
				$arrUriParamPiecesToAdd += "{0}={1}" -f $hshCmdletParamNameToXIOAPIParamNameMapping[$strThisCmdletParamName], (Convert-UrlEncoding $PSBoundParameters.Item($strThisCmdletParamName).ToString($hshCfg["GetEventDatetimeFormat"])).ConvertedString
			} ## end if
		} ## end foreach-object
		## URI filter portion (may end up $null if no add'l params passed to this function)
		$strURIFilter = $arrUriParamPiecesToAdd -join "&"
	} ## end begin

	Process {
		## start of params for Get-XIOItemInfo call
		$hshParamsForGetXioItemInfo = @{ItemType_str = $ItemType_str} ## end hash
		## if any of these params were passed, add them to the hashtable of params to pass along
		"ComputerName","ReturnFullResponse_sw" | Foreach-Object {if ($PSBoundParameters.ContainsKey($_)) {$hshParamsForGetXIOItemInfo[$_] = $PSBoundParameters[$_]}}
		## if any of the filtering params were passed (and, so, $strURIFilter is non-null), add param to hashtable
		if (-not [System.String]::IsNullOrEmpty($strURIFilter)) {$hshParamsForGetXioItemInfo["AdditionalURIParam"] = "/?${strURIFilter}"}
		#Write-Debug ("${strLogEntry_ToAdd}: string for URI filter: '$strURIFilter'")
		## call the base function to get the given events
		Get-XIOItemInfo @hshParamsForGetXioItemInfo
	} ## end process
} ## end function


#region  performance section #####################################################################################
<#	.Description
	Function to get XIO item performance information
	.Example
	Get-XIOPerformanceInfo -ItemType cluster
	Request info from all current XMS connections and return an object with the cluster performance info
	.Example
	Get-XIOPerformanceInfo -ComputerName somexmsappl01.dom.com  -ItemType cluster
	Request info from specified XMS connection and return an object with the cluster peformance info
	.Example
	Get-XIOCluster somecluster | Get-XIOPerformanceInfo -FrequencySeconds 5 -DurationSeconds 30
	Get info for specified item and return cluster peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOPerformanceInfo {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to which to connect
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName_arr,
		## Item type for which to get info; currently supported types:
		##   for all API versions:                "cluster", "initiator-group", "initiator", "target", "volume"
		##   and, for API versions 2.2.3 and up:  "ssd"
		##   and, for API versions 2.4 and up:    "ig-folder", "volume-folder"
		## "target-group" performance not available via API, yet
		[parameter(Mandatory=$true,ParameterSetName="ByComputerName")]
		[ValidateSet("cluster","data-protection-group","ig-folder","initiator","initiator-group","ssd","target","volume-folder","volume")][string]$ItemType_str,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds = 15,
		## Frequency, in seconds, to refresh performance info
		[int]$FrequencySeconds = 5,
		## Full URI to use for the REST call, instead of specifying components from which to construct the URI
		[parameter(Position=0,ParameterSetName="SpecifyFullUri",ValueFromPipelineByPropertyName)]
		[ValidateScript({[System.Uri]::IsWellFormedUriString($_, "Absolute")})][Alias("Uri")][string]$URI_str
	) ## end param

	begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
	} ## end begin
	process {
		## params to pass to Get-XIOItemInfo (since there are potentially some PSBoundParameters params specific to only this function)
		$hshParamsForGetXIOItemInfo = @{}
		Switch ($PSCmdlet.ParameterSetName) {
			"ByComputerName" {
				"ComputerName_arr","ItemType_str","Name_arr" | Foreach-Object {if ($PSBoundParameters.ContainsKey($_)) {$hshParamsForGetXIOItemInfo[$_] = $PSBoundParameters[$_]}}
				## type to return; something like "TargetPerformance"
				$strItemTypeToReturn = "$((Get-Culture).TextInfo.ToTitleCase($ItemType_str.ToLower()))Performance"
				break} ## end case
			"SpecifyFullUri" {
				$hshParamsForGetXIOItemInfo["URI_str"] = $URI_str
				## the type being retrieved, for use in making the typename for the return
				$strItemType_plural = Get-ItemTypeFromURI -URI $URI_str
				## type to return; something like "TargetPerformance", grabbed from URL
				$strItemTypeToReturn = "$((Get-Culture).TextInfo.ToTitleCase($strItemType_plural.TrimEnd('s').ToLower()))Performance"
				break} ## end case
		} ## end switch
		## scriptblock to execute to get performance info
		$sbGetPerformanceInfo = {
			$arrXioItemInfo = Get-XIOItemInfo @hshParamsForGetXIOItemInfo
			$arrXioItemInfo | Foreach-Object {
				$oThisXioItemInfo = $_
				## make a new object with some juicy info (and a new property for the XMS "computer" name used here)
				$oObjToReturn = _New-Object_fromItemTypeAndContent -argItemType $strItemTypeToReturn -oContent $oThisXioItemInfo | Add-Member -Name "ComputerName" -MemberType NoteProperty -Value $oThisXioItemInfo.ComputerName -PassThru
				## add a TypeName to the TypeNames collection; this is for use by PS custom formatting; ref: http://msdn.microsoft.com/en-us/library/system.management.automation.psobject.typenames%28v=vs.85%29.aspx
				$oObjToReturn.PSObject.TypeNames.Insert(0, "XioItemInfo.$strItemTypeToReturn")
				## return the object
				return $oObjToReturn
			} ## end foreach-object
		} ## end scriptblock
		if ($PSBoundParameters.ContainsKey("DurationSeconds") -or $PSBoundParameters.ContainsKey("FrequencySeconds")) {
			## datetime of the start and end of this monitoring session
			$dteStartOfGet = Get-Date; $dteEndOfGet = $dteStartOfGet.AddSeconds($DurationSeconds); $strEndDate = $dteEndOfGet.ToString($hshCfg.VerboseDatetimeFormat)
			while ((Get-Date) -lt $dteEndOfGet) {& $sbGetPerformanceInfo; if ((Get-Date).AddSeconds($FrequencySeconds) -lt $dteEndOfGet) {Write-Verbose -Verbose "$(Get-Date -Format $hshCfg['VerboseDatetimeFormat']); '$FrequencySeconds' sec sleep; ending run at/about $strEndDate ('$DurationSeconds' sec duration)"; Start-Sleep -Seconds $FrequencySeconds} else {break}}
		} ## end if
		else {& $sbGetPerformanceInfo}
	} ## end process
} ## end function


<#	.Description
	Function to get Cluster performance information
	.Example
	Get-XIOClusterPerformance
	Request info from all current XMS connections and return objects with the cluster performance info
	.Example
	Get-XIOClusterPerformance -ComputerName somexmsappl01.dom.com
	Request info from specified XMS connection and return object with peformance info
	.Example
	Get-XIOClusterPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOClusterPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.ClusterPerformance])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "cluster"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get data-protection-group performance information
	.Example
	Get-XIODataProtectionGroupPerformance
	Request info from all current XMS connections and return objects with the data-protection-group performance info
	.Example
	Get-XIODataProtectionGroupPerformance -ComputerName somexmsappl01.dom.com
	Request info from specified XMS connection and return object with the data-protection-group peformance info
	.Example
	Get-XIODataProtectionGroupPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get data-protection-group peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIODataProtectionGroupPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "data-protection-group"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get initiator-group-folder performance information
	.Example
	Get-XIOInitiatorGroupFolderPerformance
	Request info from all current XMS connections and return objects with the ig-folder performance info
	.Example
	Get-XIOInitiatorGroupFolderPerformance -ComputerName somexmsappl01.dom.com
	Request info from specified XMS connection and return objects with the ig-folder peformance info
	.Example
	Get-XIOInitiatorGroupFolderPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get ig-folder peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiatorGroupFolderPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "ig-folder"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get initiator-group performance information
	.Example
	Get-XIOInitiatorGroupPerformance
	Request info from all current XMS connections and return objects with the initiator-group performance info
	.Example
	Get-XIOInitiatorGroupPerformance -ComputerName somexmsappl01.dom.com -Name someig*,otherig*
	Request info from specified XMS connection and return objects with the initiator-group peformance info for initiator groups with names like someig* and otherig*
	.Example
	Get-XIOInitiatorGroupPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get initiator-group peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiatorGroupPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "initiator-group"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get initiator performance information
	.Example
	Get-XIOInitiatorPerformance
	Request info from all current XMS connections and return objects with the initiator performance info
	.Example
	Get-XIOInitiatorPerformance -ComputerName somexmsappl01.dom.com
	Request info from specified XMS connection and return an object with the initiator peformance info
	.Example
	Get-XIOInitiatorPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get initiator peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOInitiatorPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.InitiatorPerformance])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "initiator"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get SSD performance information
	.Example
	Get-XIOSsdPerformance
	Request info from all current XMS connections and return objects with the SSD performance info
	.Example
	Get-XIOSsdPerformance -ComputerName somexmsappl01.dom.com
	Request info from specified XMS connection and return objects with the SSD peformance info
	.Example
	Get-XIOSsdPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get SSD peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOSsdPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.SsdPerformance])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "ssd"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get target performance information
	.Example
	Get-XIOTargetPerformance
	Request info from all current XMS connections and return objects with the target performance info
	.Example
	Get-XIOTargetPerformance X1-SC2-fc1,X1-SC2-fc2
	Get the target peformance info for targets X1-SC2-fc1 and X1-SC2-fc2
	.Example
	Get-XIOTargetPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get target peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOTargetPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.TargetPerformance])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "target"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get volume-folder performance information
	.Example
	Get-XIOVolumeFolderPerformance
	Request info from all current XMS connections and return objects with the volume-folder performance info
	.Example
	Get-XIOVolumeFolderPerformance /someVolFolder/someDeeperFolder
	Get the volume-folder peformance info for the given volume folder
	.Example
	Get-XIOVolumeFolderPerformance -FrequencySeconds 5 -DurationSeconds 30
	Get volume-folder peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOVolumeFolderPerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "volume-folder"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function


<#	.Description
	Function to get volume performance information
	.Example
	Get-XIOVolumePerformance
	Request info from all current XMS connections and return objects with the volume performance info
	.Example
	Get-XIOVolumePerformance *somevols*.02[5-8]
	Get the volume peformance info for volumes with names like *somevols*.025, *somevols*.026, *somevols*.027, *somevols*.028
	.Example
	Get-XIOVolumePerformance -FrequencySeconds 5 -DurationSeconds 30
	Get volume peformance info every 5 seconds for 30 seconds
	.Outputs
	PSCustomObject
#>
function Get-XIOVolumePerformance {
	[CmdletBinding(DefaultParameterSetName="ByComputerName")]
	[OutputType([XioItemInfo.VolumePerformance])]
	param(
		## XMS appliance address to use; if none, use default connections
		[parameter(ParameterSetName="ByComputerName")][string[]]$ComputerName,
		## Item name(s) for which to get info (or, all items of given type if no name specified here)
		[parameter(Position=0,ParameterSetName="ByComputerName")][Alias("Name")][string[]]$Name_arr,
		## Duration for which to refresh performance info, in seconds
		[int]$DurationSeconds,
		## Frequency, in seconds, with which to refresh performance info
		[int]$FrequencySeconds
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
		## the itemtype to get via Get-XIOPerformanceInfo
		$ItemType_str = "volume"
	} ## end begin

	Process {
		## call the base function to get the given item
		Get-XIOPerformanceInfo @PSBoundParameters -ItemType $ItemType_str
	} ## end process
} ## end function
#endregion  performance section #####################################################################################
