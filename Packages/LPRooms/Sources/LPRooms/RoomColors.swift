import Foundation

/// Name tag colours, picked by index so a peer can never send a raw colour. All read well with the tag's dark backing.
public enum TagColors {
    public static let all: [UInt32] = [
        0x4fc3f7, // sky
        0xff8a65, // coral
        0xaed581, // lime
        0xba68c8, // purple
        0xffd54f, // amber
        0x4db6ac, // teal
        0xf06292, // pink
        0xe0e0e0, // silver
    ]

    public static func isTagColor(_ n: Int) -> Bool { n >= 0 && n < all.count }
    public static func color(_ index: Int) -> UInt32 { isTagColor(index) ? all[index] : all[0] }
}
