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

        $actividad = ''
        if ($proc -and $proc.StartTime) {
            $span = (Get-Date) - $proc.StartTime
            $actividad = if ($span.TotalDays -ge 1) { "{0}d {1}h" -f [int]$span.TotalDays, $span.Hours }
                elseif ($span.TotalHours -ge 1) { "{0}h {1}m" -f [int]$span.TotalHours, $span.Minutes }
                else { "{0}m" -f [Math]::Max(1, [int]$span.TotalMinutes) }
        }

        [PSCustomObject]@{
            Puertos   = $ports
            PID       = $procId
            Proceso   = $cim.Name
            Estado    = if ($isDev -and -not $parentAlive) { 'Huerfano' } else { 'Activo' }
            EsDev     = $isDev
            ParentPID = $parentId
            Actividad = $actividad
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
    # Returns what actually happened so the UI can report honestly
    # instead of silently doing nothing.
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
    if (-not $cim) { return 'NoEncontrado' }
    if ((Test-SystemProcess $cim) -or -not (Test-DevProcess $cim)) { return 'OmitidoSeguridad' }
    Start-Process -FilePath "$env:WINDIR\System32\taskkill.exe" -ArgumentList "/PID $targetPid /T /F" -WindowStyle Hidden -Wait
    return 'Matado'
}

# --- Dashboard window --------------------------------------------------------

$script:DotCache = @{}
function Get-StatusDot([System.Drawing.Color]$color) {
    $key = $color.ToArgb()
    if ($script:DotCache.ContainsKey($key)) { return $script:DotCache[$key] }
    $bmp = New-Object System.Drawing.Bitmap(14, 14)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, 1, 1, 12, 12)
    $g.Dispose(); $brush.Dispose()
    $script:DotCache[$key] = $bmp
    return $bmp
}

function Show-Dashboard {
    if ($script:DashboardForm -and -not $script:DashboardForm.IsDisposed) {
        $script:DashboardForm.Activate()
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'McPorts - Puertos y procesos de desarrollo'
    $form.Size = New-Object System.Drawing.Size(1040, 580)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(760, 420)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = 'AllCells'
    $grid.RowHeadersVisible = $false
    $grid.RowTemplate.Height = 26
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = 'None'
    $grid.GridColor = [System.Drawing.Color]::FromArgb(225, 225, 230)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 55, 72)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersHeight = 30
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

    $legend = New-Object System.Windows.Forms.Label
    $legend.Dock = 'Top'
    $legend.Height = 28
    $legend.Padding = New-Object System.Windows.Forms.Padding(10, 7, 0, 0)
    $legend.Text = 'Rojo = huerfano, se puede matar con seguridad.   Verde = servidor de desarrollo activo.   Gris = otra app o servicio, McPorts nunca lo toca.'

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 48
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = [char]0x21BB + ' Actualizar'
    $btnRefresh.Location = New-Object System.Drawing.Point(10, 9)
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 30)
    $btnRefresh.Cursor = [System.Windows.Forms.Cursors]::Hand

    $btnKillSelected = New-Object System.Windows.Forms.Button
    $btnKillSelected.Text = [char]0x2715 + ' Matar seleccionados'
    $btnKillSelected.Location = New-Object System.Drawing.Point(126, 9)
    $btnKillSelected.Size = New-Object System.Drawing.Size(170, 30)
    $btnKillSelected.Cursor = [System.Windows.Forms.Cursors]::Hand

    $btnKillOrphans = New-Object System.Windows.Forms.Button
    $btnKillOrphans.Text = [char]0x26A0 + ' Matar todos los huerfanos'
    $btnKillOrphans.Location = New-Object System.Drawing.Point(302, 9)
    $btnKillOrphans.Size = New-Object System.Drawing.Size(210, 30)
    $btnKillOrphans.FlatStyle = 'Flat'
    $btnKillOrphans.Cursor = [System.Windows.Forms.Cursors]::Hand

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.AutoSize = $true
    $lblCount.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblCount.Location = New-Object System.Drawing.Point(524, 17)
    $lblCount.Text = ''

    $bottom.Controls.AddRange(@($btnRefresh, $btnKillSelected, $btnKillOrphans, $lblCount))

    $colorHuerfano = [System.Drawing.Color]::Crimson
    $colorActivoDev = [System.Drawing.Color]::SeaGreen
    $colorOtro = [System.Drawing.Color]::Gray

    $refresh = {
        $data = @(Get-DevPorts)
        $grid.DataSource = [System.Collections.ArrayList]$data

        foreach ($colName in @('EsDev', 'ParentPID')) {
            if ($grid.Columns[$colName]) { $grid.Columns[$colName].Visible = $false }
        }
        if ($grid.Columns['Comando']) { $grid.Columns['Comando'].AutoSizeMode = 'Fill' }

        $dotCol = New-Object System.Windows.Forms.DataGridViewImageColumn
        $dotCol.Name = 'Dot'
        $dotCol.HeaderText = ''
        $dotCol.Width = 28
        $dotCol.ImageLayout = 'Zoom'
        $dotCol.DefaultCellStyle.NullValue = $null
        $grid.Columns.Insert(0, $dotCol)

        # Color rows synchronously right after binding instead of via
        # CellFormatting - that event fired with stale row indices during
        # a live refresh and crashed the app ("cannot index into a null
        # array"). This runs once per refresh, no race.
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            $row = $grid.Rows[$i]
            $isHuerfano = $row.Cells['Estado'].Value -eq 'Huerfano'
            $isDev = $row.Cells['EsDev'].Value -eq $true

            if ($isHuerfano) {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 235, 235)
                $row.Cells['Estado'].Style.ForeColor = $colorHuerfano
                $row.Cells['Estado'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                $row.Cells['Dot'].Value = Get-StatusDot $colorHuerfano
            } elseif ($isDev) {
                $row.Cells['Estado'].Style.ForeColor = $colorActivoDev
                $row.Cells['Dot'].Value = Get-StatusDot $colorActivoDev
            } else {
                $row.Cells['Estado'].Style.ForeColor = $colorOtro
                $row.Cells['Dot'].Value = Get-StatusDot $colorOtro
            }
        }

        $orphanCount = ($data | Where-Object { $_.Estado -eq 'Huerfano' }).Count
        $lblCount.Text = "$($data.Count) procesos escuchando - $orphanCount huerfanos"
        Update-TrayTooltip $orphanCount

        $btnKillOrphans.Enabled = $orphanCount -gt 0
        if ($orphanCount -gt 0) {
            $btnKillOrphans.BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
            $btnKillOrphans.ForeColor = [System.Drawing.Color]::White
        } else {
            $btnKillOrphans.BackColor = [System.Drawing.SystemColors]::Control
            $btnKillOrphans.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
    }

    $btnRefresh.add_Click({
        try { & $refresh } catch { [System.Windows.Forms.MessageBox]::Show("Error al actualizar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $showKillSummary = {
        param($results)
        $matados = @($results | Where-Object { $_ -eq 'Matado' }).Count
        $omitidos = @($results | Where-Object { $_ -eq 'OmitidoSeguridad' }).Count
        $lines = @("Matados: $matados")
        if ($omitidos -gt 0) { $lines += "Omitidos por seguridad (no son procesos de desarrollo reconocidos): $omitidos" }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), 'McPorts') | Out-Null
    }

    $btnKillSelected.add_Click({
        try {
            $pids = @($grid.SelectedRows | ForEach-Object { $_.Cells['PID'].Value } | Select-Object -Unique)
            if ($pids.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('Seleccioná primero una o mas filas.', 'McPorts') | Out-Null
                return
            }
            $results = @($pids | ForEach-Object { Stop-ProcessTreeByPid $_ })
            & $refresh
            & $showKillSummary $results
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
                $results = @($orphanPids | ForEach-Object { Stop-ProcessTreeByPid $_ })
                & $refresh
                & $showKillSummary $results
            }
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $rowMenuKill = $rowMenu.Items.Add('Matar este proceso')
    $rowMenuCopy = $rowMenu.Items.Add('Copiar comando completo')
    $grid.ContextMenuStrip = $rowMenu

    $grid.add_CellMouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
            $grid.ClearSelection()
            $grid.Rows[$e.RowIndex].Selected = $true
        }
    })

    $rowMenuKill.add_Click({
        try {
            $pids = @($grid.SelectedRows | ForEach-Object { $_.Cells['PID'].Value } | Select-Object -Unique)
            if ($pids.Count -eq 0) { return }
            $results = @($pids | ForEach-Object { Stop-ProcessTreeByPid $_ })
            & $refresh
            & $showKillSummary $results
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $rowMenuCopy.add_Click({
        try {
            $cmd = $grid.SelectedRows | Select-Object -First 1 | ForEach-Object { $_.Cells['Comando'].Value }
            if ($cmd) { [System.Windows.Forms.Clipboard]::SetText([string]$cmd) }
        } catch { }
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
