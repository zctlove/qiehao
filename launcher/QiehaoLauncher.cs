using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Qiehao Launcher")]
[assembly: AssemblyDescription("Qiehao Launcher")]
[assembly: AssemblyProduct("Qiehao")]
[assembly: AssemblyCompany("Qiehao")]
[assembly: AssemblyVersion("1.1.1.0")]
[assembly: AssemblyFileVersion("1.1.1.0")]
[assembly: AssemblyInformationalVersion("1.1.1")]

namespace QiehaoLauncher
{
    internal static class Launcher
    {
        internal const string ScriptMissing = "Qiehao could not start: gui\\QiehaoGui.ps1 is missing. Fully extract the ZIP first.";
        internal const string PowerShellMissing = "Qiehao could not start: Windows PowerShell was not found.";
        internal const string StartFailed = "Qiehao could not start. Please try Start-Qiehao.cmd.";

        // Windows argv quoting, including quotes and trailing backslashes.
        internal static string QuoteArgument(string value)
        {
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                }
                else
                {
                    result.Append('\\', slashes);
                    result.Append(character);
                }
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }

        internal static ProcessStartInfo CreateStartInfo(string root, string windowsDirectory)
        {
            return new ProcessStartInfo
            {
                FileName = Path.Combine(windowsDirectory, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File " + QuoteArgument(Path.Combine(root, "gui", "QiehaoGui.ps1")),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
        }

        // Offline tests supply delegates; production uses Process.Start and MessageBox.
        internal static int Run(string root, string windowsDirectory,
            Action<ProcessStartInfo> start, Action<string> showError)
        {
            string failure = null;
            try
            {
                if (!File.Exists(Path.Combine(root, "gui", "QiehaoGui.ps1")))
                    failure = ScriptMissing;
                else
                {
                    ProcessStartInfo info = CreateStartInfo(root, windowsDirectory);
                    if (!File.Exists(info.FileName)) failure = PowerShellMissing;
                    else { start(info); return 0; }
                }
            }
            catch (Exception) { failure = StartFailed; }
            showError(failure);
            return 1;
        }

        [STAThread]
        private static int Main()
        {
            try
            {
                string root = Path.GetDirectoryName(typeof(Launcher).Assembly.Location);
                string windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                return Run(root, windowsDirectory,
                    delegate(ProcessStartInfo info)
                    {
                        using (Process process = Process.Start(info))
                        {
                            if (process == null) throw new InvalidOperationException();
                        }
                    }, ShowSafeError);
            }
            catch (Exception) { ShowSafeError(StartFailed); return 1; }
        }

        private static void ShowSafeError(string message)
        {
            MessageBox.Show(message, "Qiehao", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
