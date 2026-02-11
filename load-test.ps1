# PowerShell Load Test Script for Bulkhead Isolation Demo

$API_URL = "http://localhost:8080"

Write-Host "Starting load test against $API_URL`n" -ForegroundColor Green

# Function to run free tier flood
$freeScript = {
    param($url)
    $headers = @{'X-Tenant-Tier' = 'free'}
    $results = @()
    
    1..300 | ForEach-Object {
        try {
            $response = Invoke-WebRequest -Uri "$url/api/data" -Headers $headers -UseBasicParsing -ErrorAction Stop
            $results += "free 200"
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 429) {
                $results += "free 429"
            } elseif ($code -eq 503) {
                $results += "free 503"
            } else {
                $results += "free $code"
            }
        }
    }
    return $results
}

# Function for pro tier steady stream
$proScript = {
    param($url)
    $headers = @{'X-Tenant-Tier' = 'pro'}
    $results = @()
    
    1..40 | ForEach-Object {
        try {
            $response = Invoke-WebRequest -Uri "$url/api/data" -Headers $headers -UseBasicParsing -ErrorAction Stop
            $results += "pro 200"
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            $results += "pro $code"
        }
        Start-Sleep -Milliseconds 500
    }
    return $results
}

# Function for enterprise tier steady stream
$enterpriseScript = {
    param($url)
    $headers = @{'X-Tenant-Tier' = 'enterprise'}
    $results = @()
    
    1..40 | ForEach-Object {
        try {
            $response = Invoke-WebRequest -Uri "$url/api/data" -Headers $headers -UseBasicParsing -ErrorAction Stop
            $results += "enterprise 200"
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            $results += "enterprise $code"
        }
        Start-Sleep -Milliseconds 500
    }
    return $results
}

Write-Host "Launching concurrent load..." -ForegroundColor Yellow

# Start all jobs
$jobs = @()
$jobs += Start-Job -ScriptBlock $freeScript -ArgumentList $API_URL
$jobs += Start-Job -ScriptBlock $proScript -ArgumentList $API_URL
$jobs += Start-Job -ScriptBlock $enterpriseScript -ArgumentList $API_URL

# Wait for all jobs to complete and collect results
Write-Host "Waiting for jobs to complete...`n" -ForegroundColor Yellow
$allResults = @()
foreach ($job in $jobs) {
    $allResults += Receive-Job -Job $job -Wait
    Remove-Job -Job $job
}

# Analyze results
$freeSuccess = ($allResults | Where-Object { $_ -match "^free 200" }).Count
$freeRateLimited = ($allResults | Where-Object { $_ -match "^free 429" }).Count
$freeError = ($allResults | Where-Object { $_ -match "^free 503" }).Count

$proSuccess = ($allResults | Where-Object { $_ -match "^pro 200" }).Count
$proFailed = ($allResults | Where-Object { $_ -match "^pro" -and $_ -notmatch "200" }).Count

$enterpriseSuccess = ($allResults | Where-Object { $_ -match "^enterprise 200" }).Count
$enterpriseFailed = ($allResults | Where-Object { $_ -match "^enterprise" -and $_ -notmatch "200" }).Count

Write-Host "`n=== Load Test Results ===" -ForegroundColor Cyan
Write-Host "`nFree Tier (300 requests):" -ForegroundColor Yellow
Write-Host "  Success (200): $freeSuccess"
Write-Host "  Rate Limited (429): $freeRateLimited"
Write-Host "  Service Unavailable (503): $freeError"

Write-Host "`nPro Tier (40 requests):" -ForegroundColor Green
Write-Host "  Success (200): $proSuccess"
Write-Host "  Failed: $proFailed"

Write-Host "`nEnterprise Tier (40 requests):" -ForegroundColor Green
Write-Host "  Success (200): $enterpriseSuccess"
Write-Host "  Failed: $enterpriseFailed"

Write-Host "`nLoad test complete. Checking /metrics/bulkheads for pool saturation..." -ForegroundColor Cyan

# Fetch final metrics
try {
    $metrics = Invoke-WebRequest -Uri "$API_URL/metrics/bulkheads" -UseBasicParsing | Select-Object -ExpandProperty Content | ConvertFrom-Json
    
    Write-Host "`n=== Bulkhead Metrics ===" -ForegroundColor Cyan
    
    Write-Host "`nFree Tier:" -ForegroundColor Yellow
    Write-Host "  Connection Pool: active=$($metrics.free.connectionPool.active), idle=$($metrics.free.connectionPool.idle), max=$($metrics.free.connectionPool.max)"
    Write-Host "  Thread Pool: active=$($metrics.free.threadPool.active), queued=$($metrics.free.threadPool.queued), poolSize=$($metrics.free.threadPool.poolSize)"
    Write-Host "  Circuit Breaker: state=$($metrics.free.circuitBreaker.state), failures=$($metrics.free.circuitBreaker.failures)"
    
    Write-Host "`nPro Tier:" -ForegroundColor Green
    Write-Host "  Connection Pool: active=$($metrics.pro.connectionPool.active), idle=$($metrics.pro.connectionPool.idle), max=$($metrics.pro.connectionPool.max)"
    Write-Host "  Thread Pool: active=$($metrics.pro.threadPool.active), queued=$($metrics.pro.threadPool.queued), poolSize=$($metrics.pro.threadPool.poolSize)"
    Write-Host "  Circuit Breaker: state=$($metrics.pro.circuitBreaker.state), failures=$($metrics.pro.circuitBreaker.failures)"
    
    Write-Host "`nEnterprise Tier:" -ForegroundColor Green
    Write-Host "  Connection Pool: active=$($metrics.enterprise.connectionPool.active), idle=$($metrics.enterprise.connectionPool.idle), max=$($metrics.enterprise.connectionPool.max)"
    Write-Host "  Thread Pool: active=$($metrics.enterprise.threadPool.active), queued=$($metrics.enterprise.threadPool.queued), poolSize=$($metrics.enterprise.threadPool.poolSize)"
    Write-Host "  Circuit Breaker: state=$($metrics.enterprise.circuitBreaker.state), failures=$($metrics.enterprise.circuitBreaker.failures)"
    
} catch {
    Write-Host "Failed to fetch metrics: $_" -ForegroundColor Red
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($proSuccess -ge 38 -and $enterpriseSuccess -ge 38) {
    Write-Host "✓ Pro and Enterprise tiers remained responsive under free tier load" -ForegroundColor Green
} else {
    Write-Host "✗ Some pro/enterprise requests failed - bulkhead isolation may need tuning" -ForegroundColor Red
}

if ($freeRateLimited -gt 0 -or $freeError -gt 0) {
    Write-Host "✓ Free tier experienced rate limiting/errors as expected" -ForegroundColor Green
} else {
    Write-Host "✗ Free tier did not hit rate limits - may need longer test" -ForegroundColor Yellow
}
