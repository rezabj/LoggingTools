function Set-LTLogDefaultLevel {
  <#
    .SYNOPSIS
      Sets a global logging severity level
    .DESCRIPTION
      This function sets a global logging severity level.
      This level is used by all logging functions that do not have a -Level parameter.
    .PARAMETER Level
      The severity level to set. Valid values are: DEBUG, INFO, WARNING, ERROR, CRITICAL
    .EXAMPLE
      PS C:\> Set-LTLogDefaultLevel -Level INFO
      PS C:\> Write-LTLog -Message "This is an INFO message"
    .LINK
      https://rezabj.github.io/LoggingTools/Functions/Set-LTLogDefaultLevel/
    .LINK
      https://github.com/rezabj/LoggingTools/blob/Dev/docs/Functions/Set-LTLogDefaultLevel.md
  #>

  [CmdletBinding(HelpUri='https://github.com/rezabj/LoggingTools/blob/Dev/docs/Functions/Set-LTLogDefaultLevel.md')]
  param (
    [Parameter(Mandatory=$true)]
    [ValidateSet('DEBUG','INFO','WARNING','ERROR','CRITICAL')]
    [string]$Level
  )

  $Script:LoggingTools.Level = $Level
}