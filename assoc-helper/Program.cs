// Sylphplay 默认打开方式助手 — Ruanftrix
// 仅在被主进程按需调用时运行，负责把 Sylphplay 关联为媒体的默认打开程序。
// 只写 HKCU（当前用户），无需管理员权限，绝不拉起应用本身。
// 用法：assoc-helper.exe "<可执行文件绝对路径>"
using System;
using System.IO;
using Microsoft.Win32;

internal static class Program
{
    private static readonly string[][] EXT_GROUPS =
    {
        new[] { "jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "jpg2", "j2k", "jpf", "ico", "jfif" },          // 图片
        new[] { "mp4", "webm", "mkv", "mov", "m4v", "ogv", "avi", "mpg", "mpeg", "3gp", "3g2", "ts", "m2ts" },      // 视频
        new[] { "mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac", "wma", "weba", "amr", "mid", "midi" }     // 音频
    };

    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("缺少可执行文件路径");
            return 2;
        }
        var exe = Path.GetFullPath(args[0]);
        if (!File.Exists(exe))
        {
            Console.Error.WriteLine("可执行文件不存在: " + exe);
            return 2;
        }
        var exeName = Path.GetFileName(exe); // 例如 Sylphplay.exe

        // 「打开方式」命令：%1 只替换第一个文件，必须显式列出 %1..%10 才能接收多选。
        // 未选满时产生的多余 %n 令牌非真实文件，主进程 mediaFromArgv 会按 fs.existsSync 过滤掉。
        var openCmd = "\"" + exe + "\" \"%1\" \"%2\" \"%3\" \"%4\" \"%5\" \"%6\" \"%7\" \"%8\" \"%9\" \"%10\"";

        // 让 Sylphplay 出现在「打开方式」建议列表里
        string AppsKey(string part) => @"Software\Classes\Applications\" + exeName + @"\shell\open\" + part;
        Set(Registry.CurrentUser, AppsKey("command"), "", openCmd);
        Set(Registry.CurrentUser, AppsKey("FriendlyAppName"), "", "Sylphplay");

        // 统一 ProgId：让全部媒体类型共享同一个关联组，
        // 资源管理器才会把「混类型多选 + 回车」整体传给同一个命令（否则只进首个文件）。
        const string SHARED = "Sylphplay";
        // 右键菜单「加入到 Sylphplay 播放队列」：自定义动词在资源管理器里多选时会把
        // 所有文件（含混类型）一起传给命令，天然绕开 UserChoice 影响，且只追加不替换。
        const string VERB = "SYPlayQueue";
        const string VERB_LABEL = "加入到 Sylphplay 播放队列";
        void WriteVerb(string progId)
        {
            string verbBase = @"Software\Classes\" + progId + @"\shell\" + VERB;
            Set(Registry.CurrentUser, verbBase, "", VERB_LABEL);                      // 右键菜单显示文字
            Set(Registry.CurrentUser, verbBase, "Icon", exe + ",0");
            Set(Registry.CurrentUser, verbBase + @"\command", "", openCmd);
        }

        void WriteShared()
        {
            Set(Registry.CurrentUser, @"Software\Classes\" + SHARED, "", "Sylphplay");                      // ProgId 名称
            Set(Registry.CurrentUser, @"Software\Classes\" + SHARED + @"\DefaultIcon", "", exe + ",0");
            Set(Registry.CurrentUser, @"Software\Classes\" + SHARED + @"\shell\open\command", "", openCmd);
            Set(Registry.CurrentUser, @"Software\Classes\" + SHARED + @"\shell\open\FriendlyAppName", "", "Sylphplay");
            WriteVerb(SHARED);
        }

        int count = 0;
        foreach (var group in EXT_GROUPS)
        {
            foreach (var ext in group)
            {
                // .ext 的默认：优先指向共享 ProgId；同时保留「Sylphplay.ext」别名，
                // 让用户已通过「打开方式→始终」设好的旧 UserChoice 仍能解析、不会失效。
                Set(Registry.CurrentUser, @"Software\Classes\." + ext, "", SHARED);

                var alias = "Sylphplay." + ext;
                Set(Registry.CurrentUser, @"Software\Classes\" + alias, "", "Sylphplay");
                Set(Registry.CurrentUser, @"Software\Classes\" + alias + @"\DefaultIcon", "", exe + ",0");
                Set(Registry.CurrentUser, @"Software\Classes\" + alias + @"\shell\open\command", "", openCmd);
                Set(Registry.CurrentUser, @"Software\Classes\" + alias + @"\shell\open\FriendlyAppName", "", "Sylphplay");
                WriteVerb(alias);
                count++;
            }
        }
        WriteShared();

        Console.WriteLine("已将 " + count + " 种扩展名关联到 " + exe);
        return 0;
    }

    private static void Set(RegistryKey root, string subKey, string name, string value)
    {
        using var key = root.CreateSubKey(subKey, true);
        key?.SetValue(name, value, RegistryValueKind.String);
    }
}