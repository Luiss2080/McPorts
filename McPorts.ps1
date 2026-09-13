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
    $form.Size = New-Object System.Drawing.Size(1080, 620)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(760, 420)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $script:grid = New-Object System.Windows.Forms.DataGridView
    $script:grid.Dock = 'Fill'
    $script:grid.ReadOnly = $false
    $script:grid.AllowUserToAddRows = $false
    $script:grid.AllowUserToDeleteRows = $false
    $script:grid.SelectionMode = 'FullRowSelect'
    $script:grid.MultiSelect = $true
    $script:grid.AutoSizeColumnsMode = 'AllCells'
    $script:grid.RowHeadersVisible = $false
    $script:grid.RowTemplate.Height = 26
    $script:grid.BackgroundColor = [System.Drawing.Color]::White
    $script:grid.BorderStyle = 'None'
    $script:grid.GridColor = [System.Drawing.Color]::FromArgb(225, 225, 230)
    $script:grid.EnableHeadersVisualStyles = $false
    $script:grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 55, 72)
    $script:grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $script:grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:grid.ColumnHeadersHeight = 30
    $script:grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

    $legend = New-Object System.Windows.Forms.Label
    $legend.Dock = 'Top'
    $legend.Height = 26
    $legend.Padding = New-Object System.Windows.Forms.Padding(10, 6, 0, 0)
    $legend.Text = 'Rojo = huerfano, se puede matar con seguridad.   Verde = servidor de desarrollo activo.   Gris = otra app o servicio, McPorts nunca lo toca.'

    $searchBar = New-Object System.Windows.Forms.Panel
    $searchBar.Dock = 'Top'
    $searchBar.Height = 36
    $searchBar.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = 'Buscar:'
    $lblSearch.AutoSize = $true
    $lblSearch.Location = New-Object System.Drawing.Point(10, 8)

    $script:txtSearch = New-Object System.Windows.Forms.TextBox
    $script:txtSearch.Location = New-Object System.Drawing.Point(65, 5)
    $script:txtSearch.Size = New-Object System.Drawing.Size(280, 24)

    $script:chkAuto = New-Object System.Windows.Forms.CheckBox
    $script:chkAuto.Text = 'Auto-actualizar (5s)'
    $script:chkAuto.AutoSize = $true
    $script:chkAuto.Location = New-Object System.Drawing.Point(360, 8)

    $searchBar.Controls.AddRange(@($lblSearch, $script:txtSearch, $script:chkAuto))

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 88

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Top'
    $flow.Height = 40
    $flow.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0)
    $flow.WrapContents = $false
    $flow.AutoScroll = $true

    function New-ToolButton([string]$text, [int]$width) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Size = New-Object System.Drawing.Size($width, 30)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        return $b
    }

    $btnRefresh = New-ToolButton ([char]0x21BB + ' Actualizar') 110
    $btnSelAll = New-ToolButton 'Marcar todos' 110
    $btnSelNone = New-ToolButton 'Marcar ninguno' 120
    $btnSelOrphans = New-ToolButton 'Marcar huerfanos' 140
    $btnKillSelected = New-ToolButton ([char]0x2715 + ' Limpiar marcados') 170
    $script:btnKillOrphans = New-ToolButton ([char]0x26A0 + ' Limpiar todo lo no usado') 220
    $script:btnKillOrphans.FlatStyle = 'Flat'

    $flow.Controls.AddRange(@($btnRefresh, $btnSelAll, $btnSelNone, $btnSelOrphans, $btnKillSelected, $script:btnKillOrphans))

    $script:lblCount = New-Object System.Windows.Forms.Label
    $script:lblCount.AutoSize = $true
    $script:lblCount.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:lblCount.Padding = New-Object System.Windows.Forms.Padding(10, 10, 0, 0)
    $script:lblCount.Dock = 'Bottom'
    $script:lblCount.Height = 26
    $script:lblCount.Text = ''

    $bottom.Controls.Add($script:lblCount)
    $bottom.Controls.Add($flow)

    $script:colorHuerfano = [System.Drawing.Color]::Crimson
    $script:colorActivoDev = [System.Drawing.Color]::SeaGreen
    $script:colorOtro = [System.Drawing.Color]::Gray

    # bindGrid renders a data array (already filtered by search text if
    # any) without re-querying Windows - filtering/typing stays instant.
    $script:bindGrid = {
        param($data)

        $script:grid.DataSource = [System.Collections.ArrayList]$data

        foreach ($colName in @('EsDev', 'ParentPID')) {
            if ($script:grid.Columns[$colName]) { $script:grid.Columns[$colName].Visible = $false }
        }
        if ($script:grid.Columns['Comando']) { $script:grid.Columns['Comando'].AutoSizeMode = 'Fill' }
        foreach ($colName in @('Puertos', 'PID', 'Proceso', 'Estado', 'Actividad', 'Comando')) {
            if ($script:grid.Columns[$colName]) { $script:grid.Columns[$colName].ReadOnly = $true }
        }

        $selCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
        $selCol.Name = 'Sel'
        $selCol.HeaderText = ''
        $selCol.Width = 30
        $script:grid.Columns.Insert(0, $selCol)

        $dotCol = New-Object System.Windows.Forms.DataGridViewImageColumn
        $dotCol.Name = 'Dot'
        $dotCol.HeaderText = ''
        $dotCol.Width = 26
        $dotCol.ImageLayout = 'Zoom'
        $dotCol.ReadOnly = $true
        $dotCol.DefaultCellStyle.NullValue = $null
        $script:grid.Columns.Insert(1, $dotCol)

        # Color rows synchronously right after binding instead of via
        # CellFormatting - that event fired with stale row indices during
        # a live refresh and crashed the app ("cannot index into a null
        # array"). This runs once per bind, no race.
        for ($i = 0; $i -lt $script:grid.Rows.Count; $i++) {
            $row = $script:grid.Rows[$i]
            $isHuerfano = $row.Cells['Estado'].Value -eq 'Huerfano'
            $isDev = $row.Cells['EsDev'].Value -eq $true

            if ($isHuerfano) {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 235, 235)
                $row.Cells['Estado'].Style.ForeColor = $script:colorHuerfano
                $row.Cells['Estado'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
                $row.Cells['Dot'].Value = Get-StatusDot $script:colorHuerfano
                $row.Cells['Sel'].Value = $true
            } elseif ($isDev) {
                $row.Cells['Estado'].Style.ForeColor = $script:colorActivoDev
                $row.Cells['Dot'].Value = Get-StatusDot $script:colorActivoDev
            } else {
                $row.Cells['Estado'].Style.ForeColor = $script:colorOtro
                $row.Cells['Dot'].Value = Get-StatusDot $script:colorOtro
                $row.Cells['Sel'].ReadOnly = $true
            }
        }
    }

    # applyFilter re-slices the already-fetched $script:AllData by the
    # search box text and rebinds - no WMI calls, stays instant while typing.
    $script:applyFilter = {
        $text = $script:txtSearch.Text
        $data = if ([string]::IsNullOrWhiteSpace($text)) {
            $script:AllData
        } else {
            $script:AllData | Where-Object {
                $_.Proceso -like "*$text*" -or $_.Puertos -like "*$text*" -or
                [string]$_.PID -like "*$text*" -or $_.Comando -like "*$text*"
            }
        }
        & $script:bindGrid @($data)

        $total = @($script:AllData).Count
        $orphanCount = @($script:AllData | Where-Object { $_.Estado -eq 'Huerfano' }).Count
        $shown = @($data).Count
        $script:lblCount.Text = if ($shown -eq $total) { "$total procesos escuchando - $orphanCount huerfanos" } else { "Mostrando $shown de $total - $orphanCount huerfanos en total" }
        Update-TrayTooltip $orphanCount

        $script:btnKillOrphans.Enabled = $orphanCount -gt 0
        if ($orphanCount -gt 0) {
            $script:btnKillOrphans.BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
            $script:btnKillOrphans.ForeColor = [System.Drawing.Color]::White
        } else {
            $script:btnKillOrphans.BackColor = [System.Drawing.SystemColors]::Control
            $script:btnKillOrphans.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
    }

    $script:refresh = {
        $script:AllData = @(Get-DevPorts)
        & $script:applyFilter
    }

    # Checkbox edits don't commit until focus leaves the cell by default -
    # without this a single click looks like it did nothing.
    $script:grid.add_CurrentCellDirtyStateChanged({
        if ($script:grid.IsCurrentCellDirty -and $script:grid.CurrentCell.OwningColumn.Name -eq 'Sel') {
            $script:grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $script:txtSearch.add_TextChanged({
        try { & $script:applyFilter } catch { }
    })

    $script:autoTimer = New-Object System.Windows.Forms.Timer
    $script:autoTimer.Interval = 5000
    $script:autoTimer.add_Tick({
        try { & $script:refresh } catch { }
    })
    $script:chkAuto.add_CheckedChanged({
        if ($script:chkAuto.Checked) { $script:autoTimer.Start() } else { $script:autoTimer.Stop() }
    })

    $btnRefresh.add_Click({
        try { & $script:refresh } catch { [System.Windows.Forms.MessageBox]::Show("Error al actualizar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $btnSelAll.add_Click({
        for ($i = 0; $i -lt $script:grid.Rows.Count; $i++) { if (-not $script:grid.Rows[$i].Cells['Sel'].ReadOnly) { $script:grid.Rows[$i].Cells['Sel'].Value = $true } }
    })
    $btnSelNone.add_Click({
        for ($i = 0; $i -lt $script:grid.Rows.Count; $i++) { $script:grid.Rows[$i].Cells['Sel'].Value = $false }
    })
    $btnSelOrphans.add_Click({
        for ($i = 0; $i -lt $script:grid.Rows.Count; $i++) { $script:grid.Rows[$i].Cells['Sel'].Value = ($script:grid.Rows[$i].Cells['Estado'].Value -eq 'Huerfano') }
    })

    $script:showKillSummary = {
        param($results)
        $matados = @($results | Where-Object { $_ -eq 'Matado' }).Count
        $omitidos = @($results | Where-Object { $_ -eq 'OmitidoSeguridad' }).Count
        $lines = @("Matados: $matados")
        if ($omitidos -gt 0) { $lines += "Omitidos por seguridad (no son procesos de desarrollo reconocidos): $omitidos" }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), 'McPorts') | Out-Null
    }

    $btnKillSelected.add_Click({
        try {
            $pids = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $script:grid.Rows.Count; $i++) {
                if ($script:grid.Rows[$i].Cells['Sel'].Value -eq $true) { $pids.Add([int]$script:grid.Rows[$i].Cells['PID'].Value) }
            }
            $pids = @($pids | Select-Object -Unique)
            if ($pids.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('MarcÃ¡ el casillero de una o mas filas primero (columna de la izquierda).', 'McPorts') | Out-Null
                return
            }
            $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a limpiar $($pids.Count) proceso(s) marcados. Continuar?", 'McPorts', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { return }
            $results = @($pids | ForEach-Object { Stop-ProcessTreeByPid $_ })
            & $script:refresh
            & $script:showKillSummary $results
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $script:btnKillOrphans.add_Click({
        try {
            $orphanPids = @($script:AllData | Where-Object { $_.Estado -eq 'Huerfano' } | ForEach-Object { $_.PID })
            if ($orphanPids.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('No hay procesos huerfanos ahora mismo.', 'McPorts') | Out-Null
                return
            }
            $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a limpiar $($orphanPids.Count) proceso(s) huerfano(s) (servidores abandonados sin proceso padre). Continuar?", 'McPorts', 'YesNo', 'Warning')
            if ($confirm -eq 'Yes') {
                $results = @($orphanPids | ForEach-Object { Stop-ProcessTreeByPid $_ })
                & $script:refresh
                & $script:showKillSummary $results
            }
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $rowMenuKill = $rowMenu.Items.Add('Matar este proceso')
    $rowMenuBrowser = $rowMenu.Items.Add('Abrir en el navegador')
    $rowMenuCopy = $rowMenu.Items.Add('Copiar comando completo')
    $script:grid.ContextMenuStrip = $rowMenu

    $script:grid.add_CellMouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
            $script:grid.ClearSelection()
            $script:grid.Rows[$e.RowIndex].Selected = $true
        }
    })

    $script:grid.add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $script:grid.Rows[$e.RowIndex]
        $msg = "Proceso: $($row.Cells['Proceso'].Value)  (PID $($row.Cells['PID'].Value))`nPuertos: $($row.Cells['Puertos'].Value)`nActividad: $($row.Cells['Actividad'].Value)`n`nComando completo:`n$($row.Cells['Comando'].Value)"
        [System.Windows.Forms.MessageBox]::Show($msg, 'McPorts - Detalle del proceso') | Out-Null
    })

    $rowMenuKill.add_Click({
        try {
            $pids = @($script:grid.SelectedRows | ForEach-Object { $_.Cells['PID'].Value } | Select-Object -Unique)
            if ($pids.Count -eq 0) { return }
            $results = @($pids | ForEach-Object { Stop-ProcessTreeByPid $_ })
            & $script:refresh
            & $script:showKillSummary $results
        } catch { [System.Windows.Forms.MessageBox]::Show("Error al matar: $($_.Exception.Message)", 'McPorts') | Out-Null }
    })

    $rowMenuBrowser.add_Click({
        try {
            $ports = $script:grid.SelectedRows | Select-Object -First 1 | ForEach-Object { $_.Cells['Puertos'].Value }
            if (-not $ports) { return }
            $firstPort = ([string]$ports).Split(',')[0].Trim()
            if ($firstPort) { Start-Process "http://localhost:$firstPort" }
        } catch { }
    })

    $rowMenuCopy.add_Click({
        try {
            $cmd = $script:grid.SelectedRows | Select-Object -First 1 | ForEach-Object { $_.Cells['Comando'].Value }
            if ($cmd) { [System.Windows.Forms.Clipboard]::SetText([string]$cmd) }
        } catch { }
    })

    $form.Controls.Add($script:grid)
    $form.Controls.Add($searchBar)
    $form.Controls.Add($legend)
    $form.Controls.Add($bottom)

    $form.add_FormClosed({ $script:autoTimer.Stop(); $script:autoTimer.Dispose() })

    try { & $script:refresh } catch { [System.Windows.Forms.MessageBox]::Show("Error al cargar: $($_.Exception.Message)", 'McPorts') | Out-Null }

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
