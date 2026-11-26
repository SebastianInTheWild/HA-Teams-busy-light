using System;
using System.IO;
using System.Linq;
using System.Text;
using Xunit;

namespace TeamsBusyLight.Tests
{
    /// <summary>Reading the end of the Teams log (TeamsMonitor.ReadTail)</summary>
    public sealed class LogTailTests : IDisposable
    {
        readonly string path = Path.Combine(Path.GetTempPath(), "TeamsBusyLight-Test-" + Guid.NewGuid().ToString("N") + ".log");

        public void Dispose() => File.Delete(path);

        [Fact]
        public void SmallLogIsReadCompletely()
        {
            File.WriteAllText(path, "first\r\nsecond\r\nthird ä\r\n", new UTF8Encoding(true));
            Assert.Equal(new[] { "first", "second", "third ä" }, TeamsMonitor.ReadTail(path));
        }

        [Fact]
        public void LongLogGivesTheLast1000Lines()
        {
            // About 3 MB, many blocks of 64 KB
            var lines = Enumerable.Range(1, 30000).Select(i => $"line {i} " + new string('x', 90)).ToArray();
            File.WriteAllText(path, string.Join("\n", lines) + "\n");
            var tail = TeamsMonitor.ReadTail(path);
            Assert.Equal(1000, tail.Count);
            Assert.Equal(lines.Skip(29000), tail);
        }

        [Fact]
        public void LinesLongerThanTheLimitDropTheCutLine()
        {
            // Over 4 MB in a few lines: only the end is read, the cut first line is dropped
            var lines = Enumerable.Range(1, 5).Select(i => $"line {i} " + new string('x', 1024 * 1024)).ToArray();
            File.WriteAllText(path, string.Join("\r\n", lines));
            var tail = TeamsMonitor.ReadTail(path);
            Assert.Equal(lines.Skip(2), tail);
        }

        [Fact]
        public void MissingLogGivesNoLines()
        {
            Assert.Empty(TeamsMonitor.ReadTail(path));
        }
    }
}
