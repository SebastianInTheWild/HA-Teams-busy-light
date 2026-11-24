using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace TeamsBusyLight
{
    /// <summary>Shared pieces of the windows: icon, fonts, message boxes</summary>
    internal static class Ui
    {
        static Icon appIcon;

        /// <summary>The app icon (embedded, uncompressed images up to 64 pixels)</summary>
        public static Icon AppIcon
        {
            get
            {
                if (appIcon == null)
                {
                    using (var stream = typeof(Ui).Assembly.GetManifestResourceStream("app-icon.ico")) appIcon = new Icon(stream);
                }
                return appIcon;
            }
        }

        /// <summary>The brand image in the given size</summary>
        public static Bitmap BrandImage(int size)
        {
            using (var icon = new Icon(AppIcon, 64, 64))
            using (var source = icon.ToBitmap())
            {
                var bitmap = new Bitmap(size, size);
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.DrawImage(source, 0, 0, size, size);
                }
                return bitmap;
            }
        }

        public static Font NewFont(float size = 9, bool bold = false) =>
            new Font(bold ? "Segoe UI Semibold" : "Segoe UI", size);

        /// <summary>
        /// Message box in front of other windows: an invisible topmost owner
        /// window, because a tray app has no window of its own.
        /// (MessageBoxOptions.DefaultDesktopOnly must not be used: in a tray app
        /// the box returned "No" at once without being shown.)
        /// </summary>
        public static DialogResult Message(string text, MessageBoxButtons buttons = MessageBoxButtons.OK,
            MessageBoxIcon icon = MessageBoxIcon.Information, string caption = AppPaths.AppName)
        {
            using (var owner = new Form
            {
                FormBorderStyle = FormBorderStyle.None,
                ShowInTaskbar = false,
                StartPosition = FormStartPosition.Manual,
                Location = new Point(-32000, -32000),
                Size = new Size(1, 1),
                TopMost = true,
            })
            {
                owner.Show();
                owner.Activate();
                return MessageBox.Show(owner, text, caption, buttons, icon);
            }
        }
    }
}
