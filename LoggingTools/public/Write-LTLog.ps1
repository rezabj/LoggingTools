function Write-LTLog {
  <#
    .SYNOPSIS
      Writes a log message to the target
    .DESCRIPTION
      This function writes a log message to the target.
      The target can be a file, the console, or a custom target.
      The default target is the console.
    .PARAMETER Level
      The severity level of the message. Valid values are: DEBUG, INFO, WARNING, ERROR, CRITICAL
    .PARAMETER Message
      The message to write to the target
    .PARAMETER ErrorRecord
      An error record object to write to the target
    .LINK
      https://rezabj.github.io/LoggingTools/Functions/Write-LTLog/
    .LINK
      https://github.com/rezabj/LoggingTools/blob/Dev/docs/Functions/Write-LTLog.md
  #>

  [CmdletBinding(HelpUri='https://github.com/rezabj/LoggingTools/blob/Dev/docs/Functions/Write-LTLog.md')]
  param (
    [Parameter(Mandatory=$false)]
    [ValidateSet('DEBUG','INFO','WARNING','ERROR','CRITICAL')]
    [string]$Level,
    [Parameter(Mandatory=$true)]
    [string]$Message,
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord
  )

  if (($null -eq $Level) -and ($null -ne $Script:LoggingTools.Level)) {
    $Level = $Script:LoggingTools.Level
  } else {
    $Level = 'INFO'
  }

  if (!$Script:LTLogQueue) {
    $Script:LTLogQueue = New-Object System.Collections.Queue
  }

  $Script:LTLogQueue.Enqueue(
    [PSCustomObject]@{
    TimeStamp    = [datetime]::now
    TimeStamputc = [datetime]::UtcNow
    Level = $Level
    Message = $Message
    ErrorRecord = $ErrorRecord
    }
  )
}