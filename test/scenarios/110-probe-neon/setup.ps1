# THROWAWAY PROBE, never merged: finds Opera Neon's Windows download and prints its pages.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')
$out = Join-Path $env:RUNNER_TEMP 'probe.out'
& {
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'
  foreach ($page in 'https://www.operaneon.com/', 'https://www.operaneon.com/download', 'https://www.opera.com/download') {
    $f = Join-Path $env:RUNNER_TEMP 'page.html'
    & curl.exe -sSL -A $ua -m 30 -o $f -w "$page HTTP %{http_code} -> %{url_effective}`n" $page
    if (Test-Path $f) { Select-String -Path $f -Pattern 'https?://[^"''<> ]*(neon|\.exe)[^"''<> ]*' -AllMatches | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique | Select-Object -First 40 }
  }
  foreach ($u in 'https://net.geo.opera.com/opera_neon/stable/windows', 'https://download.opera.com/download/get/?partner=www&opsys=Windows&product=Opera%20Neon') {
    & curl.exe -sS -A $ua -m 30 -o NUL -L -r 0-0 -w "$u HTTP %{http_code} -> %{url_effective} type %{content_type}`n" $u
  }
} *>&1 | Tee-Object -FilePath $out
& python (Join-Path $PSScriptRoot 'emit.py') $out
exit 0
