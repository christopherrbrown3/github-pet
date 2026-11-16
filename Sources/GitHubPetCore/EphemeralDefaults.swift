import Foundation

/// In-memory `UserDefaults` for throwaway domains (simulated scope launches, unit tests).
/// Nothing reaches cfprefsd or disk: `removePersistentDomain` on a real suite still lets
/// cfprefsd write an empty plist later, so a quit, crash or late callback could otherwise
/// leave preference files behind. Only the accessors the stores use are supported.
public final class EphemeralDefaults: UserDefaults, @unchecked Sendable {
    public let name: String
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init(name: String) {
        self.name = name
        // nil suite = the app's search list; every accessor below is overridden so it is never read.
        super.init(suiteName: nil)!
    }

    private static let registryLock = NSLock()
    private static var registry: [String: EphemeralDefaults] = [:]
    /// One shared instance per name for the life of the process, until `release`.
    public static func named(_ name: String) -> EphemeralDefaults {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[name] { return existing }
        let created = EphemeralDefaults(name: name)
        registry[name] = created
        return created
    }
    public static func release(_ name: String) {
        registryLock.lock(); let released = registry.removeValue(forKey: name); registryLock.unlock()
        released?.removePersistentDomain(forName: name)
    }

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }; return values[defaultName]
    }
    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    public override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }
    public override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    public override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    public override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? Bool) ?? false }
    public override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? Int) ?? 0 }
    public override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? Double) ?? 0 }
    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    public override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    public override func persistentDomain(forName domainName: String) -> [String: Any]? {
        domainName == name ? dictionaryRepresentation() : nil
    }
    public override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == name else { return }
        lock.lock(); values = domain; lock.unlock()
    }
    public override func removePersistentDomain(forName domainName: String) {
        guard domainName == name else { return }
        lock.lock(); values = [:]; lock.unlock()
    }
    @discardableResult public override func synchronize() -> Bool { true }
}
