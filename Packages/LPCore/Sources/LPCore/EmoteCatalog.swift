// The bundled emotes. The slugs name the files in Resources/emotes and are what a room message carries.
// Regenerate with Scripts/import-assets.sh when the asset set changes.
import Foundation

public struct Emote: Identifiable, Hashable, Sendable {
    public let slug: String
    public let name: String
    public let zhName: String
    public let hasSound: Bool

    public var id: String { slug }

    public func displayName(chinese: Bool) -> String { chinese ? zhName : name }
}

public enum EmoteCatalog {
    public static let all: [Emote] = [
        Emote(slug: "facepalm", name: "Facepalm", zhName: "捂脸", hasSound: true),
        Emote(slug: "unworthy", name: "Unworthy", zhName: "弱爆", hasSound: true),
        Emote(slug: "unworthy_cn", name: "Unworthy (Chinese text)", zhName: "弱爆（文字版）", hasSound: true),
        Emote(slug: "poro_snax", name: "Poro Snax", zhName: "魄罗佳肴", hasSound: true),
        Emote(slug: "sad_kitten", name: "Sad Kitten", zhName: "悲伤猫咪", hasSound: true),
        Emote(slug: "cheeky_poro", name: "Cheeky Poro", zhName: "调皮魄罗", hasSound: true),
        Emote(slug: "angry_kitty", name: "Angry Kitty", zhName: "我生气了！", hasSound: true),
        Emote(slug: "gg_heart", name: "GG <3", zhName: "精彩的对局 <3", hasSound: true),
        Emote(slug: "bee_happy", name: "Bee Happy", zhName: "小蜜蜂 高兴", hasSound: true),
        Emote(slug: "bee_mad", name: "Bee Mad", zhName: "小蜜蜂 疯狂", hasSound: true),
        Emote(slug: "bee_sad", name: "Bee Sad", zhName: "小蜜蜂 悲伤", hasSound: true),
        Emote(slug: "snoozy_poro", name: "Snoozy Poro", zhName: "打盹魄罗", hasSound: true),
        Emote(slug: "wahaha", name: "Wahaha", zhName: "笑哭我了", hasSound: true),
        Emote(slug: "omg_love_it", name: "OMG I love it", zhName: "我的天，爱死它了", hasSound: true),
        Emote(slug: "poro_ride", name: "Poro Ride", zhName: "溜了溜了", hasSound: true),
        Emote(slug: "dont_make_me_laugh", name: "Don't Make Me Laugh", zhName: "xswl", hasSound: true),
        Emote(slug: "woah_dizzy", name: "Woah…Dizzy", zhName: "晕晕", hasSound: true),
        Emote(slug: "haha_hilarious", name: "Haha HILARIOUS", zhName: "哈哈笑死", hasSound: true),
        Emote(slug: "gasp", name: "Gasp!", zhName: "倒吸一口凉气！", hasSound: true),
        Emote(slug: "super_approved", name: "Super-Approved", zhName: "超赞的", hasSound: true),
        Emote(slug: "pain", name: "PaiN…", zhName: "强颜欢笑", hasSound: true),
        Emote(slug: "laughing_out_loud", name: "Laughing Out LOUD", zhName: "哈哈哈", hasSound: true),
        Emote(slug: "hats_off", name: "Hat's Off", zhName: "脱帽致意", hasSound: true),
        Emote(slug: "call_me", name: "Call Me!", zhName: "双击666！", hasSound: true),
        Emote(slug: "think_about_it", name: "Think About It", zhName: "脑子是个好东西", hasSound: true),
        Emote(slug: "unimpressed", name: "Animated Unimpressed!", zhName: "凡人！动态表情", hasSound: true),
        Emote(slug: "did_you_just", name: "Animated Did You Just?", zhName: "动态 我太难了！", hasSound: true),
        Emote(slug: "nice_try", name: "Nice Try", zhName: "棒棒哒", hasSound: true),
        Emote(slug: "nice", name: "Nice", zhName: "干得漂亮", hasSound: true),
        Emote(slug: "despair", name: "Despair", zhName: "呜呜呜---", hasSound: true),
        Emote(slug: "does_not_compute", name: "Does Not Compute", zhName: "无法求解", hasSound: true),
        Emote(slug: "come_at_me", name: "Come at Me", zhName: "放马过来", hasSound: true),
        Emote(slug: "how_could_you", name: "How Could You", zhName: "你怎能这样", hasSound: true),
        Emote(slug: "scout_approved", name: "Scout-Approved", zhName: "提莫说很好", hasSound: true),
        Emote(slug: "maybe_next_time", name: "Maybe Next Time", zhName: "也许下次", hasSound: true),
        Emote(slug: "okay", name: "Okay", zhName: "OK", hasSound: true),
        Emote(slug: "good_job_buddy", name: "Good Job, Buddy!", zhName: "干得好，伙计！", hasSound: true),
        Emote(slug: "teamwork", name: "Teamwork!", zhName: "团队协作！", hasSound: true),
        Emote(slug: "i_will_destroy_you", name: "I will destroy you", zhName: "你瞅啥？", hasSound: true),
        Emote(slug: "not_today", name: "Not Today!", zhName: "没门！", hasSound: true),
        Emote(slug: "oh", name: "Oh...", zhName: "大受震撼", hasSound: true),
        Emote(slug: "come_again", name: "Come again?", zhName: "一脸问号", hasSound: true),
        Emote(slug: "magpie_oopsie", name: "Magpie Oopsie", zhName: "雀实有问题", hasSound: true),
        Emote(slug: "such_foolishness", name: "Such Foolishness", zhName: "如此愚蠢", hasSound: true),
    ]

    /// The emote wheel a fresh install starts with, from the top going clockwise.
    public static let standardWheel = ["unworthy_cn", "poro_snax", "sad_kitten", "cheeky_poro", "angry_kitty", "gg_heart", "bee_happy", "bee_mad"]
    /// What trigger + click sends until the user picks something else.
    public static let standardQuick = "facepalm"

    private static let index = Dictionary(uniqueKeysWithValues: all.map { ($0.slug, $0) })

    public static subscript(slug: String) -> Emote? { index[slug] }
    public static func contains(_ slug: String) -> Bool { index[slug] != nil }
}
