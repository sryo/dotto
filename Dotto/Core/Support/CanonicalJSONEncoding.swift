import Foundation

/// Sorted keys, unescaped slashes and ISO 8601 dates: encoding the same value twice gives the same bytes. Request
/// bodies rely on it for a stable prompt cache, and routine signatures are computed over these exact bytes, so the
/// options must never change.
enum CanonicalJSONEncoding {
    static func makeEncoder() -> JSONEncoder {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        canonicalEncoder.dateEncodingStrategy = .iso8601
        return canonicalEncoder
    }

    static func encode<EncodableValue: Encodable>(_ encodableValue: EncodableValue) throws -> Data {
        try makeEncoder().encode(encodableValue)
    }

    /// nil when the value can't be encoded.
    static func encodedText<EncodableValue: Encodable>(_ encodableValue: EncodableValue) -> String? {
        guard let encodedData = try? encode(encodableValue) else { return nil }
        return String(data: encodedData, encoding: .utf8)
    }
}
