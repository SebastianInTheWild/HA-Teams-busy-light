using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Linq;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using Microsoft.Win32;

namespace TeamsBusyLight
{
    /// <summary>Camera and microphone in use by any app; null = unknown</summary>
    internal sealed class DeviceState
    {
        public bool? Camera;
        public string[] CameraApps = new string[0];
        public string CameraSource = "none";
        public bool? Microphone;
        public string[] MicrophoneApps = new string[0];
        public string MicrophoneSource = "audio system";
    }

    /// <summary>
    /// Camera and microphone in use by any app. No permission needed.
    /// - Microphone: the active recording sessions of the Windows audio system
    ///   (WASAPI), with the process of each session. Works on all Windows
    ///   versions.
    /// - Camera: the sensor activity monitor of Media Foundation (the source of
    ///   the camera privacy indicator, Windows 10 1903 and newer, with the
    ///   process), combined with the registry of the privacy settings
    ///   ("recently used"): older Windows versions record the use per app
    ///   there, an app uses the device while LastUsedTimeStop is 0. After an
    ///   upgrade to a newer Windows version the old registry entries stay (with
    ///   a stop time) and only show the camera off. Without the monitor the
    ///   events of the camera service are the last resort (experimental; they
    ///   do not tell on and off apart for Teams, seen on Windows 11 26H2 with a
    ///   USB camera, 23.11.2026). Without any source the camera is unknown and
    ///   not sent.
    ///   The registry is also the fallback for the microphone.
    /// </summary>
    internal static class DeviceUsage
    {
        public static DeviceState Read()
        {
            var result = new DeviceState();
            var camera = RegistryUsers("webcam");
            var sources = new List<string>();
            var on = camera.Apps.Length > 0;
            result.CameraApps = camera.Apps;
            if (camera.Tracked) sources.Add("registry");
            var monitorApps = CameraUsers();
            if (monitorApps != null)
            {
                sources.Add("sensor activity monitor");
                if (monitorApps.Length > 0)
                {
                    on = true;
                    result.CameraApps = camera.Apps.Concat(monitorApps).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
                }
            }
            else
            {
                var fromEvents = CameraFromEvents();
                if (fromEvents != null)
                {
                    sources.Add("camera service events (experimental)");
                    on = on || fromEvents.Value;
                }
            }
            if (sources.Count > 0)
            {
                result.Camera = on;
                result.CameraSource = string.Join(" + ", sources);
            }

            var apps = MicrophoneUsers();
            if (apps == null)
            {
                var microphone = RegistryUsers("microphone");
                result.MicrophoneSource = microphone.Tracked ? "registry" : "none";
                apps = microphone.Tracked ? microphone.Apps : null;
            }
            result.Microphone = apps == null ? (bool?)null : apps.Length > 0;
            if (apps != null) result.MicrophoneApps = apps;
            return result;
        }

        /// <summary>Process names, sorted, without duplicates</summary>
        static string[] ProcessNames(IEnumerable<int> ids)
        {
            var names = new List<string>();
            foreach (var id in ids)
            {
                try
                {
                    using (var process = Process.GetProcessById(id)) names.Add(process.ProcessName);
                }
                catch (Exception)
                {
                    // The process has ended in the meantime
                }
            }
            return names.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
        }

        // --- Microphone: audio system -------------------------------------------

        // After an error the audio system is asked again only after a while
        // (e.g. not ready yet right after signing in, or restarted)
        const int AudioRetrySeconds = 30;
        static DateTime audioRetryAfter = DateTime.MinValue;
        static bool audioFailed;

        /// <summary>
        /// Names of the processes recording from a microphone right now (e.g.
        /// "Zoom", "msedge"): empty when none, null when the audio system
        /// cannot be asked at the moment
        /// </summary>
        public static string[] MicrophoneUsers()
        {
            if (DateTime.Now < audioRetryAfter) return null;
            try
            {
                var names = ProcessNames(AudioCapture.ActiveProcessIds());
                if (audioFailed) Log.Write("Microphone: audio system available again");
                audioFailed = false;
                return names;
            }
            catch (Exception exception)
            {
                // Logged once per outage, not on every retry
                if (!audioFailed) Log.Write("Microphone: audio system not available: " + exception.Message);
                audioFailed = true;
                audioRetryAfter = DateTime.Now.AddSeconds(AudioRetrySeconds);
                return null;
            }
        }

        // --- Camera: sensor activity monitor ------------------------------------

        static bool? monitorReady;

        /// <summary>
        /// Names of the processes streaming from a camera right now (e.g.
        /// "ms-teams"): empty when none, null when Windows offers no sensor
        /// activity monitor (before Windows 10 1903). The monitor keeps running
        /// once started; it reports the current state right after the start and
        /// then every change.
        /// </summary>
        public static string[] CameraUsers()
        {
            if (monitorReady == null)
            {
                try
                {
                    CameraMonitor.Start();
                    monitorReady = true;
                }
                catch (Exception exception)
                {
                    monitorReady = false;
                    Log.Write("Camera: sensor activity monitor not available: " + exception.Message);
                }
            }
            return monitorReady == true ? ProcessNames(CameraMonitor.StreamingProcessIds()) : null;
        }

        /// <summary>Last report per camera, for the diagnostics</summary>
        public static string CameraMonitorDetails() => monitorReady == true ? CameraMonitor.Details() : "";

        // --- Camera: events of the camera service -------------------------------

        // Camera in use according to the camera service (Frame Server), for
        // Windows versions without the sensor activity monitor. Experimental:
        // the service writes no documented "camera on/off" event, so this relies
        // on its watchdog events (ID 11) in the diagnostic log Camera_FrameServer,
        // which a normal user may read. For the camera device (TimerScope 2) the
        // operation is 2 when a stream starts and 3 when it stops; the newest
        // event per device object counts, the camera is on while any object last
        // started. When the service is not running, the camera is off.
        const string CameraEventLog = "Microsoft-Windows-MF-FrameServer/Camera_FrameServer";
        static bool? cameraEventLogEnabled;

        /// <summary>null when the log is missing, turned off or unreadable</summary>
        public static bool? CameraFromEvents()
        {
            if (cameraEventLogEnabled == null)
            {
                try
                {
                    using (var config = new EventLogConfiguration(CameraEventLog)) cameraEventLogEnabled = config.IsEnabled;
                }
                catch (Exception)
                {
                    cameraEventLogEnabled = false;
                }
            }
            if (cameraEventLogEnabled != true) return null;
            try
            {
                using (var service = new ServiceController("FrameServer"))
                {
                    if (service.Status != ServiceControllerStatus.Running) return false;
                }
            }
            catch (Exception)
            {
                return null;
            }
            try
            {
                var query = new EventLogQuery(CameraEventLog, PathType.LogName, "*[System[EventID=11]]") { ReverseDirection = true };
                using (var reader = new EventLogReader(query))
                {
                    var lastOperation = new Dictionary<string, string>();
                    for (var index = 0; index < 30; index++)
                    {
                        using (var record = reader.ReadEvent())
                        {
                            if (record == null) break;
                            var values = record.Properties;
                            if (values.Count >= 3 && Convert.ToString(values[0].Value) == "2")
                            {
                                var device = Convert.ToString(values[1].Value);
                                if (!lastOperation.ContainsKey(device)) lastOperation[device] = Convert.ToString(values[2].Value);
                            }
                        }
                    }
                    return lastOperation.Values.Contains("2");
                }
            }
            catch (Exception)
            {
                return null;
            }
        }

        // --- Registry of the privacy settings -----------------------------------

        /// <summary>
        /// Apps using a device according to the registry. Tracked is false when
        /// this Windows version does not record the use there (no
        /// LastUsedTimeStart at all).
        /// </summary>
        public static (bool Tracked, string[] Apps) RegistryUsers(string capability)
        {
            var users = new List<string>();
            var tracked = false;
            void Check(RegistryKey key, string name)
            {
                var start = key.GetValue("LastUsedTimeStart");
                var stop = key.GetValue("LastUsedTimeStop");
                if (start != null) tracked = true;
                if (start != null && Convert.ToInt64(start) != 0 && stop != null && Convert.ToInt64(stop) == 0) users.Add(name);
            }
            try
            {
                using (var root = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\" + capability))
                {
                    if (root == null) return (false, new string[0]);
                    foreach (var name in root.GetSubKeyNames())
                    {
                        using (var key = root.OpenSubKey(name))
                        {
                            if (key == null) continue;
                            if (name == "NonPackaged")
                            {
                                // Desktop apps: the path with # instead of \, e.g. C:#Program Files#Zoom#bin#Zoom.exe -> Zoom
                                foreach (var appName in key.GetSubKeyNames())
                                {
                                    using (var appKey = key.OpenSubKey(appName))
                                    {
                                        if (appKey == null) continue;
                                        var file = appName.Split('#').Last();
                                        if (file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) file = file.Substring(0, file.Length - 4);
                                        Check(appKey, file);
                                    }
                                }
                            }
                            else
                            {
                                // Store apps, e.g. MSTeams_8wekyb3d8bbwe
                                Check(key, name.Split('_')[0]);
                            }
                        }
                    }
                }
            }
            catch (Exception)
            {
                // Unreadable: treated like no record
            }
            return (tracked, users.ToArray());
        }
    }

    // --- Audio system (WASAPI) ---------------------------------------------------

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, int flags, out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, int flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name, IntPtr context);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path, IntPtr context);
        [PreserveSig] int GetGroupingParam(out Guid param);
        [PreserveSig] int SetGroupingParam(IntPtr param, IntPtr context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out int pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    static class AudioCapture
    {
        static void Release(object o)
        {
            if (o != null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
        }

        /// <summary>Process IDs of all recording sessions that are active right now, on all microphones</summary>
        public static int[] ActiveProcessIds()
        {
            var result = new List<int>();
            object enumerator = new MMDeviceEnumerator();
            IMMDeviceCollection devices = null;
            try
            {
                Marshal.ThrowExceptionForHR(((IMMDeviceEnumerator)enumerator).EnumAudioEndpoints(1 /* eCapture */, 1 /* DEVICE_STATE_ACTIVE */, out devices));
                devices.GetCount(out var count);
                for (var i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    object manager = null;
                    IAudioSessionEnumerator sessions = null;
                    try
                    {
                        if (devices.Item(i, out device) != 0) continue;
                        var iid = typeof(IAudioSessionManager2).GUID;
                        if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager) != 0) continue;
                        if (((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions) != 0) continue;
                        sessions.GetCount(out var n);
                        for (var j = 0; j < n; j++)
                        {
                            object session = null;
                            try
                            {
                                if (sessions.GetSession(j, out session) != 0) continue;
                                var control = (IAudioSessionControl2)session;
                                // State 1 = active; IsSystemSoundsSession returns 0 (S_OK) for system sounds
                                if (control.GetState(out var state) == 0 && state == 1 &&
                                    control.IsSystemSoundsSession() != 0 &&
                                    control.GetProcessId(out var pid) == 0 && pid != 0 && !result.Contains(pid))
                                {
                                    result.Add(pid);
                                }
                            }
                            finally { Release(session); }
                        }
                    }
                    finally { Release(sessions); Release(manager); Release(device); }
                }
            }
            finally { Release(devices); Release(enumerator); }
            return result.ToArray();
        }
    }

    // --- Sensor activity monitor (Media Foundation) -------------------------------

    [ComImport, Guid("39DC7F4A-B141-4719-813C-A7F46162A2B8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSensorProcessActivity
    {
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int GetStreamingState(out int streaming);
        [PreserveSig] int GetStreamingMode(out int mode);
        [PreserveSig] int GetReportTime(out long time);
    }

    [ComImport, Guid("3E8C4BE1-A8C2-4528-90DE-2851BDE5FEAD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSensorActivityReport
    {
        [PreserveSig] int GetFriendlyName([MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, uint cch, out uint written);
        [PreserveSig] int GetSymbolicLink([MarshalAs(UnmanagedType.LPWStr)] StringBuilder link, uint cch, out uint written);
        [PreserveSig] int GetProcessCount(out uint count);
        [PreserveSig] int GetProcessActivity(uint index, out IMFSensorProcessActivity activity);
    }

    [ComImport, Guid("683F7A5E-4A19-43CD-B1A9-DBF4AB3F7777"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSensorActivitiesReport
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetActivityReport(uint index, out IMFSensorActivityReport report);
        [PreserveSig] int GetActivityReportByDeviceName([MarshalAs(UnmanagedType.LPWStr)] string name, out IMFSensorActivityReport report);
    }

    [ComImport, Guid("DE5072EE-DBE3-46DC-8A87-B6F631194751"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSensorActivitiesReportCallback
    {
        [PreserveSig] int OnActivitiesReport(IMFSensorActivitiesReport report);
    }

    [ComImport, Guid("D0CEF145-B3F4-4340-A2E5-7A5080CA05CB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSensorActivityMonitor
    {
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
    }

    /// <summary>
    /// Camera use as Windows reports it for the privacy indicator: Media
    /// Foundation's sensor activity monitor tells, per camera, which processes
    /// stream from it. The callback runs on a Media Foundation thread.
    /// </summary>
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class CameraMonitor : IMFSensorActivitiesReportCallback
    {
        [DllImport("mfplat.dll")] static extern int MFStartup(int version, int flags);
        [DllImport("mfsensorgroup.dll")] static extern int MFCreateSensorActivityMonitor(IMFSensorActivitiesReportCallback callback, out IMFSensorActivityMonitor monitor);

        static readonly object Lock = new object();
        static CameraMonitor instance;
        static IMFSensorActivityMonitor monitor;
        // Symbolic link of the camera -> IDs of the processes streaming from it
        static readonly Dictionary<string, int[]> streaming = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
        // Last report per camera for the diagnostics: name, link, pid:streaming:mode
        static readonly Dictionary<string, string> details = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public static string Details()
        {
            lock (Lock) return string.Join(Environment.NewLine, details.Values);
        }

        public static void Start()
        {
            lock (Lock)
            {
                if (monitor != null) return;
                Marshal.ThrowExceptionForHR(MFStartup(0x20070 /* MF_VERSION */, 0));
                instance = new CameraMonitor();
                Marshal.ThrowExceptionForHR(MFCreateSensorActivityMonitor(instance, out var created));
                Marshal.ThrowExceptionForHR(created.Start());
                monitor = created;
            }
        }

        /// <summary>IDs of all processes streaming from any camera right now</summary>
        public static int[] StreamingProcessIds()
        {
            lock (Lock) return streaming.Values.SelectMany(ids => ids).Distinct().ToArray();
        }

        public int OnActivitiesReport(IMFSensorActivitiesReport report)
        {
            try
            {
                if (report.GetCount(out var count) != 0) return 0;
                var update = new Dictionary<string, int[]>();
                var text = new Dictionary<string, string>();
                for (uint i = 0; i < count; i++)
                {
                    if (report.GetActivityReport(i, out var device) != 0 || device == null) continue;
                    try
                    {
                        var link = new StringBuilder(1024);
                        var name = new StringBuilder(256);
                        if (device.GetSymbolicLink(link, (uint)link.Capacity, out _) != 0) continue;
                        device.GetFriendlyName(name, (uint)name.Capacity, out _);
                        if (device.GetProcessCount(out var processes) != 0) continue;
                        var ids = new List<int>();
                        var line = new StringBuilder();
                        line.Append(name).Append(" [").Append(link).Append("]:");
                        for (uint j = 0; j < processes; j++)
                        {
                            if (device.GetProcessActivity(j, out var activity) != 0 || activity == null) continue;
                            try
                            {
                                activity.GetProcessId(out var pid);
                                activity.GetStreamingState(out var state);
                                var mode = -1;
                                activity.GetStreamingMode(out mode);
                                line.Append(' ').Append(pid).Append(':').Append(state != 0 ? "streaming" : "idle").Append(':').Append(mode == 0 ? "controller" : "shared");
                                if (state != 0 && pid != 0) ids.Add((int)pid);
                            }
                            finally { Marshal.ReleaseComObject(activity); }
                        }
                        update[link.ToString()] = ids.ToArray();
                        text[link.ToString()] = line.ToString();
                    }
                    finally { Marshal.ReleaseComObject(device); }
                }
                lock (Lock)
                {
                    foreach (var pair in update) streaming[pair.Key] = pair.Value;
                    foreach (var pair in text) details[pair.Key] = pair.Value;
                }
            }
            catch (Exception)
            {
                // A report that cannot be read is skipped; the next one counts
            }
            return 0;
        }
    }
}
