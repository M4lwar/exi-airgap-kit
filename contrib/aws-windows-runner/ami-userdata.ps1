<#
ami-userdata.ps1 — first-boot provisioner for the gitlab-win64-bake AMI.

Runs once, at first boot of the *builder* instance, via EC2 user-data
(wrapped in <powershell>...</powershell> by build-ami.sh). It turns a stock
Windows_Server-2022-English-Full-Base instance into a Windows bake host:
OpenSSH (keyed for the instance's launch key), the full C/C++ + Java + Python
toolchain under C:\tools, and the site's TLS trust anchor. The instance is
then stopped and imaged (see build-ami.sh) — this script never runs again on
the resulting AMI's descendants.

Idempotency: NOT idempotent by design — it is meant to run exactly once,
at AMI-bake time, on a throwaway builder instance.

Everything below C:\tools is self-contained (no MSI/registry-heavy
installers) except OpenSSH (a Windows capability) and VS Build Tools (which
requires its own installer). All output is transcribed to C:\ami-build.log
for post-mortem via SSH. The sentinel C:\ami-ready.txt is written LAST and
is the sole readiness signal build-ami.sh polls for.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much faster without a progress bar

Start-Transcript -Path 'C:\ami-build.log' -Append -Force | Out-Null

function Write-Step {
    param([string]$Message)
    Write-Output "`n=== [$(Get-Date -Format 'u')] $Message ==="
}

try {
    # ------------------------------------------------------------------
    # 1. OpenSSH Server
    # ------------------------------------------------------------------
    Write-Step 'Installing OpenSSH Server'
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null

    Set-Service -Name sshd -StartupType Automatic
    Set-Service -Name ssh-agent -StartupType Automatic

    # ------------------------------------------------------------------
    # 2. Authorize the launch key from instance metadata (IMDSv2)
    # ------------------------------------------------------------------
    Write-Step 'Fetching launch key from instance metadata (IMDSv2)'
    $tokenHeaders = @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
    $imdsToken = Invoke-RestMethod -Method PUT -Uri 'http://169.254.169.254/latest/api/token' -Headers $tokenHeaders
    $authHeaders = @{ 'X-aws-ec2-metadata-token' = $imdsToken }
    $publicKey = Invoke-RestMethod -Method GET -Uri 'http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key' -Headers $authHeaders

    $sshDir = 'C:\ProgramData\ssh'
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $authorizedKeysPath = Join-Path $sshDir 'administrators_authorized_keys'
    Set-Content -Path $authorizedKeysPath -Value $publicKey -Encoding ASCII -Force

    # administrators_authorized_keys must be readable ONLY by Administrators + SYSTEM
    # or sshd will refuse to use it.
    icacls $authorizedKeysPath /inheritance:r | Out-Null
    icacls $authorizedKeysPath /grant 'Administrators:F' | Out-Null
    icacls $authorizedKeysPath /grant 'SYSTEM:F' | Out-Null

    # ------------------------------------------------------------------
    # 3. PowerShell as the default ssh shell
    # ------------------------------------------------------------------
    Write-Step 'Setting PowerShell as the default SSH shell'
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -PropertyType String -Force | Out-Null

    # sshd is started deliberately LATE (after step 9 sets machine PATH /
    # JAVA_HOME below), not here. Windows services snapshot their process
    # environment block at start and do not pick up later machine-env
    # changes without a restart — every SSH session spawned by sshd
    # inherits sshd's own (possibly stale) environment. Starting it only
    # after PATH/JAVA_HOME are final means every SSH session on the baked
    # AMI sees the right values from the very first connection, with no
    # manual `Restart-Service sshd` required downstream.

    # ------------------------------------------------------------------
    # Helpers: download + extract zips into C:\tools
    # ------------------------------------------------------------------
    New-Item -ItemType Directory -Path 'C:\tools' -Force | Out-Null
    $workDir = 'C:\tools\_downloads'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    function Get-File {
        param([string]$Url, [string]$OutFile)
        Write-Output "  downloading $Url"
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
                return
            } catch {
                if ($attempt -ge 5) { throw }
                Write-Output "    attempt $attempt failed ($($_.Exception.Message)); retrying in 10s"
                Start-Sleep -Seconds 10
            }
        }
    }

    # Expands a zip and moves its contents into $Dest. If the archive has a
    # single top-level directory (the common "versioned folder" zip layout,
    # e.g. apache-maven-3.9.9/...), that directory's *contents* are moved up
    # so $Dest itself becomes the tool root (e.g. C:\tools\maven\bin\...).
    # If the archive is already flat (e.g. MinGit), its contents are moved
    # as-is.
    function Expand-ToolZip {
        param([string]$ZipPath, [string]$Dest)
        $extractDir = Join-Path $workDir ([System.IO.Path]::GetRandomFileName())
        Expand-Archive -Path $ZipPath -DestinationPath $extractDir -Force

        $children = Get-ChildItem -Path $extractDir
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            Get-ChildItem -Path $children[0].FullName | Move-Item -Destination $Dest -Force
        } else {
            $children | Move-Item -Destination $Dest -Force
        }
        Remove-Item -Path $extractDir -Recurse -Force
    }

    # ------------------------------------------------------------------
    # 4. git (MinGit)
    # ------------------------------------------------------------------
    Write-Step 'Installing MinGit'
    $minGitVersion = '2.47.1'
    $minGitZip = Join-Path $workDir 'mingit.zip'
    Get-File -Url "https://github.com/git-for-windows/git/releases/download/v$minGitVersion.windows.1/MinGit-$minGitVersion-64-bit.zip" -OutFile $minGitZip
    Expand-ToolZip -ZipPath $minGitZip -Dest 'C:\tools\git'

    # ------------------------------------------------------------------
    # 5. GraalVM Community JDK (pinned to match Dockerfile.builder's
    #    GRAALVM_VERSION ARG, so native-image builds behave identically
    #    on Windows and Linux).
    # ------------------------------------------------------------------
    Write-Step 'Installing GraalVM Community JDK'
    $graalVersion = '21.0.2'
    $graalZip = Join-Path $workDir 'graalvm.zip'
    Get-File -Url "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-$graalVersion/graalvm-community-jdk-${graalVersion}_windows-x64_bin.zip" -OutFile $graalZip
    Expand-ToolZip -ZipPath $graalZip -Dest 'C:\tools\graalvm'

    # ------------------------------------------------------------------
    # 6. Apache Maven
    # ------------------------------------------------------------------
    Write-Step 'Installing Apache Maven'
    $mavenVersion = '3.9.9'
    $mavenZip = Join-Path $workDir 'maven.zip'
    Get-File -Url "https://archive.apache.org/dist/maven/maven-3/$mavenVersion/binaries/apache-maven-$mavenVersion-bin.zip" -OutFile $mavenZip
    Expand-ToolZip -ZipPath $mavenZip -Dest 'C:\tools\maven'

    # ------------------------------------------------------------------
    # 7. Python (full installer — pip needs it; embeddable does not ship pip)
    #    + Conan 2.x
    # ------------------------------------------------------------------
    Write-Step 'Installing Python (full installer) and Conan'
    $pythonVersion = '3.12.7'
    $pythonExe = Join-Path $workDir 'python-installer.exe'
    Get-File -Url "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-amd64.exe" -OutFile $pythonExe
    $pythonHome = 'C:\tools\python'
    $pythonProc = Start-Process -FilePath $pythonExe -ArgumentList @(
        '/quiet', 'InstallAllUsers=1', 'PrependPath=1', "TargetDir=$pythonHome"
    ) -Wait -PassThru
    if ($pythonProc.ExitCode -ne 0) {
        throw "Python installer exited with code $($pythonProc.ExitCode)"
    }

    # PrependPath=1 edits the machine PATH, but this process does not see it
    # until a new shell picks up the environment — call the installed
    # interpreter directly by full path instead of relying on refreshed PATH.
    & "$pythonHome\python.exe" -m pip install --upgrade pip
    & "$pythonHome\python.exe" -m pip install 'conan>=2'

    # ------------------------------------------------------------------
    # 8. VS Build Tools (VCTools workload) — the slow step (15-30 min)
    # ------------------------------------------------------------------
    Write-Step 'Installing VS Build Tools (Microsoft.VisualStudio.Workload.VCTools) - this takes 15-30 minutes'
    $vsBuildToolsExe = Join-Path $workDir 'vs_buildtools.exe'
    Get-File -Url 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $vsBuildToolsExe
    $vsProc = Start-Process -FilePath $vsBuildToolsExe -ArgumentList @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--includeRecommended'
    ) -Wait -PassThru
    # 0 = success. 3010 = success, reboot required. Anything else is a real
    # failure; diagnose via the VS Build Tools bootstrapper logs plus this
    # transcript (C:\ami-build.log).
    if ($vsProc.ExitCode -eq 3010) {
        Write-Output '  VS Build Tools requested a reboot (exit 3010) - continuing without rebooting; a pending reboot flag is harmless in the baked AMI.'
    } elseif ($vsProc.ExitCode -ne 0) {
        throw "vs_buildtools.exe exited with code $($vsProc.ExitCode)"
    }

    # ------------------------------------------------------------------
    # 9. Machine-scope environment (JAVA_HOME + PATH)
    # ------------------------------------------------------------------
    Write-Step 'Setting machine-scope environment variables'
    [Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\tools\graalvm', 'Machine')

    $existingPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $additions = @(
        'C:\tools\graalvm\bin',
        'C:\tools\maven\bin',
        'C:\tools\git\cmd',
        'C:\tools\python',
        'C:\tools\python\Scripts'
    )
    $pathParts = $existingPath -split ';' | Where-Object { $_ -ne '' }
    foreach ($addition in $additions) {
        if ($pathParts -notcontains $addition) { $pathParts += $addition }
    }
    [Environment]::SetEnvironmentVariable('PATH', ($pathParts -join ';'), 'Machine')

    # Start sshd now, for the first time, so its process environment block
    # is snapshotted AFTER JAVA_HOME/PATH are final (see the note at step 3
    # above) — every SSH session from here on sees the right values.
    Start-Service sshd

    # ------------------------------------------------------------------
    # 10. Site TLS trust anchor (Cloudflare origin root)
    # ------------------------------------------------------------------
    Write-Step 'Importing site TLS trust anchor into LocalMachine\Root'
    $certPem = @'
__CF_ORIGIN_PEM__
'@
    $certPath = 'C:\tools\site-origin-root.pem'
    Set-Content -Path $certPath -Value $certPem -Encoding ASCII -Force
    Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

    # ------------------------------------------------------------------
    # 11. Sentinel — written LAST. build-ami.sh polls for this file over SSH.
    # ------------------------------------------------------------------
    Write-Step 'Provisioning complete'
    Set-Content -Path 'C:\ami-ready.txt' -Value (Get-Date -Format 'u') -Encoding ASCII -Force

    Stop-Transcript | Out-Null
} catch {
    Write-Output "PROVISIONING FAILED: $($_.Exception.Message)"
    Write-Output ($_ | Format-List * -Force | Out-String)
    try { Stop-Transcript | Out-Null } catch {}
    throw
}
