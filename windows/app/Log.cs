using System;
using System.IO;
using System.Text;

namespace TeamsBusyLight
{
    /// <summary>Log file in the data folder; one older log of about 1 MB is kept</summary>
    internal static class Log
    {
        static readonly object Lock = new object();
        static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

        public static void Write(string message)
        {
            lock (Lock)
            {
                try
                {
                    AppPaths.EnsureDataDir();
                    var file = new FileInfo(AppPaths.LogPath);
                    if (file.Exists && file.Length > 1024 * 1024)
                    {
                        var old = AppPaths.LogPath + ".old";
                        File.Delete(old);
                        File.Move(AppPaths.LogPath, old);
                    }
                    var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine;
                    File.AppendAllText(AppPaths.LogPath, line, Utf8NoBom);
                }
                catch (Exception)
                {
                    // The log must never stop the app
                }
            }
        }
    }
}
