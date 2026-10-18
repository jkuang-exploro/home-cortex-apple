import Foundation

/// Existing on-disk keys are retained, including the body-independent setup attempt.
struct EmbodimentPreferences {
    enum Field: String {
        case attempt = "HomeCortex.embodiment.setup-attempt"
        case configuration = "HomeCortex.embodiment.configuration."
        case camera = "HomeCortex.camera.preference."
        case motion = "HomeCortex.motion.preference."
        case localization = "HomeCortex.localization.preference."
        case space = "HomeCortex.localization.space."
        case reference = "HomeCortex.localization.reference."
        case pendingReference = "HomeCortex.localization.pending."
        func key(body: String) -> String { self == .attempt ? rawValue : rawValue + body }
    }
    let storage: UserDefaults
    func load<T: Decodable>(_ type: T.Type, _ field: Field, body: String = "") -> T? {
        guard let data = storage.data(forKey: field.key(body: body)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func save<T: Encodable>(_ value: T, _ field: Field, body: String = "") throws {
        storage.set(try JSONEncoder().encode(value), forKey: field.key(body: body))
    }
    func selected(_ field: Field, body: String) -> Bool {
        storage.object(forKey: field.key(body: body)) as? Bool ?? true
    }
    func string(_ field: Field, body: String) -> String? { storage.string(forKey: field.key(body: body)) }
    func set(_ value: Bool, _ field: Field, body: String) { storage.set(value, forKey: field.key(body: body)) }
    func set(_ value: String, _ field: Field, body: String) { storage.set(value, forKey: field.key(body: body)) }
    func remove(_ field: Field, body: String = "") { storage.removeObject(forKey: field.key(body: body)) }
}

struct EmbodimentRuntimeSelection: Equatable {
    let camera: Bool
    let motion: Bool
    let localization: Bool
    init(foreground: Bool, enabled: Bool, credentialAvailable: Bool,
         camera: Bool, motion: Bool, localization: Bool) {
        let active = foreground && enabled && credentialAvailable
        self.camera = active && camera
        self.motion = active && motion
        self.localization = active && localization
    }
    static let stopped = Self(foreground: false, enabled: false, credentialAvailable: false,
                              camera: false, motion: false, localization: false)
}
