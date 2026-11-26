using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace TeamsBusyLight
{
    /// <summary>
    /// "Send only in these networks": Teams Busy Light sends only while the PC
    /// has an address in one of the networks (CIDR, e.g. 192.168.1.0/24), so it
    /// does not send through an externally reachable webhook URL while on the
    /// road. Empty = everywhere.
    /// </summary>
    internal static class HomeNetwork
    {
        internal struct Network
        {
            public byte[] Bytes;
            public int Prefix;
        }

        /// <summary>Splits the entered list (commas, semicolons or spaces)</summary>
        public static string[] Split(string text) =>
            (text ?? "").Split(new[] { ',', ';', ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);

        /// <summary>The network of an entry, or null if it is not valid</summary>
        public static Network? Parse(string text)
        {
            var parts = text.Split('/');
            if (parts.Length > 2) return null;
            if (!IPAddress.TryParse(parts[0], out var address)) return null;
            // IPAddress also accepts shortened forms like "10.1"
            if (address.AddressFamily == AddressFamily.InterNetwork && parts[0].Split('.').Length != 4) return null;
            var bytes = address.GetAddressBytes();
            var prefix = bytes.Length * 8;
            if (parts.Length == 2)
            {
                if (!int.TryParse(parts[1], out var value) || value < 0 || value > prefix) return null;
                prefix = value;
            }
            return new Network { Bytes = bytes, Prefix = prefix };
        }

        /// <summary>The first invalid entry of the list, null if all are valid</summary>
        public static string FindInvalid(string text) => Split(text).FirstOrDefault(entry => Parse(entry) == null);

        public static bool Contains(Network network, byte[] address)
        {
            if (address.Length != network.Bytes.Length) return false;
            var bits = network.Prefix;
            for (var index = 0; index < address.Length && bits > 0; index++, bits -= 8)
            {
                var mask = bits >= 8 ? 255 : (255 << (8 - bits)) & 255;
                if ((address[index] & mask) != (network.Bytes[index] & mask)) return false;
            }
            return true;
        }

        static IEnumerable<NetworkInterface> ActiveInterfaces() =>
            NetworkInterface.GetAllNetworkInterfaces().Where(item =>
                item.OperationalStatus == OperationalStatus.Up && item.NetworkInterfaceType != NetworkInterfaceType.Loopback);

        static List<Network> ParseAll(string text) =>
            Split(text).Select(Parse).Where(network => network != null).Select(network => network.Value).ToList();

        /// <summary>True when no networks are set or an active interface has an address in one of them</summary>
        public static bool IsHome(string text)
        {
            var networks = ParseAll(text);
            if (networks.Count == 0) return true;
            foreach (var item in ActiveInterfaces())
            {
                foreach (var unicast in item.GetIPProperties().UnicastAddresses)
                {
                    var bytes = unicast.Address.GetAddressBytes();
                    if (networks.Any(network => Contains(network, bytes))) return true;
                }
            }
            return false;
        }

        /// <summary>
        /// IPv4 networks of the active interfaces with a gateway (no VPN
        /// tunnels), e.g. "192.168.1.0/24", for "Add current network"
        /// </summary>
        public static string[] Current()
        {
            var result = new List<string>();
            foreach (var item in ActiveInterfaces())
            {
                if (item.NetworkInterfaceType == NetworkInterfaceType.Tunnel || item.NetworkInterfaceType == NetworkInterfaceType.Ppp) continue;
                var properties = item.GetIPProperties();
                if (!properties.GatewayAddresses.Any(gateway => !gateway.Address.Equals(IPAddress.Any))) continue;
                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var network = NetworkOf(unicast.Address.GetAddressBytes(), unicast.PrefixLength);
                    if (network != null && !result.Contains(network)) result.Add(network);
                }
            }
            return result.ToArray();
        }

        /// <summary>"a.b.c.0/prefix" of an IPv4 address, null for link-local addresses</summary>
        public static string NetworkOf(byte[] bytes, int prefix)
        {
            if (bytes[0] == 169 && bytes[1] == 254) return null;
            var masked = (byte[])bytes.Clone();
            var bits = prefix;
            for (var index = 0; index < 4; index++, bits -= 8)
            {
                var mask = bits >= 8 ? 255 : bits <= 0 ? 0 : (255 << (8 - bits)) & 255;
                masked[index] = (byte)(masked[index] & mask);
            }
            return new IPAddress(masked) + "/" + prefix;
        }

        /// <summary>
        /// Current networks that are neither covered by the home networks nor
        /// ignored; only while home networks are set (otherwise everything is
        /// sent)
        /// </summary>
        public static string[] New(string homeNetworks, string ignoredNetworks) => New(homeNetworks, ignoredNetworks, Current());

        public static string[] New(string homeNetworks, string ignoredNetworks, string[] current)
        {
            var networks = ParseAll(homeNetworks);
            if (networks.Count == 0) return new string[0];
            var ignored = Split(ignoredNetworks);
            return current.Where(entry =>
            {
                var bytes = Parse(entry)?.Bytes;
                return bytes != null && !ignored.Contains(entry) && !networks.Any(network => Contains(network, bytes));
            }).ToArray();
        }

        /// <summary>Appends networks to a list, without duplicates</summary>
        public static string Add(string text, IEnumerable<string> networks)
        {
            var entries = new List<string>();
            foreach (var entry in Split(text).Concat(networks))
            {
                if (!string.IsNullOrEmpty(entry) && !entries.Contains(entry)) entries.Add(entry);
            }
            return string.Join(", ", entries);
        }
    }
}
