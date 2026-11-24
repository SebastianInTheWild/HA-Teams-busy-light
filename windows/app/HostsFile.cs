using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace TeamsBusyLight
{
    /// <summary>
    /// Entries of Teams Busy Light in the Windows hosts file, e.g. when Home
    /// Assistant cannot be resolved while a company VPN is connected. Changing
    /// the file needs administrator rights: the installer and uninstaller start
    /// this executable with "--admin-hosts add|remove &lt;host&gt;" and a UAC prompt.
    /// </summary>
    internal static class HostsFile
    {
        const string Tag = "# Teams Busy Light";
        static readonly string HostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts");

        /// <summary>--admin-hosts add|remove host...: runs elevated and reports the result</summary>
        public static int Run(string[] arguments)
        {
            var report = new List<string>();
            var failed = false;
            var mode = arguments.FirstOrDefault();
            var hosts = arguments.Skip(1).Where(host => Uri.CheckHostName(host) != UriHostNameType.Unknown).ToArray();
            if (mode == "add")
            {
                foreach (var host in hosts)
                {
                    try
                    {
                        var address = ResolveOnLan(host);
                        if (address == null)
                        {
                            report.Add(Strings.Format("DnsFailed", host));
                            failed = true;
                            continue;
                        }
                        var desired = $"{address}\t{host}\t{Tag}";
                        var names = new[] { host.ToLowerInvariant() };
                        var replaced = false;
                        Update(lines =>
                        {
                            var result = new List<string>();
                            foreach (var line in lines)
                            {
                                if (MapsHost(line, names))
                                {
                                    if (!replaced) result.Add(desired);
                                    replaced = true;
                                    continue;
                                }
                                result.Add(line);
                            }
                            if (!replaced) result.Add(desired);
                            return result;
                        });
                        report.Add(Strings.Format(replaced ? "HostsUpdated" : "HostsAdded", address, host));
                    }
                    catch (Exception exception)
                    {
                        report.Add(Strings.Format("HostsFailed", host, exception.Message));
                        failed = true;
                    }
                }
            }
            else if (mode == "remove" && hosts.Length > 0)
            {
                try
                {
                    var names = hosts.Select(host => host.ToLowerInvariant()).ToArray();
                    if (Update(lines => lines.Where(line => !(line.TrimEnd().EndsWith(Tag) && MapsHost(line, names))).ToList()))
                        report.Add(Strings.Get("HostsRemoved"));
                }
                catch (Exception exception)
                {
                    report.Add(Strings.Format("HostsFailed", string.Join(", ", hosts), exception.Message));
                    failed = true;
                }
            }
            if (report.Count > 0)
                Ui.Message(string.Join("\n\n", report), icon: failed ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
            return failed ? 1 : 0;
        }

        /// <summary>True if the hosts file has an entry of Teams Busy Light for the host</summary>
        public static bool HasEntry(string host)
        {
            try
            {
                var names = new[] { host.ToLowerInvariant() };
                return File.ReadAllLines(HostsPath, Encoding.Default).Any(line => line.TrimEnd().EndsWith(Tag) && MapsHost(line, names));
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>True if the line maps one of the hosts (comments are ignored)</summary>
        public static bool MapsHost(string line, string[] names)
        {
            var tokens = line.Split(new[] { '#' }, 2)[0].Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            return tokens.Length >= 2 && tokens.Skip(1).Any(name => names.Contains(name.ToLowerInvariant()));
        }

        /// <summary>
        /// Rewrites the hosts file with the lines returned by transform. The
        /// file is opened once and exclusively, so it is never left truncated:
        /// if it is in use, nothing changes; if writing fails, the original
        /// content is written back. Returns true if the content changed.
        /// </summary>
        static bool Update(Func<List<string>, List<string>> transform)
        {
            var encoding = Encoding.Default;
            FileStream stream = null;
            for (var attempt = 1; stream == null; attempt++)
            {
                try
                {
                    stream = new FileStream(HostsPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                }
                catch (IOException) when (attempt < 20)
                {
                    Thread.Sleep(500);
                }
            }
            using (stream)
            {
                var original = new byte[stream.Length];
                var read = 0;
                while (read < original.Length)
                {
                    var count = stream.Read(original, read, original.Length - read);
                    if (count <= 0) break;
                    read += count;
                }
                var text = encoding.GetString(original);
                var lines = text.Split('\n').Select(line => line.TrimEnd('\r')).ToList();
                if (lines.Count > 0 && lines[lines.Count - 1].Length == 0) lines.RemoveAt(lines.Count - 1);
                var newText = string.Join("\r\n", transform(lines)) + "\r\n";
                if (newText == text) return false;
                var bytes = encoding.GetBytes(newText);
                try
                {
                    stream.SetLength(0);
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush();
                }
                catch (Exception)
                {
                    stream.SetLength(0);
                    stream.Write(original, 0, original.Length);
                    stream.Flush();
                    throw;
                }
                return true;
            }
        }

        // --- DNS through the LAN -------------------------------------------------

        /// <summary>
        /// IPv4 address of the host from the DNS servers of the active LAN and
        /// Wi-Fi adapters (not those of a VPN, which may not know Home Assistant)
        /// </summary>
        static IPAddress ResolveOnLan(string host)
        {
            var servers = NetworkInterface.GetAllNetworkInterfaces()
                .Where(item => item.OperationalStatus == OperationalStatus.Up && IsLanAdapter(item))
                .SelectMany(item => item.GetIPProperties().DnsAddresses)
                .Where(server => server.AddressFamily == AddressFamily.InterNetwork && server.GetAddressBytes()[0] != 127)
                .Distinct();
            foreach (var server in servers)
            {
                try
                {
                    var address = QueryA(host, server);
                    if (address != null) return address;
                }
                catch (Exception)
                {
                    // Next server
                }
            }
            return null;
        }

        static bool IsLanAdapter(NetworkInterface item)
        {
            var wired = item.NetworkInterfaceType == NetworkInterfaceType.Ethernet || item.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet ||
                        item.NetworkInterfaceType == NetworkInterfaceType.FastEthernetT || item.NetworkInterfaceType == NetworkInterfaceType.FastEthernetFx;
            if (!wired && item.NetworkInterfaceType != NetworkInterfaceType.Wireless80211) return false;
            // Virtual adapters (Hyper-V, VPN clients) report themselves as Ethernet
            var description = item.Description ?? "";
            return new[] { "Virtual", "VPN", "TAP-", "Hyper-V", "Tunnel", "WireGuard" }
                .All(word => description.IndexOf(word, StringComparison.OrdinalIgnoreCase) < 0);
        }

        /// <summary>A plain DNS query for the A record of a name at one server (UDP)</summary>
        public static IPAddress QueryA(string host, IPAddress server)
        {
            var id = (ushort)new Random().Next(0, 65536);
            var query = BuildQuery(id, host);
            using (var udp = new UdpClient(server.AddressFamily))
            {
                udp.Client.ReceiveTimeout = 2000;
                udp.Connect(server, 53);
                udp.Send(query, query.Length);
                var remote = new IPEndPoint(IPAddress.Any, 0);
                return ParseAnswer(udp.Receive(ref remote), id);
            }
        }

        public static byte[] BuildQuery(ushort id, string host)
        {
            var packet = new List<byte> { (byte)(id >> 8), (byte)id, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0 };
            foreach (var label in host.TrimEnd('.').Split('.'))
            {
                var bytes = Encoding.ASCII.GetBytes(label);
                if (bytes.Length == 0 || bytes.Length > 63) throw new ArgumentException("invalid host name");
                packet.Add((byte)bytes.Length);
                packet.AddRange(bytes);
            }
            packet.AddRange(new byte[] { 0, 0, 1, 0, 1 });
            return packet.ToArray();
        }

        public static IPAddress ParseAnswer(byte[] answer, ushort id)
        {
            if (answer.Length < 12 || answer[0] != (byte)(id >> 8) || answer[1] != (byte)id) return null;
            if ((answer[3] & 0x0F) != 0) return null;
            var questions = (answer[4] << 8) | answer[5];
            var answers = (answer[6] << 8) | answer[7];
            var offset = 12;
            for (var i = 0; i < questions; i++) offset = SkipName(answer, offset) + 4;
            for (var i = 0; i < answers && offset + 10 <= answer.Length; i++)
            {
                offset = SkipName(answer, offset);
                var type = (answer[offset] << 8) | answer[offset + 1];
                var length = (answer[offset + 8] << 8) | answer[offset + 9];
                offset += 10;
                if (offset + length > answer.Length) return null;
                if (type == 1 && length == 4) return new IPAddress(new[] { answer[offset], answer[offset + 1], answer[offset + 2], answer[offset + 3] });
                offset += length;
            }
            return null;
        }

        static int SkipName(byte[] packet, int offset)
        {
            while (offset < packet.Length)
            {
                var length = packet[offset];
                if (length == 0) return offset + 1;
                // Compressed: a pointer of two bytes ends the name
                if ((length & 0xC0) == 0xC0) return offset + 2;
                offset += length + 1;
            }
            return offset;
        }
    }
}
