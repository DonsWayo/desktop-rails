<#
Fetch RubyInstaller's portable archive and check it relocates.

Windows is fetched rather than built. RubyInstaller already ships a portable
interpreter that resolves relative to itself, so building a second one would be
work for its own sake. Spike 3 established that it relocates, tolerates a path
containing a space, and boots Rails with no compiler present.
#>
param(
  [string]$Version = "3.4.10",
  [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = "Stop"

$url = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$Version-1/rubyinstaller-$Version-1-x64.7z"
Write-Host "Fetching $url"
# Downloaded and unpacked in a scratch directory of its own. `desktop:runtime`
# runs this from the application root, where a ruby.7z left behind would be
# packaged into the app, and a fixed C:\unpacked collides with the previous run.
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("desktop-rails-runtime-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
curl.exe -fsSL -o "$scratch\ruby.7z" $url
if ($LASTEXITCODE -ne 0) { throw "downloading $url failed" }
7z x "$scratch\ruby.7z" "-o$scratch\unpacked" | Out-Null
$src = (Get-ChildItem "$scratch\unpacked" | Select-Object -First 1).FullName

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
Copy-Item -Recurse $src $Out
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue

# The prefix has to be where the interpreter now is — compared as files, since
# either spelling may carry 8.3 short names. This used to check that it
# merely contained "out", which held for CI's out\ruby and failed for every
# other destination — including .desktop-rails\runtime, where desktop:runtime
# puts it.
$env:DESKTOP_RAILS_RUNTIME_OUT = (Resolve-Path $Out).Path
& "$Out\bin\ruby.exe" -e @"
require 'psych'
require 'openssl'
abort 'psych broken' unless Psych.load('- 1') == [1]
abort 'openssl mismatch' unless OpenSSL::OPENSSL_VERSION == OpenSSL::OPENSSL_LIBRARY_VERSION
here = File.join(ENV.fetch('DESKTOP_RAILS_RUNTIME_OUT'), 'bin', 'ruby.exe')
abort 'RbConfig did not follow the binary: ' + RbConfig::CONFIG['prefix'] unless File.identical?(File.join(RbConfig::CONFIG['prefix'], 'bin', 'ruby.exe'), here)
puts "OK  ruby #{RUBY_VERSION} #{RUBY_PLATFORM}, psych #{Psych::VERSION}, #{OpenSSL::OPENSSL_VERSION}"
"@
if ($LASTEXITCODE -ne 0) { throw "the portable interpreter did not check out" }
