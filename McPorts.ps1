Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Get-DevPorts {
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalPort, OwningProcess -Unique |
        Group-Object OwningProcess

    $rows = foreach ($group in $listeners) {
        $procId = [int]$group.Name
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
        if (-not $cim) { continue }
        if (Test-SystemProcess $cim) { continue }

        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $parentId = $cim.ParentProcessId
        $parentCim = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue

        # A PID whose recorded parent is gone (or whose PID was reused by a
        # process started AFTER this one) has no living original parent.
        $parentAlive = $true
        if (-not $parentCim) {
            $parentAlive = $false
        } elseif ($proc -and $proc.StartTime -and $parentCim.CreationDate -and $parentCim.CreationDate -gt $proc.StartTime) {
            $parentAlive = $false
        }

        $ports = ($group.Group.LocalPort | Sort-Object -Unique) -join ', '

        [PSCustomObject]@{
            Puertos   = $ports
            PID       = $procId
            Proceso   = $cim.Name
            Estado    = if ($parentAlive) { 'Activo' } else { 'Huerfano' }
            ParentPID = $parentId
            Inicio    = if ($proc) { $proc.StartTime } else { $null }
            Comando   = $cim.CommandLine
        }
    }

    $rows | Sort-Object @{Expression = 'Estado'; Descending = $true}, Puertos
}

function Stop-ProcessTreeByPid([int]$targetPid) {
    # Defense in depth: re-check right before killing, never trust a
    # possibly-stale grid row for a destructive action.
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
    if (-not $cim -or (Test-SystemProcess $cim)) { return }
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
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.RowHeadersVisible = $false

    $grid.add_CellFormatting({
        param($s, $e)
        $row = $grid.Rows[$e.RowIndex]
        if ($row.Cells['Estado'].Value -eq 'Huerfano') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
        }
    })

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
        $orphanCount = ($data | Where-Object { $_.Estado -eq 'Huerfano' }).Count
        $lblCount.Text = "$($data.Count) procesos escuchando - $orphanCount huerfanos"
        Update-TrayTooltip $orphanCount
    }

    $btnRefresh.add_Click($refresh)

    $btnKillSelected.add_Click({
        $pids = $grid.SelectedRows | ForEach-Object { $_.Cells['PID'].Value }
        foreach ($p in ($pids | Select-Object -Unique)) { Stop-ProcessTreeByPid $p }
        & $refresh
    })

    $btnKillOrphans.add_Click({
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
    })

    $form.Controls.Add($grid)
    $form.Controls.Add($bottom)

    & $refresh

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
    $orphanCount = (@(Get-DevPorts) | Where-Object { $_.Estado -eq 'Huerfano' }).Count
    Update-TrayTooltip $orphanCount
    if ($orphanCount -gt 0) {
        $trayIcon.ShowBalloonTip(4000, 'McPorts', "$orphanCount proceso(s) huerfano(s) ocupando puertos.", 'Warning')
    }
})
$timer.Start()

Update-TrayTooltip (@(Get-DevPorts) | Where-Object { $_.Estado -eq 'Huerfano' }).Count

[System.Windows.Forms.Application]::Run()
