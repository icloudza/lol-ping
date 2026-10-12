import Foundation
import LPCore

enum AppLanguage: Equatable {
    case english, chinese

    /// The language to show for a preference: the user's pick, or whatever macOS is set to.
    static func resolve(_ choice: LanguageChoice) -> AppLanguage {
        switch choice {
        case .english: return .english
        case .chinese: return .chinese
        case .system: return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh") ? .chinese : .english
        }
    }

    var locale: Locale { Locale(identifier: self == .chinese ? "zh-Hans" : "en") }
}

/// Every piece of text the app shows, in one language. Each entry holds both wordings side by side, so a string
/// can't exist in one language and be forgotten in the other.
struct L10n: Equatable {
    let language: AppLanguage
    static let appName = "LolPing"

    var isChinese: Bool { language == .chinese }
    private func t(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

    // MARK: Settings: sidebar

    var tagline: String { t("Pings for your desktop", "把信号发到桌面上") }
    var paneGesture: String { t("Gesture", "手势") }
    var paneShortcut: String { t("Shortcut", "快捷键") }
    var paneLook: String { t("Look & Sound", "显示与声音") }
    var paneWheel: String { t("Ping Wheel", "信号轮盘") }
    var paneEmotes: String { t("Emotes", "表情") }
    var paneRoom: String { t("Room", "房间") }
    var paneGeneral: String { t("General", "通用") }

    // MARK: Status

    var statusOn: String { t("\(Self.appName) is on", "\(Self.appName) 已开启") }
    var statusPaused: String { t("\(Self.appName) is paused", "\(Self.appName) 已暂停") }
    var statusNeedsAccess: String { t("Accessibility access needed", "需要辅助功能权限") }
    var statusNeedsAccessHint: String { t("Without it \(Self.appName) can't see the mouse or keyboard.", "没有这项权限，\(Self.appName) 读不到鼠标和键盘。") }
    /// `shortcut`: the pause shortcut, when one is set.
    func statusHint(trigger: String, sideButton: Bool, shortcut: String?, on: Bool) -> String {
        if !on {
            return shortcut.map { t("Press \($0) to resume.", "按 \($0) 恢复。") } ?? t("Switch it back on here or from the menu bar.", "在这里或菜单栏里重新开启。")
        }
        let how = sideButton
            ? t("Drag with \(trigger) to bring up the ping wheel.", "按住\(trigger)拖动，呼出信号轮盘。")
            : t("Hold \(trigger) and drag to bring up the ping wheel.", "按住 \(trigger) 拖动鼠标，呼出信号轮盘。")
        return how + (shortcut.map { t(" \($0) pauses.", "按 \($0) 暂停。") } ?? "")
    }

    // MARK: Permissions

    var permissions: String { t("Permissions", "权限") }
    var permissionsHeadline: String { t("Before you start, grant access", "开始之前，先完成授权") }
    var permissionsPromise: String { t("\(Self.appName) only watches for its own keys and drags. Nothing you type is recorded or sent anywhere.", "\(Self.appName) 只识别自己的按键和拖动手势，不记录也不上传你的任何输入。") }
    var permissionsFootnote: String { t("You can change these any time in System Settings", "可随时在系统设置中更改") }
    func permissionsReady(trigger: String, sideButton: Bool) -> String {
        sideButton ? t("All set. Drag with \(trigger) to bring up the ping wheel.", "已就绪。按住\(trigger)拖动，试试呼出信号轮盘。")
            : t("All set. Hold \(trigger) and drag to bring up the ping wheel.", "已就绪。按住 \(trigger) 拖动鼠标，试试呼出信号轮盘。")
    }
    var permAccessibility: String { t("Accessibility", "辅助功能") }
    func permAccessibilityCaption(_ step: AppController.AccessStep, appName: String) -> String {
        switch step {
        case .granted, .ask: return t("Sees the trigger key and the drag that bring up a wheel", "识别触发键和拖动手势，用来呼出轮盘")
        case .switchOn: return t("Switch on “\(appName)” in the list in System Settings. It takes effect at once", "在系统设置的列表里打开「\(appName)」的开关，打开后立即生效")
        case .stale: return t("Listed as allowed, yet not working: usually an entry left by an older copy. Reset it, then allow again", "系统显示已允许，但没有生效，多半是旧版本留下的条目。重置后重新允许即可")
        }
    }
    var permLocalNetwork: String { t("Local network", "本地网络") }
    func permLocalNetworkCaption(unavailable: Bool, appName: String) -> String {
        unavailable ? t("Rooms can't reach your network. Check that “\(appName)” is switched on under Local Network", "房间连不上局域网，检查「本地网络」里是否打开了「\(appName)」")
            : t("Connects directly to room members on your network. macOS asks the first time you join a room", "和同一网络里的房间成员直连。第一次加入房间时 macOS 会询问")
    }
    var requiredBadge: String { t("Required", "必需") }
    var optionalBadge: String { t("Optional", "可选") }
    var allow: String { t("Allow", "允许") }
    var allowed: String { t("Allowed", "已允许") }
    var openSettings: String { t("Open Settings", "打开设置") }
    var resetAccess: String { t("Reset", "重置授权") }
    var later: String { t("Later", "稍后") }
    var getStarted: String { t("Get Started", "开始使用") }
    var done: String { t("Done", "完成") }
    var tryAgain: String { t("Try Again", "重试") }
    var accessCardHint: String { t("\(Self.appName) can't see the mouse or keyboard until it is allowed under Accessibility.", "在「辅助功能」里允许 \(Self.appName) 之后，才能识别按键和拖动。") }
    var viewPermissions: String { t("Review Permissions", "查看权限") }
    var permissionsRowHint: String { t("Accessibility and local network.", "辅助功能、本地网络。") }

    // MARK: Gesture pane

    var pingKey: String { t("Ping key", "信号键") }
    var pingKeyHint: String { t("Hold it and drag with the left mouse button to bring up the ping wheel.", "按住它，再按住鼠标左键拖动，呼出信号轮盘。") }
    var pingButtonHint: String { t("Press this mouse button and drag to bring up the ping wheel.", "按住这个鼠标键直接拖动，呼出信号轮盘。") }
    var keyTriggerNote: String { t("While \(Self.appName) is on, this key no longer reaches other apps.", "\(Self.appName) 开启期间，这个按键不会再传给其他应用。") }
    var dragDistance: String { t("Drag distance", "拖动距离") }
    var dragDistanceHint: String { t("How far the pointer travels before it counts as a drag. Raise it if the wheel opens by accident.", "按下后移动多远才算拖动。误触多的话调大一些。") }
    func clickSendsPing(_ key: String) -> String { t("\(key) + click sends a ping", "\(key) + 单击发送信号") }
    var clickSendsPingHint: String { t("A click without dragging sends the ping in the middle of the wheel. When off, the click goes to the app underneath as usual.", "不拖动、直接单击时，在光标处发送轮盘中心的信号。关闭时，这次单击照常交给下面的应用。") }

    // MARK: Recording keys

    func sideButton(_ number: Int) -> String {
        switch number {
        case 2: return t("Middle button", "鼠标中键")
        case 3: return t("Side button (Back)", "鼠标侧键（后退）")
        case 4: return t("Side button (Forward)", "鼠标侧键（前进）")
        default: return t("Mouse button \(number + 1)", "鼠标按键 \(number + 1)")
        }
    }
    var notSet: String { t("Not set", "未设置") }
    var off: String { t("Off", "已关闭") }
    var pressShortcut: String { t("Press a shortcut…", "请按下快捷键…") }
    var pressTrigger: String { t("Press keys or a mouse button…", "请按下按键或鼠标键…") }
    var keyUnusable: String { t("That key can't be used", "这个键不能用") }
    var keyReserved: String { t("Needs ⌃, ⌥ or ⌘ held with it", "这个键要同时按住 ⌃、⌥ 或 ⌘") }
    var clearKey: String { t("Clear", "清除") }
    var turnOff: String { t("Turn Off", "关闭") }
    var restoreDefault: String { t("Restore Default", "恢复默认") }
    var recorderHelp: String { t("Click, then press the keys. Esc cancels, Delete clears.", "点击后按下按键。Esc 取消，Delete 清除。") }
    var bareKeyNote: String { t("Without ⌃, ⌥ or ⌘, this key stops typing in every app while \(Self.appName) is on.", "没有搭配 ⌃、⌥ 或 ⌘：\(Self.appName) 开启期间，这个键在所有应用里都无法再输入。") }
    func slotName(_ slot: Preferences.KeySlot) -> String {
        switch slot {
        case .pingTrigger: return pingKey
        case .emoteTrigger: return emoteKey
        case .hotkey(.slice(let kind, let index)):
            return t("\(kind == .ping ? "Ping" : "Emote"): \(sliceNames[index])", "\(kind == .ping ? "信号" : "表情") · \(sliceNames[index])")
        case .hotkey(let action): return hotkeyName(action)
        }
    }
    func conflict(_ c: Preferences.KeyConflict) -> String {
        t("Already used by “\(slotName(c.first))”. “\(slotName(c.second))” needs something else.", "已经被「\(slotName(c.first))」占用，「\(slotName(c.second))」得换一个。")
    }

    // MARK: Shortcut pane

    var wheelKeys: String { t("Wheels", "轮盘") }
    var wheelKeysHint: String { t("One modifier or several, any key with or without modifiers, or an extra mouse button.", "可以是一个或多个修饰键、任意按键或组合键，也可以是鼠标侧键、中键。") }
    var actions: String { t("Actions", "常用操作") }
    var sendPings: String { t("Send a ping directly", "直接发送信号") }
    var sendPingsHint: String { t("Sends what is on that slice at the pointer, without opening the wheel. Change what the slices hold under Ping Wheel.", "不打开轮盘，直接在光标处发出这个扇区上的信号。扇区上放什么，在「信号轮盘」里调整。") }
    var sendEmotes: String { t("Send an emote directly", "直接发送表情") }
    var sendEmotesHint: String { t("Sends what is on that slice at the pointer. Change what the slices hold under Emotes.", "直接在光标处发出这个扇区上的表情。扇区上放什么，在「表情」里调整。") }
    func hotkeyName(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleEnabled: return t("Pause / resume", "暂停 / 恢复")
        case .openSettings: return t("Open settings", "打开设置")
        case .toggleMute: return t("Mute / unmute", "静音 / 取消静音")
        case .toggleRoomMute: return t("Mute room", "房间静音")
        case .quick(.ping): return t("Send the quick ping", "发送快捷信号")
        case .quick(.emote): return t("Send the quick emote", "发送快捷表情")
        case .slice(_, let index): return sliceNames[index]
        }
    }
    func hotkeyHint(_ action: HotkeyAction) -> String? {
        switch action {
        case .toggleEnabled: return t("Works everywhere, and still works while paused.", "在任何应用里都能用，暂停期间也靠它恢复。")
        case .openSettings: return t("Brings up this window, also while paused.", "打开这个窗口，暂停期间也能用。")
        case .toggleMute: return t("Silences pings and emotes; they still show.", "关掉信号和表情的声音，画面照常显示。")
        case .toggleRoomMute: return t("Hides or shows what others in the room send.", "隐藏或恢复显示房间里其他人发的内容。")
        case .quick(.ping): return t("Sends the ping in the middle of the wheel at the pointer.", "在光标处发送轮盘中心的信号。")
        case .quick(.emote): return t("Sends the emote in the middle of the wheel at the pointer.", "在光标处发送轮盘中心的表情。")
        case .slice: return nil
        }
    }
    var restoreAllKeys: String { t("Restore All Defaults", "全部恢复默认") }
    var restoreAllKeysTitle: String { t("Default keys", "默认按键") }
    var restoreAllKeysHint: String { t("Puts the wheel keys back to ⌥ and ⌃, pause back to ⌃⌥P, and clears every other shortcut.", "信号键、表情键恢复为 ⌥ 和 ⌃，暂停恢复为 ⌃⌥P，其余快捷键全部清除。") }
    var startsOn: String { t("On at launch", "启动时开启") }
    var startsOnHint: String { t("Ready to ping as soon as \(Self.appName) opens.", "打开 \(Self.appName) 后立即可以发信号。") }

    // MARK: Look & sound pane

    var pingSize: String { t("Ping size", "信号大小") }
    var pingDuration: String { t("Time on screen", "停留时间") }
    var pingDurationHint: String { t("How long a ping stays before it fades.", "信号在屏幕上显示多久后淡出。") }
    var volume: String { t("Volume", "音量") }
    var muted: String { t("Mute", "静音") }
    var wheelTick: String { t("Wheel tick", "轮盘滑动音") }
    var wheelTickHint: String { t("A soft click as the pointer crosses onto another slice.", "光标划到另一个扇区时轻响一声。") }

    // MARK: Wheel editor

    var pingWheelTitle: String { t("Ping wheel", "信号轮盘") }
    func pingWheelHint(_ key: String) -> String { t("Drag a ping onto a slice. Drop one on the middle to make it the \(key) + click ping.", "把右边的信号拖到扇区上。拖到中心，就设为 \(key) + 单击发送的信号。") }
    var allPings: String { t("All pings", "全部信号") }
    var libraryHint: String { t("Click one to see it. You can also click one, then click where it should go.", "单击可以试看。也可以先点选一个，再点要放的位置。") }
    var resetWheel: String { t("Reset", "恢复默认") }
    func pickedHint(_ name: String) -> String { t("“\(name)” picked: click a slice or the middle to place it, Esc to cancel.", "已选中「\(name)」：点一个扇区或中心放下，按 Esc 取消。") }
    var quickCaption: String { t("Click", "单击") }
    var extraBadge: String { t("Extra", "新增") }
    var sliceNames: [String] {
        isChinese ? ["上", "右上", "右", "右下", "下", "左下", "左", "左上"] : ["Top", "Top right", "Right", "Bottom right", "Bottom", "Bottom left", "Left", "Top left"]
    }
    func sliceTooltip(_ slice: Int, _ name: String) -> String { t("\(sliceNames[slice]): \(name)", "\(sliceNames[slice])：\(name)") }
    func quickTooltip(_ key: String, _ name: String) -> String { t("\(key) + click: \(name)", "\(key) + 单击：\(name)") }

    func pingName(_ id: String) -> String {
        switch id {
        case "danger": return t("Danger", "危险")
        case "push": return t("Push", "推进")
        case "omw": return t("On My Way", "正在路上")
        case "allin": return t("All In", "全军出击")
        case "assist": return t("Assist Me", "请求协助")
        case "needvision": return t("Need Vision", "需要视野")
        case "missing": return t("Enemy Missing", "敌人不见了")
        case "enemyvision": return t("Enemy Vision", "敌方视野")
        case "generic": return t("Ping", "信号")
        case "bait": return t("Bait", "诱饵")
        case "visioncleared": return t("Vision Cleared", "视野已清除")
        default: return id
        }
    }

    // MARK: On the wheel itself

    var wheelBack: String { t("BACK", "返回") }
    func wheelIdleLabel(_ kind: WheelKind) -> String { kind == .ping ? t("PING", "信号") : t("EMOTE", "表情") }

    // MARK: Emotes pane

    var emoteKey: String { t("Emote key", "表情键") }
    var emoteKeyHint: String { t("Hold it and drag to bring up the emote wheel. It has to differ from the ping key.", "按住它拖动，呼出表情轮盘。必须和信号键不同。") }
    var emoteOffHint: String { t("The emote wheel is off. Click to give it a key again.", "表情轮盘已关闭。点右边重新设一个键即可开启。") }
    func clickSendsEmote(_ key: String) -> String { t("\(key) + click sends an emote", "\(key) + 单击发送表情") }
    var clickSendsEmoteHint: String { t("A click without dragging sends the emote in the middle of the wheel. When off, the click goes to the app underneath.", "不拖动、直接单击时，发送轮盘中心的表情。关闭时，这次单击照常交给下面的应用。") }
    var emoteSize: String { t("Emote size", "表情大小") }
    var emoteSound: String { t("Emote sounds", "表情音效") }
    var emoteSoundHint: String { t("Plays the sound that comes with an emote, at the volume set under Look & Sound.", "播放表情自带的声音，音量跟随「显示与声音」里的设置。") }
    var emoteWheelTitle: String { t("Emote wheel", "表情轮盘") }
    func emoteWheelHint(_ key: String) -> String { t("Drag an emote onto a slice. Drop one on the middle to make it the \(key) + click emote.", "把右边的表情拖到扇区上。拖到中心，就设为 \(key) + 单击发送的表情。") }
    var allEmotes: String { t("All emotes", "全部表情") }
    var addImage: String { t("Add Image…", "添加图片…") }
    var addImageHint: String { t("PNG, JPG, GIF or WebP; you can also drop files here. An animated one moves on your own screen only.", "支持 PNG、JPG、GIF、WebP，也可以把文件拖到这里。动图只在你自己的屏幕上会动。") }
    func yourImages(_ n: Int, of max: Int) -> String { t("Your images: \(n) of \(max)", "我的图片 \(n)/\(max)") }
    func removeImage(_ name: String) -> String { t("Remove “\(name)”", "移除「\(name)」") }
    func importFailure(_ error: EmoteImportError, file: String) -> String {
        switch error {
        case .notAnImage: return t("“\(file)” isn't a usable image (PNG, JPG, GIF or WebP).", "「\(file)」不是可用的图片（支持 PNG、JPG、GIF、WebP）。")
        case .tooLarge: return t("“\(file)” is too large: at most 8 MB and 8192 pixels on its longer side.", "「\(file)」太大了：不超过 8 MB，最长边不超过 8192 像素。")
        case .animationTooLarge: return t("“\(file)” is too large to keep as an animation: at most 5 MB and 1024 pixels on its longer side.", "「\(file)」作为动图太大：不超过 5 MB，最长边不超过 1024 像素。")
        case .cannotProcess: return t("“\(file)” couldn't be processed.", "「\(file)」处理失败。")
        case .libraryFull: return t("You already have \(ImportedEmote.limit) images. Remove some first.", "最多添加 \(ImportedEmote.limit) 张图片，先移除几张再试。")
        case .alreadyAdded: return t("“\(file)” is already in your images.", "「\(file)」已经添加过了。")
        case .cannotSave: return t("“\(file)” couldn't be saved. Check that the data folder is writable.", "「\(file)」保存失败，请确认数据文件夹可以写入。")
        }
    }

    // MARK: Room pane

    var nickname: String { t("Nickname", "昵称") }
    var nicknameHint: String { t("Shown under your pings. Everyone in the room sees it.", "显示在你发出的信号下面，房间里的人都能看到。") }
    var tagColor: String { t("Tag colour", "名牌颜色") }
    func tagColorName(_ n: Int) -> String { t("Colour \(n)", "颜色 \(n)") }
    var joinTitle: String { t("Ping together", "和朋友一起发信号") }
    var joinHint: String { t("Enter the room code a friend gave you, or start a room and send its code to them.", "输入朋友给你的房间码，或者新建一个房间，把房间码发给他们。") }
    var localNetworkHint: String { t("The first time, macOS asks whether \(Self.appName) may use the local network. Allow it.", "首次使用时，macOS 会询问是否允许 \(Self.appName) 访问本地网络，请选择允许。") }
    var join: String { t("Join", "加入") }
    var newRoom: String { t("New Room", "新建房间") }
    var codeNotFound: String { t("No room code found in that.", "没有找到房间码。") }
    var codeMistyped: String { t("That code looks mistyped. Check it against the original.", "房间码似乎输错了，请再核对一下。") }
    var joinFailed: String { t("Couldn't join. Try again.", "加入失败，请再试一次。") }
    var shareCodeHint: String { t("Send this code to your friends so they can join.", "把房间码发给朋友，他们就能加入。") }
    var joining: String { t("Joining…", "正在加入…") }
    var copy: String { t("Copy", "复制") }
    var copied: String { t("Copied", "已复制") }
    var leave: String { t("Leave", "离开") }
    var you: String { t("you", "你") }
    func pathName(_ path: String) -> String {
        switch path {
        case "lan": return t("Local network", "局域网")
        case "internet": return t("Internet", "互联网")
        case "connecting": return t("Connecting", "连接中")
        default: return t("Unreachable", "连不上")
        }
    }
    var memberPaused: String { t("Paused", "已暂停") }
    var memberMuted: String { t("Muted room", "已静音") }
    var memberNeedsUpdate: String { t("Needs update", "需要更新") }
    var memberNoEmotes: String { t("Older version: can't see emotes", "对方版本较旧，看不到表情") }
    var hideMember: String { t("Hide", "屏蔽") }
    var showMember: String { t("Show", "取消屏蔽") }
    var nobodyYet: String { t("Nobody else is here yet.", "还没有其他人。") }
    var stillAlone: String { t("Still only you. Make sure everyone has the same code.", "等了一会儿仍然只有你，检查一下大家的房间码是否一致。") }
    var internetOffNote: String { t("Internet connections are off, so only people on your network can join.", "互联网连接已关闭，只有同一网络里的人能加入。") }
    var clockSkew: String { t("Someone's clock is more than 10 minutes off, so their pings may not arrive.", "有成员的系统时间相差超过 10 分钟，他的信号可能收不到。") }
    var lanUnavailable: String { t("Local network unavailable", "局域网不可用") }
    var lanUnavailableHint: String { t("The port is in use by another copy, or local network access was not allowed. The internet route still works.", "端口被另一个副本占用，或者没有允许访问本地网络。仍然可以通过互联网连接。") }
    var internetUnavailable: String { t("Can't reach the relays", "连不上中继服务器") }
    var internetUnavailableHint: String { t("Friends on other networks can't be reached right now. People on your own network are unaffected.", "暂时无法连接其他网络的朋友，同一网络内不受影响。") }
    var muteRoom: String { t("Mute room", "房间静音") }
    var muteRoomHint: String { t("Hides everyone else's pings and emotes. Yours are still sent.", "不显示别人的信号和表情，你发的仍然会送出。") }
    var incomingLimit: String { t("Incoming limit", "接收上限") }
    var incomingLimitHint: String { t("The most pings and emotes shown per second from each person.", "每位成员每秒最多显示多少个信号和表情。") }
    func perSecond(_ n: Int) -> String { n == 0 ? t("No limit", "不限") : t("\(n) a second", "\(n) 个/秒") }
    var allowInternet: String { t("Connect over the internet", "允许通过互联网连接") }
    var allowInternetHint: String { t("Friends on other networks join through public relays. Off: your local network only.", "不在同一网络的朋友通过公共中继加入。关闭后仅限局域网。") }
    var rejoin: String { t("Return to the last room at launch", "启动时回到上次的房间") }
    var displays: String { t("Displays", "显示器") }
    var displaysHint: String { t("A ping appears on the other person's display with the same number, or on number 1 when they have fewer.", "信号会出现在对方编号相同的显示器上；对方没有这个编号时落在 1 号。") }
    var mainDisplay: String { t("main", "主显示器") }
    var privacyNote: String { t("Pings, emotes and nicknames are end-to-end encrypted with a key made from the room code. Relays can see your IP address and when you send, never what.", "信号、表情和昵称都用房间码派生的密钥端到端加密。中继服务器能看到你的 IP 地址和发送时间，看不到内容。") }

    // MARK: General pane

    var openAtLogin: String { t("Open at login", "登录时启动") }
    var openAtLoginHint: String { t("Starts quietly in the menu bar.", "登录后自动在菜单栏运行。") }
    var languageTitle: String { t("Language", "语言") }
    func languageName(_ choice: LanguageChoice) -> String {
        switch choice {
        case .system: return t("Same as macOS", "跟随系统")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
    var autoCheck: String { t("Check for updates automatically", "自动检查更新") }
    var autoCheckHint: String { t("Looks at launch and then every hour, and tells you when a new version is out.", "启动时和之后每小时查看一次，有新版本时提醒你。") }
    var autoInstall: String { t("Install updates automatically", "自动下载并安装更新") }
    var autoInstallHint: String { t("Downloads a new version in the background and installs it when \(Self.appName) quits.", "在后台下载新版本，退出 \(Self.appName) 时自动装好。") }
    var about: String { t("About", "关于") }
    func versionLine(_ version: String) -> String { t("Version \(version)", "版本 \(version)") }
    var checkNow: String { t("Check for Updates", "检查更新") }
    var repository: String { t("GitHub repository", "GitHub 仓库") }
    var openRepository: String { t("Open on GitHub", "在 GitHub 上打开") }
    var dataFolder: String { t("Data folder", "数据文件夹") }
    var dataFolderHint: String { t("Preferences and the images you added live here.", "偏好设置和你添加的表情图片都存在这里。") }
    var openDataFolder: String { t("Show in Finder", "在访达中显示") }
    func lastChecked(_ time: String) -> String { t("Last checked \(time)", "上次检查：\(time)") }
    func updateFound(_ version: String) -> String { t("\(Self.appName) \(version) is out", "发现新版本 \(version)") }
    var updateFoundHint: String { t("It is downloaded and installed right here; \(Self.appName) restarts when it is done.", "直接在这里下载并安装，完成后 \(Self.appName) 会自动重新打开。") }
    var viewUpdate: String { t("View and Install", "查看并安装") }
    var attention: String { t("Needs attention", "需要留意") }
    var goodToKnow: String { t("Good to know", "使用须知") }
    func notes(stableSignature: Bool) -> [String] {
        var list = [
            t("The wheel can't open over protected screens such as the login window or a password prompt.", "登录窗口、密码输入框等受保护的界面出现时，无法呼出轮盘。"),
            t("A few full-screen games draw on top of the pings.", "个别全屏游戏会盖住信号。"),
            t("When sharing a single window, viewers don't see the pings. Share the whole screen instead.", "只共享单个窗口时对方看不到信号，请共享整个屏幕。"),
            t("While \(Self.appName) is on, the emote key + drag opens the emote wheel instead of what it normally does. Pick another emote key or turn the emote wheel off if that gets in the way.", "\(Self.appName) 开启时，表情键 + 拖动会用来呼出表情轮盘。如果和你常用的操作冲突，可以换一个表情键，或者关闭表情轮盘。"),
        ]
        if !stableSignature {
            list.append(t("This copy has no fixed signature, so macOS asks for Accessibility access again after each update.", "这个版本没有固定签名，每次更新后都需要重新授予辅助功能权限。"))
        }
        return list
    }
    var prefsUnreadable: String { t("The preferences file couldn't be read. It was kept as preferences.bak.json and the defaults are in use.", "偏好设置文件无法读取，已另存为 preferences.bak.json 并恢复默认设置。") }
    func prefsNotSaved(_ reason: String) -> String { t("Preferences couldn't be saved: \(reason)", "偏好设置保存失败：\(reason)") }
    func missingFile(_ file: String) -> String { t("Missing file: \(file)", "缺少资源文件：\(file)") }
    var emoteKeyTurnedOff: String { t("The saved emote key clashed with another key, so the emote wheel was turned off.", "保存的表情键与其他按键冲突，表情轮盘已被关闭。") }

    // MARK: Main menu

    func menuAbout(_ name: String) -> String { t("About \(name)", "关于 \(name)") }
    func menuHide(_ name: String) -> String { t("Hide \(name)", "隐藏 \(name)") }
    func menuQuitApp(_ name: String) -> String { t("Quit \(name)", "退出 \(name)") }
    var menuEdit: String { t("Edit", "编辑") }
    var menuUndo: String { t("Undo", "撤销") }
    var menuRedo: String { t("Redo", "重做") }
    var menuCut: String { t("Cut", "剪切") }
    var menuCopy: String { t("Copy", "拷贝") }
    var menuPaste: String { t("Paste", "粘贴") }
    var menuSelectAll: String { t("Select All", "全选") }
    var menuWindow: String { t("Window", "窗口") }
    var menuClose: String { t("Close", "关闭") }
    var menuMinimize: String { t("Minimize", "最小化") }

    // MARK: Menu bar

    var menuEnabled: String { t("Enable \(Self.appName)", "启用 \(Self.appName)") }
    var menuRoom: String { t("Room", "房间") }
    var menuJoinFromClipboard: String { t("Join From Clipboard", "从剪贴板加入") }
    var menuNewRoom: String { t("New Room", "新建房间") }
    var menuRoomSettings: String { t("Room Settings", "房间设置") }
    func menuRoomSummary(_ code: String, _ people: Int) -> String { t("\(code) · \(people) here", "\(code) · \(people) 人") }
    var menuCopyCode: String { t("Copy Room Code", "复制房间码") }
    var menuLeaveRoom: String { t("Leave Room", "离开房间") }
    var menuSettings: String { t("Settings", "设置") }
    var menuCheckForUpdates: String { t("Check for Updates", "检查更新") }
    func menuGetUpdate(_ version: String) -> String { t("Install \(Self.appName) \(version)", "安装新版本 \(version)") }
    var menuQuit: String { t("Quit \(Self.appName)", "退出 \(Self.appName)") }
    func menuTooltip(on: Bool, needsAccess: Bool) -> String { needsAccess ? statusNeedsAccess : on ? statusOn : statusPaused }

    // MARK: Notices on screen

    func switchHint(_ shortcut: String?) -> String { shortcut.map { t("\($0) switches it any time", "\($0) 可随时切换") } ?? "" }
    func soundNotice(muted: Bool) -> String { muted ? t("Sound off", "已静音") : t("Sound on", "已取消静音") }
    func roomNotice(muted: Bool) -> String { muted ? t("Room muted", "房间已静音") : t("Room unmuted", "房间已取消静音") }
    var roomNoticeHint: String { t("Others' pings and emotes are hidden", "不再显示别人的信号和表情") }
    var runningInMenuBar: String { t("\(Self.appName) is in the menu bar", "\(Self.appName) 在菜单栏运行") }
    var runningInMenuBarHint: String { t("Click its icon for settings", "点菜单栏里的图标打开设置") }
    func joinedRoom(_ code: String) -> String { t("Joined \(code)", "已加入房间 \(code)") }
    var joinedRoomHint: String { t("Send the code to your friends", "把房间码发给朋友吧") }
    func memberJoined(_ name: String) -> String { t("\(name) joined", "\(name) 加入了房间") }
    func memberLeft(_ name: String) -> String { t("\(name) left", "\(name) 离开了房间") }
    func memberLost(_ name: String) -> String { t("\(name) dropped out", "\(name) 掉线了") }
    var roomFull: String { t("The room is full", "房间已满") }
    var roomFullHint: String { t("A room holds eight people", "一个房间最多 8 人") }
    var noCodeOnClipboard: String { t("No room code on the clipboard", "剪贴板里没有房间码") }
    var noCodeOnClipboardHint: String { t("Copy the code a friend sent you first", "先复制朋友发来的房间码") }
    func updateOut(_ version: String) -> String { t("\(Self.appName) \(version) is out", "\(Self.appName) \(version) 已发布") }
    var updateOutHint: String { t("Install it from the menu bar icon", "点菜单栏图标即可安装") }
}

extension L10n {
    /// "⌥ Option", "⌃⌥", "⌥Z", "Side button (Back)": a trigger as it reads in a sentence.
    func triggerName(_ trigger: Trigger) -> String {
        switch trigger {
        case .modifier(let m): return m.title
        case .sideButton(let n): return sideButton(n)
        case .key(let combo): return combo.title
        }
    }

    /// The same trigger as keycaps.
    func triggerCaps(_ trigger: Trigger) -> [String] { trigger.parts ?? [triggerName(trigger)] }
}
