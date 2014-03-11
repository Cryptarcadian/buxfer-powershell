# Windows PowerShell interface for Buxfer API
# Contributors: Stephen Mok <me@stephen.is>
#
# This tool is not affiliated with or endorsed by Buxfer Inc.
# Buxfer is an "easy online money manager": https://www.buxfer.com/

function Set-BuxferToken {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)] [String] $Token)
	$PSDefaultParameterValues["*-Buxfer*:Token"] = $Token
}

function New-BuxferToken {
	param([String]$Username, [Switch]$Save)
	# GUI or command-line prompt depends on registry setting
	$Credential = $Host.UI.PromptForCredential("New-BuxferToken", "Log in to Buxfer for API access", $Username, $null)
	if (!$Credential.UserName -or !$Credential.Password.Length) {
		Write-Error "Username and password required."
		return
	}
	$Credential = $Credential.GetNetworkCredential()
	$Request = @{
		userid = $Credential.UserName;
		password = $Credential.Password;
	}
	$Response = Invoke-RestMethod "https://www.buxfer.com/api/login.json" -Method Post -Body $Request
	if ($Response -and ($Response.response.status -eq "OK")) {
		if ($Save) {
			Set-BuxferToken $Response.response.token
		} else {
			$Response.response.token
		}
	}
}

function Get-BuxferAccounts {
	[CmdletBinding()]
	param([String]$Token)
	if (!$Token) {
		$Token = New-BuxferToken
	}
	$Response = Invoke-RestMethod "https://www.buxfer.com/api/accounts.json" -Method Post -Body @{ token = $Token }
	if ($Response -and ($Response.response.status -eq "OK")) {
		$Response.response.accounts.'key-account'
	}
}

function Get-BuxferTags {
	[CmdletBinding()]
	param([String]$Token)
	if (!$Token) {
		$Token = New-BuxferToken
	}
	$Response = Invoke-RestMethod "https://www.buxfer.com/api/tags.json" -Method Post -Body @{ token = $Token }
	if ($Response -and ($Response.response.status -eq "OK")) {
		$Response.response.tags.'key-tag'
	}
}

function Get-BuxferTransactions {
	[CmdletBinding()]
	param(
		[DateTime] $DateStart,
		[DateTime] $DateEnd,
		[String] $Account,
		[String] $Tag,
		[String] $Contact,
		[String] $Group,
		[String] $Token,
		[Switch] $All,
		# TODO: implement as true [CmdletBinding(SupportsShouldProcess=$true)]
		[Switch] $WhatIf
	)
	if (!$Token) {
		$Token = New-BuxferToken
	}
	$Request = @{ token = $Token }
	if ($DateStart -or $DateEnd) {
		if (!$DateStart) {
			# Defaults to same as DateEnd
			$DateStart = $DateEnd
		}
		if (!$DateEnd) {
			# Defaults to today
			$DateEnd = Get-Date
		}
		$Request["startDate"] = $DateStart.ToString("yyyy-MM-dd")
		$Request["endDate"] = $DateEnd.ToString("yyyy-MM-dd")
	}
	@($Account, "accountName"),
	@($Tag, "tagName"),
	@($Contact, "contactName"),
	@($Group, "groupName") | ForEach-Object {
		if ($_[0]) {
			$Request[$_[1]] = $_[0]
		}
	}
	if ($WhatIf) {
		$Request
		return
	}
	function Get-BuxferTransactionsBatch {
		$Response = Invoke-RestMethod "https://www.buxfer.com/api/transactions.json" -Method Post -Body $Request
		if ($Response -and ($Response.response.status -eq "OK")) {
			$Response.response
		}
	}
	$Results = Get-BuxferTransactionsBatch
	if ($Results.transactions) {
		$Results.transactions."key-transaction"
		$Total = $Results.numTransactions
		$Limit = $Results.transactions.Count
		if ($Total -gt $Limit) {
			if ($All) {
				$Pages = [Math]::Ceiling($Total/$Limit)
				2..$Pages | ForEach-Object {
					$Request["page"] = $_
					(Get-BuxferTransactionsBatch).transactions."key-transaction"
				}
			} else {
				Write-Warning "Partial results, returning $Limit of $Total total (use -All to get full results)"
			}
		}
	}
}

function Add-BuxferTransaction {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true, Position=0)] [Double] $Amount,
		[Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)] [String] $Description,
		[ValidateSet("Expense", "Income", "Shared", "Transfer")] [String] $Type,
		[ValidateSet("Pending", "Cleared")] [String] $Status,
		[ValidateCount(0,2)] [String[]] $Account,
		[String[]] $Tags,
		[DateTime] $Date,
		[String[]] $With,
		[String] $Token,
		# TODO: implement as true [CmdletBinding(SupportsShouldProcess=$true)]
		[Switch] $WhatIf
	)
	$Text = $Description
	# Validate additional parameters required for specific types
	if ($Account.Count -gt 1) {
		if ($Account[0] -eq $Account[1]) {
			Write-Error "You cannot transfer from/to the same account"
			return
		} elseif (!$Type) {
			$Type = "Transfer"
		} elseif ($Type -ne "Transfer") {
			Write-Error "Account parameter only accepts multiple values when transaction is of type 'Transfer'"
			return
		}
	} elseif ($Type -eq "Transfer") {
		Write-Error "You must specify both a from and to account for a transfer"
		return
	}
	if ($With) {
		if (!$Type) {
			$Type = "Shared"
		} elseif ($Type -ne "Shared") {
			Write-Error "With parameter may only be used with transactions of type 'Shared'"
			return
		}
	} elseif ($Type -eq "Shared") {
		Write-Error "You must specify who to share the transction with"
		return
	}
	# Validate amounts, by type where appropriate
	$Format = "{0:f2}"
	if ($Amount -eq 0) {
		Write-Error "Amount must not be zero"
		return
	} elseif ($Type -eq "Shared") {
		if ($Amount -lt 0) {
			$AmountString = $Format -f $Amount
		} else {
			$AmountString = $Format -f (-$Amount)
			Write-Warning "Only expenses can be shared, assuming '$Amount' was intended to be '$AmountString'"
		}
		$Text += " $($AmountString.Substring(1))"
		$Text += " WITH: $($With -join ' ')"
	} elseif ($Type -eq "Transfer") {
		if ($Amount -gt 0) {
			$AmountString = $Format -f $Amount
		} else {
			$AmountString = $Format -f (-$Amount)
			Write-Warning "Negative amounts cannot be transfered, assuming '$Amount' was intended to be '$AmountString'"
		}
		$Text += " $AmountString"
	} elseif ($Type -eq "Expense") {
		if ($Amount -lt 0) {
			$AmountString = $Format -f $Amount
		} else {
			$AmountString = $Format -f (-$Amount)
			Write-Warning "Expense must be a negative amount, assuming '$Amount' was intended to be '$AmountString'"
		}
		$Text += " $($AmountString.Substring(1))"
	} elseif ($Type -eq "Income") {
		if ($Amount -gt 0) {
			$AmountString = $Format -f $Amount
		} else {
			$AmountString = $Format -f (-$Amount)
			Write-Warning "Income must be a positive amount, assuming '$Amount' was intended to be '$AmountString'"
		}
		$Text += " +$AmountString"
	} elseif (!$Type) {
		# Guess at expense or income based on sign
		if ($Amount -gt 0) {
			$Type = "Income"
			$Text += " +" + ($Format -f $Amount)
		} else {
			$Type = "Expense"
			$AmountString = $Format -f $Amount
			$Text += " $($AmountString.Substring(1))"
		}
	}
	if ($Status) {
		$Text += " STATUS:$Status"
	}
	if ($Account) {
		$Text += " ACCT:"
		if ($Type -eq "Transfer") {
			$Text += ($Account -join ",")
		} else {
			$Text += $Account
		}
	}
	if ($Tags) {
		$Text += " TAGS:$($Tags -join ',')"
	}
	if ($Date) {
		$Text += " DATE:$($Date.ToString('yyyy-MM-dd'))"
	}
	if (!$Token) {
		if ($BuxferToken) {
			$Token = $BuxferToken
		} else {
			$Token = New-BuxferToken
		}
	}
	$Request = @{
		token = $Token;
		format = "sms";
		text = $Text
	}
	if ($WhatIf) {
		Write-Host "What if: Adding Buxfer transaction of type $Type with text request '$($Request.text)'"
		return;	
	}
	$Response = Invoke-RestMethod "https://www.buxfer.com/api/add_transaction.json" -Method Post -Body $Request
	if ($Response -and ($Response.response.status -eq "OK")) {
		$Response.response
	}
}
