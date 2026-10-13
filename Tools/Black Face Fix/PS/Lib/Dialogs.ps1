# Dialogs.ps1 - where the window reaches the desktop: message boxes, the folder
# picker, Explorer, and the modal loop that keeps the window open.
#
# Kept apart from Gui.ps1 so that file can be tested to the last line. Everything
# here puts something on screen and waits for a person, which no test can do, so
# each function is one call into Windows and decides nothing. The component tests
# mock them; Gui.ps1 reaches them only through the dialog hooks on its context and
# through Show-BffWindow.

Add-Type -AssemblyName System.Windows.Forms

function Show-BffQuestion {
    <#
    .SYNOPSIS
    A Yes/No message box. $true for Yes.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Title)

    return [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-BffMessage {
    <#
    .SYNOPSIS
    An OK message box. Icon is a MessageBoxIcon name: Information, Warning, Error.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Title, [string] $Icon = 'Information')

    [void] [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon] $Icon)
}

function Select-BffFolder {
    <#
    .SYNOPSIS
    The folder picker. The chosen path, or $null when it was cancelled.
    #>
    [CmdletBinding()]
    param([string] $Description)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally { $dialog.Dispose() }
}

function Open-BffFolder {
    [CmdletBinding()]
    param([string] $Path)

    Start-Process explorer.exe $Path
}

function Show-BffWindow {
    <#
    .SYNOPSIS
    Shows a form until it is closed, then disposes it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Windows.Forms.Form] $Form)

    try { [void] $Form.ShowDialog() }
    finally { $Form.Dispose() }
}
