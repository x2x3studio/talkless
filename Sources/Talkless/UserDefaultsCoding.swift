import Foundation

/// Codable preferences are stored as JSON data under versioned keys.
extension UserDefaults {
    /// The stored value, or nil when it is missing or cannot be decoded.
    func decoded<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    /// Stores the value; an encoding failure leaves the previous value untouched.
    func setEncoded<Value: Encodable>(_ value: Value, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, forKey: key) }
    }
}
