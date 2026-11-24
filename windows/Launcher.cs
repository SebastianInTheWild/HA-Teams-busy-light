// Starts TeamsBusyLight.ps1 without a console window.
//
// "powershell.exe -WindowStyle Hidden" still flashes a window, and with
// Windows Terminal as the default terminal it may stay visible. This small
// program starts PowerShell without any console instead. The release
// workflow compiles it with the C# compiler of the .NET Framework that ships
// with Windows (New-TeamsLauncher in Common.ps1) and ships it in the download.
//
// Arguments are passed on to the script, e.g. TeamsBusyLight.exe -Settings
using System;
using System.Diagnostics;
using System.IO;

[assembly: System.Reflection.AssemblyTitle("Teams Busy Light")]
[assembly: System.Reflection.AssemblyProduct("Teams Busy Light")]

static class Launcher
{
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "TeamsBusyLight.ps1");
        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        string arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        foreach (string arg in args)
        {
            if (arg.StartsWith("-") && arg.IndexOfAny(new[] { ' ', '"' }) < 0)
            {
                arguments += " " + arg;
            }
        }

        var start = new ProcessStartInfo(powershell, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        Process.Start(start);
        return 0;
    }
}
