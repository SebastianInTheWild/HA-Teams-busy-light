using System;
using System.IO;
using System.Threading;

namespace TeamsBusyLight
{
    /// <summary>
    /// Retries a file action: a file of an instance that just exited, or the
    /// hosts file, may still be locked for a moment
    /// </summary>
    internal static class FileRetry
    {
        public static void Run(Action action) => Run(() => { action(); return true; });

        public static T Run<T>(Func<T> action, int attempts = 20, int delayMs = 500)
        {
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    return action();
                }
                catch (Exception exception) when ((exception is IOException || exception is UnauthorizedAccessException) && attempt < attempts)
                {
                    Thread.Sleep(delayMs);
                }
            }
        }
    }
}
