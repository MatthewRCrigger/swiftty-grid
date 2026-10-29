import Foundation
import Testing

@testable import RoamingApp

/// RoamingApp's strings resolve in its own String Catalog, not
/// `Bundle.main`, so the catalog's plural variants apply.
@Suite
struct LocalizationTests {
  @Test
  func countsUseTheCatalogsPluralVariants() {
    #expect(String(localized: .localized("\(1) tabs")) == "1 tab")
    #expect(String(localized: .localized("\(2) tabs")) == "2 tabs")
    #expect(String(localized: .localized("\(1) panes")) == "1 pane")
    #expect(String(localized: .localized("\(3) panes")) == "3 panes")
    #expect(
      String(
        localized: .localized(
          "\(1) hosts keep this key selected and will not connect until you choose another key."
        )
      )
        == "1 host keeps this key selected and will not connect until you choose another key."
    )
    #expect(
      String(
        localized: .localized(
          "\(1) items from another iCloud account are hidden."
        )
      ) == "1 item from another iCloud account is hidden."
    )
  }
}
