import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct EphemeralDefaultsTests {
    @Test func storesInMemoryOnlyAndClearsOnDomainRemoval() throws {
        let name = "dev.github-pet.ephemeral.tests.\(UUID().uuidString)"
        let defaults = EphemeralDefaults.named(name)
        #expect(EphemeralDefaults.named(name) === defaults, "one shared store per name")
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.set("text", forKey: "string")
        defaults.set(true, forKey: "flag")
        #expect(defaults.data(forKey: "data") == Data([1, 2]) && defaults.data(forKey: "string") == nil)
        #expect(defaults.string(forKey: "string") == "text" && defaults.bool(forKey: "flag"))
        #expect(defaults.persistentDomain(forName: name)?.count == 3 && defaults.persistentDomain(forName: "other") == nil)
        defaults.removeObject(forKey: "flag")
        #expect(defaults.object(forKey: "flag") == nil)
        // Nothing went through cfprefsd: the real domain is empty and there is no plist.
        #expect(UserDefaults.standard.persistentDomain(forName: name)?.isEmpty != false)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        EphemeralDefaults.release(name)
        #expect(defaults.persistentDomain(forName: name)?.isEmpty == true)
        #expect(EphemeralDefaults.named(name) !== defaults, "release starts a fresh store")
        EphemeralDefaults.release(name)
    }
}
