# dmgbuild 配置：DMG 打开后的窗口样式。由 build.sh 调用：
#   dmgbuild -s Scripts/release/dmg/dmg-settings.py -D app=<LolPing.app> "LolPing" <输出.dmg>
# （dmgbuild 执行本文件时不提供 __file__，路径都由调用方传入。）
import os.path

application = defines["app"]  # noqa: F821  dmgbuild 注入
appname = os.path.basename(application)

# 内容：应用本体 + 指向 /Applications 的快捷方式。
files = [application]
symlinks = {"Applications": "/Applications"}

# 卷图标：挂载后桌面与访达侧边栏显示 LolPing 图标。
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

# LZFSE 压缩：比 zlib 小且解压快。
format = "ULFO"
filesystem = "HFS+"

# 窗口：固定大小，隐藏工具栏、侧边栏、路径栏与状态栏，只留两个图标，左边拖到右边即安装。
window_rect = ((200, 120), (560, 340))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    appname: (150, 150),
    "Applications": (410, 150),
}
