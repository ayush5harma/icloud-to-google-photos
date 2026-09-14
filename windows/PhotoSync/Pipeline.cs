// Where the pipeline's scripts are, the bash that runs them, and how to start
// one without a console window.
//
// THE LOCATION COMES FROM ONE PLACE: PhotoSync.settings.json beside the exe,
// written by windows\build.ps1 at install time. The environment is deliberately
// NOT consulted -- the macOS app's rule, for the same reason: whatever decides
// WHAT this app runs decides what runs every fifteen minutes from Task
// Scheduler, so it is recorded by an installer rather than inherited from
// whoever started the process. There is no general "run this" mode either;
// Program.cs maps each CLI mode to one fixed script.
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace PhotoSync;

internal sealed class Pipeline
{
    public const string SettingsFile = "PhotoSync.settings.json";
    // Must match AP_TASK_FOLDER in lib/config.sh and $TaskFolder in install.ps1.
    public const string TaskFolder = @"\icloud-to-google-photos\";

    public string Bash { get; }
    public string BinDir { get; }
    /// <summary>Git's usr\bin and mingw64\bin, which must lead PATH before any script starts.</summary>
    public string GitPath { get; }

    private Pipeline(string bash, string binDir)
    {
        Bash = bash;
        BinDir = binDir;
        var gitRoot = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(bash)))!;
        GitPath = Path.Combine(gitRoot, "usr", "bin") + ";" + Path.Combine(gitRoot, "mingw64", "bin");
    }

    public static Pipeline? Load(out string? error)
    {
        error = null;
        var file = Path.Combine(AppContext.BaseDirectory, SettingsFile);
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(file));
            var bash = doc.RootElement.GetProperty("bash").GetString() ?? "";
            var bin = doc.RootElement.GetProperty("binDir").GetString() ?? "";
            if (!File.Exists(bash)) { error = $"bash not found at {bash} — re-run install.ps1"; return null; }
            if (!Directory.Exists(bin)) { error = $"the pipeline's commands are not at {bin} — re-run install.ps1"; return null; }
            return new Pipeline(bash, bin);
        }
        catch (Exception e) when (e is IOException or JsonException or KeyNotFoundException or UnauthorizedAccessException)
        {
            error = $"{SettingsFile} is missing or unreadable — re-run install.ps1";
            return null;
        }
    }

    /// <summary>The script's path (forward slashes, as bash wants it), or null when it is not there.</summary>
    public string? Script(string name)
    {
        var p = BinDir.TrimEnd('/', '\\') + "/" + name;
        return File.Exists(p) ? p : null;
    }

    /// <summary>
    /// bash running <paramref name="script"/>, with no console window: a bash
    /// started from a windowless process gets a console of its own, hidden, and
    /// every adb, emulator and icloudpd it starts shares that one instead of
    /// flashing its own.
    /// </summary>
    public ProcessStartInfo StartInfo(string script, IEnumerable<string> args)
    {
        var psi = new ProcessStartInfo(Bash)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        psi.ArgumentList.Add(script);
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["PATH"] = GitPath + ";" + (psi.Environment.TryGetValue("PATH", out var p) ? p : "");
        return psi;
    }

    // The state and log directories, resolved exactly as lib/config.sh does.
    // Only for OPENING the logs folder and for this app's own task log -- not
    // for deciding anything the pipeline does.
    public static string StateDir =>
        Environment.GetEnvironmentVariable("AVD_PHOTOS_STATE_DIR") is { Length: > 0 } d ? d
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache", "avd-photos");

    public static string LogDir =>
        Environment.GetEnvironmentVariable("AVD_PHOTOS_LOG_DIR") is { Length: > 0 } d ? d : Path.Combine(StateDir, "logs");

    /// <summary>
    /// Append a line to logs\&lt;mode&gt;.task.log -- the twin of the launchd
    /// agents' *.launchd.log: where the things a script cannot log about itself
    /// land (a missing bash, a crash before its own log is set up). Empty in
    /// normal operation.
    /// </summary>
    public static void TaskLog(string mode, string line)
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            File.AppendAllText(Path.Combine(LogDir, mode + ".task.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line.TrimEnd()}\n", Encoding.UTF8);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
