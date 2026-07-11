import XCTest

@testable import Gravitas_Plague

final class TuringRichFillerCatalogTests:
  XCTestCase
{

  func testMissingWeightDefaultsToOne() {
    let url = URL(
      fileURLWithPath:
        "/tmp/rich-filler_hmm.mp3"
    )
    XCTAssertEqual(
      TuringRichFillerCatalog
        .parsedWeight(from: url),
      1
    )
  }

  func testZeroWeightClampsToOne() {
    let url = URL(
      fileURLWithPath:
        "/tmp/rich-filler_hmm_0.mp3"
    )
    XCTAssertEqual(
      TuringRichFillerCatalog
        .parsedWeight(from: url),
      1
    )
  }

  func testSixWeightProducesSixEntries() {
    let url = URL(
      fileURLWithPath:
        "/tmp/rich-filler_hmm_6.mp3"
    )
    let catalog =
      TuringRichFillerCatalog(
        weightedEntries:
          Array(
            repeating: url,
            count:
              TuringRichFillerCatalog
              .parsedWeight(
                from: url
              )
          )
      )

    XCTAssertEqual(
      catalog.weightedEntryCount,
      6
    )
    XCTAssertEqual(
      catalog.uniqueFileCount,
      1
    )
  }

  func testOversizedWeightClampsToTen() {
    let url = URL(
      fileURLWithPath:
        "/tmp/rich-filler_hmm_99.mp3"
    )
    XCTAssertEqual(
      TuringRichFillerCatalog
        .parsedWeight(from: url),
      10
    )
  }

  func testImmediateRepeatIsAvoidedWhenPossible() {
    let first = URL(
      fileURLWithPath:
        "/tmp/rich-filler_first_1.mp3"
    )
    let second = URL(
      fileURLWithPath:
        "/tmp/rich-filler_second_1.mp3"
    )
    let catalog =
      TuringRichFillerCatalog(
        weightedEntries: [
          first,
          second,
        ]
      )

    for _ in 0..<20 {
      XCTAssertEqual(
        catalog.randomURL(
          avoiding: first
        ),
        second
      )
    }
  }
}
