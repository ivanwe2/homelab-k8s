# capacity.ps1: the N-1 check.
# For each node: if it disappeared, would the pods that are able to move
# fit into the free capacity (by memory requests) of the other nodes?
# Read-only: it only runs "kubectl get".

function ConvertTo-Mi([string]$Quantity) {
    # Kubernetes memory quantity ("512Mi", "1Gi", "3920000Ki", "128M", "1048576") -> MiB
    if ([string]::IsNullOrEmpty($Quantity)) { return 0 }
    if ($Quantity -notmatch '^([0-9.]+)([A-Za-z]*)$') { Write-Warning "Unknown quantity '$Quantity'"; return 0 }
    $n = [double]$Matches[1]
    switch -CaseSensitive ($Matches[2]) {
        ''   { return $n / 1MB }
        'Ki' { return $n / 1KB }
        'Mi' { return $n }
        'Gi' { return $n * 1KB }
        'k'  { return $n * 1e3 / 1MB }
        'M'  { return $n * 1e6 / 1MB }
        'G'  { return $n * 1e9 / 1MB }
        default { Write-Warning "Unknown unit in '$Quantity'"; return 0 }
    }
}

function Get-Sum($Items, [string]$Property) {
    $s = ($Items | Measure-Object -Property $Property -Sum).Sum
    if ($null -eq $s) { 0 } else { [int]$s }
}

$nodes = (kubectl get nodes -o json | ConvertFrom-Json).items
$pods  = (kubectl get pods -A -o json | ConvertFrom-Json).items |
    Where-Object { $_.spec.nodeName -and $_.status.phase -notin 'Succeeded', 'Failed' }

# One row per pod: where it runs, what it reserves, and whether it can move.
$rows = foreach ($p in $pods) {
    $request = 0
    foreach ($c in $p.spec.containers) { $request += ConvertTo-Mi $c.resources.requests.memory }
    $owner  = $p.metadata.ownerReferences | Select-Object -First 1
    $hasPvc = [bool]($p.spec.volumes | Where-Object { $_.persistentVolumeClaim })
    $moves  = if ($owner.kind -eq 'DaemonSet') { 'no (one per node)' }
              elseif ($hasPvc) { 'no (pinned by its volume)' }
              elseif ($owner.kind -eq 'StatefulSet') { 'yes (on power loss: only after the out-of-service taint)' }
              else { 'yes' }
    [pscustomobject]@{
        Node      = $p.spec.nodeName
        Namespace = $p.metadata.namespace
        Pod       = $p.metadata.name
        RequestMi = [int][math]::Round($request)
        Moves     = $moves
    }
}

$allocatable = @{}
foreach ($n in $nodes) { $allocatable[$n.metadata.name] = [int][math]::Round((ConvertTo-Mi $n.status.allocatable.memory)) }

Write-Host "`nPer node: allocatable memory vs. what pods have reserved (requests)" -ForegroundColor Cyan
$allocatable.Keys | Sort-Object | ForEach-Object {
    $used = Get-Sum ($rows | Where-Object Node -eq $_) 'RequestMi'
    [pscustomobject]@{
        Node          = $_
        AllocatableMi = $allocatable[$_]
        RequestedMi   = $used
        FreeMi        = $allocatable[$_] - $used
        Requested     = '{0:P0}' -f ($used / $allocatable[$_])
    }
} | Format-Table -AutoSize | Out-Host

Write-Host "If this node died..." -ForegroundColor Cyan
$verdicts = foreach ($dead in ($allocatable.Keys | Sort-Object)) {
    $movers  = @($rows | Where-Object { $_.Node -eq $dead -and $_.Moves -like 'yes*' })
    $mustMove = Get-Sum $movers 'RequestMi'
    $biggest  = if ($movers) { [int]($movers | Measure-Object RequestMi -Maximum).Maximum } else { 0 }
    $free = foreach ($other in ($allocatable.Keys | Where-Object { $_ -ne $dead })) {
        $allocatable[$other] - (Get-Sum ($rows | Where-Object Node -eq $other) 'RequestMi')
    }
    $totalFree = [int]($free | Measure-Object -Sum).Sum
    $maxFree   = [int]($free | Measure-Object -Maximum).Maximum
    [pscustomobject]@{
        DeadNode        = $dead
        MustMoveMi      = $mustMove
        FreeElsewhereMi = $totalFree
        BiggestPodMi    = $biggest
        BestNodeFreeMi  = $maxFree
        Verdict         = if ($mustMove -le $totalFree -and $biggest -le $maxFree) { 'fits' } else { 'DOES NOT FIT' }
    }
}
$verdicts | Format-Table -AutoSize | Out-Host

Write-Host "Pods that cannot move, and go down with their node:" -ForegroundColor Cyan
$rows | Where-Object Moves -eq 'no (pinned by its volume)' |
    Sort-Object Node, Namespace | Format-Table Node, Namespace, Pod, RequestMi -AutoSize | Out-Host

Write-Host "StatefulSet pods: they move on a drain, but on power loss they wait for the node:" -ForegroundColor Cyan
$rows | Where-Object Moves -like 'yes (on power loss*' |
    Sort-Object Node, Namespace | Format-Table Node, Namespace, Pod, RequestMi -AutoSize | Out-Host

Write-Host "Pods without a memory request (invisible to the scheduler's math):" -ForegroundColor Cyan
$rows | Where-Object RequestMi -eq 0 | Sort-Object Namespace | Format-Table Node, Namespace, Pod -AutoSize | Out-Host