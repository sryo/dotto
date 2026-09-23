import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(parsingJSONText jsonText: String) throws {
        try self.init(parsingJSONData: Data(jsonText.utf8))
    }

    init(parsingJSONData jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }

    init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        if singleValueContainer.decodeNil() {
            self = .null
        } else if let decodedBool = try? singleValueContainer.decode(Bool.self) {
            // Bool is tried before Double so `true` never turns into 1.0; JSONDecoder refuses to
            // read the number 1 as a Bool, so numbers still land in the Double branch below.
            self = .bool(decodedBool)
        } else if let decodedNumber = try? singleValueContainer.decode(Double.self) {
            self = .number(decodedNumber)
        } else if let decodedString = try? singleValueContainer.decode(String.self) {
            self = .string(decodedString)
        } else if let decodedArray = try? singleValueContainer.decode([JSONValue].self) {
            self = .array(decodedArray)
        } else {
            self = .object(try singleValueContainer.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        switch self {
        case .string(let stringContent): try singleValueContainer.encode(stringContent)
        case .number(let numberContent): try singleValueContainer.encode(numberContent)
        case .bool(let boolContent): try singleValueContainer.encode(boolContent)
        case .null: try singleValueContainer.encodeNil()
        case .array(let arrayContent): try singleValueContainer.encode(arrayContent)
        case .object(let objectContent): try singleValueContainer.encode(objectContent)
        }
    }

    var stringValue: String? {
        if case .string(let stringContent) = self { return stringContent }
        return nil
    }

    var numberValue: Double? {
        if case .number(let numberContent) = self { return numberContent }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let boolContent) = self { return boolContent }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let arrayContent) = self { return arrayContent }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let objectContent) = self { return objectContent }
        return nil
    }

    subscript(objectKey: String) -> JSONValue? {
        objectValue?[objectKey]
    }
}
