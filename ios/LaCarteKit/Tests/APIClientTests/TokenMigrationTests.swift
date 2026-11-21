import Foundation
import Security
import Testing

@testable import APIClient

/// Spec 007 #13: moving the legacy token into the shared access group never loses it.
struct TokenMigrationTests {
  let token = Data("s3".utf8)

  @Test func anInPlaceMoveOrNoLegacyItemNeedsNothingElse() {
    for status in [errSecSuccess, errSecItemNotFound] {
      TokenStore.moveLegacyItem(
        update: { status },
        copy: { Issue.record("copied after \(status)"); return nil },
        add: { _ in Issue.record("added after \(status)"); return errSecSuccess },
        delete: { _ in Issue.record("deleted after \(status)") }
      )
    }
  }

  @Test func aRefusedMoveCopiesThenDeletesTheLegacyItem() {
    var added: Data?
    var deleted: String?
    TokenStore.moveLegacyItem(
      update: { errSecParam },
      copy: { (token, "TEAM.fr.lacarte.app") },
      add: { added = $0; return errSecSuccess },
      delete: { deleted = $0 }
    )
    #expect(added == token)
    #expect(deleted == "TEAM.fr.lacarte.app")
  }

  @Test func aFailedCopyKeepsTheLegacyItem() {
    TokenStore.moveLegacyItem(
      update: { errSecParam },
      copy: { (token, "TEAM.fr.lacarte.app") },
      add: { _ in errSecMissingEntitlement },
      delete: { _ in Issue.record("legacy token deleted although the copy failed") }
    )
  }
}
