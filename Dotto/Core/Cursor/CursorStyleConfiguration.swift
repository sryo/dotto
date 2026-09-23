import Foundation

enum CursorStatusStyle: String, Codable, Equatable, Sendable { case chat, ring, quiet }

/// The owner's cursor settings, in the shape the cursor prototype's "Copy settings" button produces, so a copied
/// JSON can replace these defaults as is.
struct CursorStyleConfiguration: Codable, Equatable, Sendable {
    static let defaultTaskColorHex = "#F0532D"
    static let cursorScaleRange = 0.5...2.0
    static let motionSpeedRange = 0.25...3.0

    var taskColorHex = defaultTaskColorHex
    var statusStyle = CursorStatusStyle.chat
    var cursorScale = 1.0
    var motionSpeed = 1.0
    /// nil follows the system's Reduce Motion setting.
    var reduceMotion: Bool? = nil
    var pauseOnlyForClicksInTargetApp = true

    static let standard = CursorStyleConfiguration()

    enum CodingKeys: String, CodingKey {
        case taskColorHex = "taskColor", statusStyle, cursorScale, motionSpeed, reduceMotion, pauseOnlyForClicksInTargetApp
    }

    init() {}

    /// Missing keys keep their defaults, and out-of-range sizes and speeds are clamped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CursorStyleConfiguration()
        taskColorHex = try container.decodeIfPresent(String.self, forKey: .taskColorHex) ?? defaults.taskColorHex
        statusStyle = try container.decodeIfPresent(CursorStatusStyle.self, forKey: .statusStyle) ?? defaults.statusStyle
        cursorScale = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? defaults.cursorScale,
                                   to: Self.cursorScaleRange)
        motionSpeed = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .motionSpeed) ?? defaults.motionSpeed,
                                   to: Self.motionSpeedRange)
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion)
        pauseOnlyForClicksInTargetApp = try container.decodeIfPresent(Bool.self, forKey: .pauseOnlyForClicksInTargetApp)
            ?? defaults.pauseOnlyForClicksInTargetApp
    }

    static func decodingOwnerJSON(_ jsonData: Data) throws -> CursorStyleConfiguration {
        try JSONDecoder().decode(CursorStyleConfiguration.self, from: jsonData)
    }

    /// 0…1 components of `taskColorHex` ("#RRGGBB" or "RRGGBB"); the default color when it can't be parsed.
    var taskColorRedGreenBlue: (red: Double, green: Double, blue: Double) {
        Self.redGreenBlue(fromHex: taskColorHex) ?? Self.redGreenBlue(fromHex: Self.defaultTaskColorHex) ?? (0, 0, 0)
    }

    private static func redGreenBlue(fromHex hexText: String) -> (red: Double, green: Double, blue: Double)? {
        let hexDigits = hexText.hasPrefix("#") ? String(hexText.dropFirst()) : hexText
        guard hexDigits.count == 6, let packedColor = UInt32(hexDigits, radix: 16) else { return nil }
        return (Double((packedColor >> 16) & 0xFF) / 255, Double((packedColor >> 8) & 0xFF) / 255, Double(packedColor & 0xFF) / 255)
    }

    private static func clamped(_ value: Double, to allowedRange: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, allowedRange.lowerBound), allowedRange.upperBound) : 1
    }
}
