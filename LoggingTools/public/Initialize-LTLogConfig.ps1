function Initialize-LTLogConfig {
  [CmdletBinding()]
  Param()

  Write-Verbose -Message 'Initializing LTConfig'
  New-Variable -Name 'LTConfig' -Value ([hashtable]@{ "DefaultLevel" = "INFO"})
  
  $Levels = ([ordered]@{
    'INFO' = 'INFO'
    'DEBUG' = 'DEBUG'
  }).AsReadOnly()

  $LTConfig.Add('Levels', $Levels)
  
  New-Variable -Name 'LTScriptRoot' -Value ([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Module.Path)) -Option ReadOnly -Scope 1 -Visibility Public

  $LTConfig.Add('ScriptRoot', $LTScriptRoot)

  return $LTConfig
  
}