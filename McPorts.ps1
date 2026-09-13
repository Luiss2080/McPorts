Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must run before any Forms control is created on this thread - Windows
# Forms locks the exception mode in permanently the moment the first
# Control exists. Without this, any bug in an event handler pops the
# default "Excepcion no controlada" crash dialog instead of a plain
# message box, and the app can die if the user clicks Salir on it.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    [System.Windows.Forms.MessageBox]::Show("McPorts encontro un error y lo ignoro: $($e.Exception.Message)", 'McPorts', 'OK', 'Warning') | Out-Null
})

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$StartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'McPorts.lnk'
$VbsLauncher = Join-Path (Split-Path $ScriptPath -Parent) 'Start-McPorts.vbs'

# --- Data collection -------------------------------------------------------

# Never list or touch OS-critical processes. Several of them (wininit,
# csrss, winlogon...) legitimately outlive the parent that spawned them
# (smss.exe exits right after boot by design) - that looks exactly like
# "orphan" to a dead-parent heuristic, but killing them can crash Windows.
$script:SystemProcessNames = @(
    'wininit.exe', 'winlogon.exe', 'csrss.exe', 'smss.exe', 'services.exe',
    'lsass.exe', 'svchost.exe', 'spoolsv.exe', 'dwm.exe', 'fontdrivehost.exe',
    'System', 'Registry', 'Idle', 'MemCompression', 'Secure System',
    'explorer.exe', 'sihost.exe', 'ctfmon.exe', 'RuntimeBroker.exe'
)

function Test-SystemProcess($cim) {
    if ($script:SystemProcessNames -contains $cim.Name) { return $true }
    if ($cim.ExecutablePath -and $cim.ExecutablePath.StartsWith($env:WINDIR, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

# "Dead parent" is NOT a safe orphan signal on its own: Electron/multi-process
# apps (IDEs, terminals, browsers) routinely have a launcher/shim parent that
# exits right after spawning the real window process - that looks exactly
# like an orphan too, but killing it closes a real app the user has open
# (this happened once with Warp and an IDE - never again). So "Huerfano"
# is only ever computed for a narrow allowlist of known dev-server
# interpreters; everything else always reports Activo and is never
# kill-eligible, even if it technically has a dead parent.
$script:DevProcessNames = @('node.exe', 'npm.cmd', 'npm', 'php.exe', 'php-cgi.exe', 'python.exe', 'pythonw.exe', 'ruby.exe', 'deno.exe', 'bun.exe')
$script:DevCmdPattern = 'npm|node|vite|next|nodemon|ts-node|yarn|pnpm|artisan|webpack|parcel|react-scripts|ng serve'

function Test-DevProcess($cim) {
    if ($script:DevProcessNames -contains $cim.Name) { return $true }
    if ($cim.Name -eq 'cmd.exe' -and $cim.CommandLine -and $cim.CommandLine -match $script:DevCmdPattern) { return $true }
    return $false
}

function Get-DevPorts {
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalPort, OwningProcess -Unique |
        Group-Object OwningProcess

    if (-not $listeners) { return @() }

    # One bulk WMI query instead of up to two Get-CimInstance calls per
    # listener (this was the "runs slow" complaint - dozens of individual
    # WMI round-trips add up to several seconds).
    $procById = @{}
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $procById[[int]$p.ProcessId] = $p }
    $liveById = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $liveById[$p.Id] = $p }

    $rows = foreach ($group in $listeners) {
        $procId = [int]$group.Name
        $cim = $procById[$procId]
        if (-not $cim) { continue }
        if (Test-SystemProcess $cim) { continue }

        $proc = $liveById[$procId]
        $parentId = [int]$cim.ParentProcessId
        $parentCim = $procById[$parentId]

        $parentAlive = $true
        if (-not $parentCim) {
            $parentAlive = $false
        } elseif ($proc -and $proc.StartTime -and $parentCim.CreationDate -and $parentCim.CreationDate -gt $proc.StartTime) {
            $parentAlive = $false
        }
        $isDev = Test-DevProcess $cim

        $ports = ($group.Group.LocalPort | Sort-Object -Unique) -join ', '

        [PSCustomObject]@{
            Puertos   = $ports
            PID       = $procId
            Proceso   = $cim.Name
            Estado    = if ($isDev -and -not $parentAlive) { 'Huerfano' } else { 'Activo' }
            ParentPID = $parentId
            Inicio    = if ($proc) { $proc.StartTime } else { $null }
            Comando   = $cim.CommandLine
        }
    }

    $rows | Sort-Object @{Expression = 'Estado'; Descending = $true}, Puertos
}

function Stop-ProcessTreeByPid([int]$targetPid) {
    # Defense in depth: re-check right before killing, never trust a
    # possibly-stale grid row for a destructive action. Only ever kill
    # something that is BOTH not a system process AND matches the dev
    # interpreter allowlist - never a bare "parent is dead" call.
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
    if (-not $cim -or (Test-SystemProcess $cim) -or -not (Test-DevProcess $cim)) { return }
    Start-Process -FilePath "$env:WINDIR\System32\taskkill.exe" -ArgumentList "/PID $targetPid /T /F" -WindowStyle Hidden -Wait
}

# --- Dashboard window --------------------------------------------------------

function Show-Dashboard {
    if ($script:DashboardForm -and -not $script:DashboardForm.IsDisposed) {
        $script:DashboardForm.Activate()
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'McPorts - Puertos y procesos de desarrollo'
    $form.Size = New-Object System.Drawing.Size(980, 560)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(700, 400)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = 'AllCells'
    $grid.RowHeadersVisible = $false

    $legend = New-Object System.Windows.Forms.Label
    $legend.Dock = 'Top'
    $legend.Height = 26
    $legend.Padding = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
    $legend.Text = 'Filas en rojo = huerfano (candidato seguro a matar). El resto son procesos activos, no se tocan.'

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 44

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Actualizar'
    $btnRefresh.Location = New-Object System.Drawing.Point(10, 8)
    $btnRefresh.Size = New-Object System.Drawing.Size(100, 28)

    $btnKillSelected = New-Object System.Windows.Forms.Button
    $btnKillSelected.Text = 'Matar seleccionados'
    $btnKillSelected.Location = New-Object System.Drawing.Point(120, 8)
    $btnKillSelected.Size = New-Object System.Drawing.Size(150, 28)

    $btnKillOrphans = New-Object System.Windows.Forms.Button
    $btnKillOrphans.Text = 'Matar todos los huerfanos'
    $btnKillOrphans.Location = New-Object System.Drawing.Point(280, 8)
    $btnKillOrphans.Size = New-Object System.Drawing.Size(180, 28)
    $btnKillOrphans.ForeColor = [System.Drawing.Color]::DarkRed

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.AutoSize = $true
    $lblCount.Location = New-Object System.Drawing.Point(480, 15)
    $lblCount.Text = ''

    $bottom.Controls.AddRange(@($btnRefresh, $btnKillSelected, $btnKillOrphans, $lblCount))

    $refresh = {
        $data = @(Get-DevPorts)
        $grid.DataSource = [System.Collections.ArrayList]$data

        foreach ($colName in @('ParentPID', 'Inicio')) {
            if ($grid.Columns[$colName]) { $grid.Columns[$colName].Visible = $false }
        }
        if ($grid.Columns['Comando']) { $grid.Columns['Comando'].AutoSizeMode = 'Fill' }

        # Color rows synchronously right after binding instead of via
        # CellFormatting - that event fired with stale row indices during
        # a live refresh and crashed the app ("cannot index into a null
        # array"). This runs once per refresh, no race.
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            if ($grid.Rows[$i].Cells['Estado'].Value -eq 'Huerfano') {
                $grid.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
            }
        }

        $orphanCount = ($data | Where-Object { $_.Estado -eq 'Huerfano' }).Count
        $lblCount.Text = "$($data.Count) procesos escuchando - $orphanCount huerfanos"
        Update-TrayTooltip $orphanCount
    }

    $btnRefresh.add_Click({
        try { & $refresh } catch { [System.Windows.Forms.MessageBox]::Show("Error al actualizar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $btnKillSelected.add_Click({
        try {
            $pids = $grid.SelectedRows | ForEach-Object { $_.Cells['PID'].Value }
            foreach ($p in ($pids | Select-Object -Unique)) { Stop-ProcessTreeByPid $p }
            & $refresh
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $btnKillOrphans.add_Click({
        try {
            $orphanPids = @($grid.Rows | Where-Object { $_.Cells['Estado'].Value -eq 'Huerfano' } | ForEach-Object { $_.Cells['PID'].Value })
            if ($orphanPids.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('No hay procesos huerfanos ahora mismo.', 'McPorts') | Out-Null
                return
            }
            $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a matar $($orphanPids.Count) proceso(s) huerfano(s). Continuar?", 'McPorts', 'YesNo', 'Warning')
            if ($confirm -eq 'Yes') {
                foreach ($p in $orphanPids) { Stop-ProcessTreeByPid $p }
                & $refresh
            }
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $form.Controls.Add($grid)
    $form.Controls.Add($legend)
    $form.Controls.Add($bottom)

    try { & $refresh } catch { [System.Windows.Forms.MessageBox]::Show("Error al cargar: $($_.Exception.Message)", 'McPorts') | Out-Null }

    $script:DashboardForm = $form
    $form.Show()
    $form.Activate()
}

# --- Tray icon ---------------------------------------------------------------

function Update-TrayTooltip([int]$orphanCount) {
    $text = if ($orphanCount -gt 0) { "McPorts - $orphanCount huerfanos detectados" } else { 'McPorts - todo limpio' }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:TrayIcon.Text = $text
}

function Test-StartupEnabled { Test-Path $StartupShortcut }

function Set-StartupEnabled([bool]$enable) {
    if ($enable) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($StartupShortcut)
        $shortcut.TargetPath = $VbsLauncher
        $shortcut.WorkingDirectory = Split-Path $ScriptPath -Parent
        $shortcut.Description = 'McPorts - gestor de puertos de desarrollo'
        $shortcut.Save()
    } elseif (Test-Path $StartupShortcut) {
        Remove-Item $StartupShortcut -Force
    }
}

$icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = $icon
$trayIcon.Text = 'McPorts'
$trayIcon.Visible = $true
$script:TrayIcon = $trayIcon

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemOpen = $menu.Items.Add('Ver puertos ocupados')
$itemKillAll = $menu.Items.Add('Matar todos los huerfanos')
$menu.Items.Add('-') | Out-Null
$itemStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Iniciar con Windows')
$itemStartup.CheckOnClick = $true
$itemStartup.Checked = Test-StartupEnabled
$menu.Items.Add($itemStartup) | Out-Null
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Salir')

$itemOpen.add_Click({ Show-Dashboard })
$trayIcon.add_DoubleClick({ Show-Dashboard })
# A single left click is what most Windows 11 tray icons respond to
# (volume, network, etc.) - relying on double-click alone reads as
# "nothing happens" to anyone who clicks once and waits.
$trayIcon.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Dashboard }
})

$itemKillAll.add_Click({
    $orphans = @(Get-DevPorts | Where-Object { $_.Estado -eq 'Huerfano' })
    if ($orphans.Count -eq 0) {
        $trayIcon.ShowBalloonTip(3000, 'McPorts', 'No hay procesos huerfanos ahora mismo.', 'Info')
        return
    }
    foreach ($row in $orphans) { Stop-ProcessTreeByPid $row.PID }
    $trayIcon.ShowBalloonTip(3000, 'McPorts', "Se mataron $($orphans.Count) proceso(s) huerfano(s).", 'Info')
    Update-TrayTooltip 0
})

$itemStartup.add_Click({ Set-StartupEnabled $itemStartup.Checked })

$itemExit.add_Click({
    $trayIcon.Visible = $false
    $timer.Stop()
    [System.Windows.Forms.Application]::Exit()
})

$trayIcon.ContextMenuStrip = $menu

# Periodic background check: keeps the tooltip honest even if the
# dashboard is never opened. No auto-kill - the user drives that action.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5 * 60 * 1000
$timer.add_Tick({
    try {
        $orphanCount = (@(Get-DevPorts) | Where-Object { $_.Estado -eq 'Huerfano' }).Count
        Update-TrayTooltip $orphanCount
        if ($orphanCount -gt 0) {
            $trayIcon.ShowBalloonTip(4000, 'McPorts', "$orphanCount proceso(s) huerfano(s) ocupando puertos.", 'Warning')
        }
    } catch { }
})
$timer.Start()

try { Update-TrayTooltip (@(Get-DevPorts) | Where-Object { $_.Estado -eq 'Huerfano' }).Count } catch { }

[System.Windows.Forms.Application]::Run()
