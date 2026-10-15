<#
  StreamingApp environment: pause / resume / status
  Run from the laptop (Windows PowerShell) with the admin CLI profile "streamingapp".

    powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action status
    powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action pause
    powershell -ExecutionPolicy Bypass -File .\infra\streamingapp-env.ps1 -Action resume

  pause  : disable alarm notifications, scale EKS nodes 2 -> 0, stop the Jenkins EC2
  resume : start Jenkins, scale EKS nodes 0 -> 2, wait for the live site, re-enable alarm notifications
  status : show node count, Jenkins state, live site HTTP codes and alarm notification state
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('pause', 'resume', 'status')]
  [string]$Action
)

$ErrorActionPreference = 'Stop'
$AwsProfile = 'streamingapp'
$Region   = 'ap-southeast-2'
$Cluster  = 'streamingapp-eks'
$NodeGrp  = 'ng-default'
$Jenkins  = 'i-0135ea3b291a431f1'
$AppUrl   = 'https://streamapp.kamalvasvani.com'

function Invoke-Aws {
  $out = & aws @args --profile $AwsProfile --region $Region
  if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed" }
  return $out
}

function Get-AlarmNames {
  $txt = Invoke-Aws cloudwatch describe-alarms --alarm-name-prefix streamingapp- --query 'MetricAlarms[].AlarmName' --output text
  return @(($txt -join ' ') -split '\s+' | Where-Object { $_ })
}

function Get-HttpCode([string]$Path) {
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 15 "$AppUrl$Path"
  return "$code"
}

function Show-Status {
  $ng = Invoke-Aws eks describe-nodegroup --cluster-name $Cluster --nodegroup-name $NodeGrp `
        --query 'nodegroup.[status,scalingConfig.desiredSize,scalingConfig.minSize,scalingConfig.maxSize]' --output text
  $js = Invoke-Aws ec2 describe-instances --instance-ids $Jenkins --query 'Reservations[0].Instances[0].State.Name' --output text
  $al = Invoke-Aws cloudwatch describe-alarms --alarm-name-prefix streamingapp- `
        --query 'MetricAlarms[].[AlarmName,StateValue,ActionsEnabled]' --output text
  Write-Host "EKS nodegroup (status desired min max): $ng"
  Write-Host "Jenkins EC2: $js"
  foreach ($p in '/', '/healthz', '/api/streaming/videos') { Write-Host ("Site {0,-24} {1}" -f $p, (Get-HttpCode $p)) }
  Write-Host "Alarms (name state notificationsEnabled):"
  $al | ForEach-Object { Write-Host "  $_" }
}

switch ($Action) {

  'status' { Show-Status }

  'pause' {
    Write-Host '1/3 Disabling alarm notifications (avoids false alerts while nodes are at 0)...'
    $alarms = Get-AlarmNames
    if ($alarms.Count -gt 0) { Invoke-Aws cloudwatch disable-alarm-actions --alarm-names @alarms | Out-Null }

    Write-Host '2/3 Scaling EKS nodegroup to 0...'
    Invoke-Aws eks update-nodegroup-config --cluster-name $Cluster --nodegroup-name $NodeGrp `
      --scaling-config 'minSize=0,maxSize=3,desiredSize=0' | Out-Null

    Write-Host '3/3 Stopping Jenkins EC2...'
    Invoke-Aws ec2 stop-instances --instance-ids $Jenkins | Out-Null
    Invoke-Aws ec2 wait instance-stopped --instance-ids $Jenkins

    Write-Host 'Waiting 3 minutes for the nodes to drain and terminate...'
    Start-Sleep -Seconds 180
    Show-Status
    Write-Host 'PAUSED. The live site will return errors until you run -Action resume.'
  }

  'resume' {
    Write-Host '1/4 Starting Jenkins EC2...'
    Invoke-Aws ec2 start-instances --instance-ids $Jenkins | Out-Null

    Write-Host '2/4 Scaling EKS nodegroup to 2...'
    Invoke-Aws eks update-nodegroup-config --cluster-name $Cluster --nodegroup-name $NodeGrp `
      --scaling-config 'minSize=2,maxSize=3,desiredSize=2' | Out-Null
    Invoke-Aws ec2 wait instance-running --instance-ids $Jenkins

    Write-Host '3/4 Waiting for the app to come back (usually 5-10 minutes)...'
    $ok = $false
    for ($i = 1; $i -le 40; $i++) {
      $h = Get-HttpCode '/healthz'; $v = Get-HttpCode '/api/streaming/videos'
      Write-Host ("  try {0,2}: /healthz={1}  /api/streaming/videos={2}" -f $i, $h, $v)
      if ($h -eq '200' -and $v -eq '200') { $ok = $true; break }
      Start-Sleep -Seconds 30
    }
    if (-not $ok) { throw 'App did not become healthy in 20 minutes. Check: kubectl -n streamingapp get pods' }

    Write-Host '4/4 Re-enabling alarm notifications...'
    $alarms = Get-AlarmNames
    if ($alarms.Count -gt 0) { Invoke-Aws cloudwatch enable-alarm-actions --alarm-names @alarms | Out-Null }

    Show-Status
    Write-Host "RUNNING. App: $AppUrl   Jenkins: http://3.104.137.60:8080"
  }
}
