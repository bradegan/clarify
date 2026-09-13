import Foundation
import Contacts

public struct ContactsStore: ContactsBridge {
    public init() {}

    public func lookup(name: String) async throws -> [ContactMatch] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try await store.requestAccess(for: .contacts)
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.map { c in
            ContactMatch(name: [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " "),
                         phones: c.phoneNumbers.map { $0.value.stringValue },
                         emails: c.emailAddresses.map { String($0.value) },
                         addresses: c.postalAddresses.map { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ") })
        }
    }
}
