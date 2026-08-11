param(
    [string]$PortName = "COM3",
    [string]$OutputPath = "D:\FPGA\reports\dma_batch\board-results.txt",
    [int]$TimeoutSeconds = 300
)

$serial = [System.IO.Ports.SerialPort]::new(
    $PortName,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.ReadTimeout = 250
$serial.DtrEnable = $false
$serial.RtsEnable = $false

$outputDirectory = [System.IO.Path]::GetDirectoryName($OutputPath)
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$writer = [System.IO.StreamWriter]::new(
    $OutputPath,
    $false,
    [System.Text.UTF8Encoding]::new($false)
)
$sawTerminalMarker = $false
$sawFailureMarker = $false

try {
    $serial.Open()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $allText = ""
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $chunk = $serial.ReadExisting()
        if ($chunk.Length -gt 0) {
            $writer.Write($chunk)
            $writer.Flush()
            [Console]::Write($chunk)
            $allText += $chunk
            if ($allText.Contains("ALL DMA BATCH SELF-TESTS PASSED") -or
                $allText.Contains("DMA BATCH SELF-TEST FAILED") -or
                $allText.Contains("ALL COMPREHENSIVE SELF-TESTS PASSED") -or
                $allText.Contains("COMPREHENSIVE SELF-TEST FAILED")) {
                $sawTerminalMarker = $true
                $sawFailureMarker =
                    $allText.Contains("DMA BATCH SELF-TEST FAILED") -or
                    $allText.Contains("COMPREHENSIVE SELF-TEST FAILED")
                Start-Sleep -Milliseconds 500
                $tail = $serial.ReadExisting()
                if ($tail.Length -gt 0) {
                    $writer.Write($tail)
                    $writer.Flush()
                    [Console]::Write($tail)
                }
                break
            }
            if ($allText.Length -gt 16384) {
                $allText = $allText.Substring($allText.Length - 8192)
            }
        }
        Start-Sleep -Milliseconds 20
    }
}
finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
    $writer.Dispose()
}

if (-not $sawTerminalMarker) {
    throw "UART capture timed out without a self-test terminal marker"
}
if ($sawFailureMarker) {
    throw "UART capture detected a self-test failure marker"
}
