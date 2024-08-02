using System;
using System.Diagnostics;
using System.IO;

class Program
{
    static void Main(string[] args)
    {
        string appPath = AppDomain.CurrentDomain.BaseDirectory;
        string settingsPath = Path.Combine(appPath, "settings.json");
        string startScriptPath = Path.Combine(appPath, "start.ps1");

        if (!File.Exists(settingsPath))
        {
            // First run setup
            RunPowerShellScript(Path.Combine(appPath, "first_run_setup.ps1"));
        }

        // Run the main start script
        RunPowerShellScript(startScriptPath);
    }

    static void RunPowerShellScript(string scriptPath)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\"", scriptPath),
            UseShellExecute = false,
            CreateNoWindow = true
        };
        Process.Start(startInfo).WaitForExit();
    }
}
