import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct InboxLegibilityTests {
    // macOS windows: light is ~#ECECEC (or white under a popover), dark is ~#1E1E1E to #323232.
    private let lightBackgrounds = [236.0, 255]
    private let darkBackgrounds = [30.0, 50]

    @Test func contrastMatchesKnownWCAGValues() {
        #expect(abs(WCAGContrast.grayRatio(foreground: 0, alpha: 1, background: 255) - 21) < 0.01)
        #expect(abs(WCAGContrast.grayRatio(foreground: 119, alpha: 1, background: 255) - 4.48) < 0.02)
        #expect(WCAGContrast.grayRatio(foreground: 255, alpha: 0, background: 255) == 1)
    }

    @Test func dimmedTextMeetsAAInLightAndDark() {
        for role in [InboxDimming.Role.title, .context] {
            for background in lightBackgrounds {
                #expect(InboxDimming.textRatio(role, labelGray: 0, backgroundGray: background) >= WCAGContrast.normalTextAA)
            }
            for background in darkBackgrounds {
                #expect(InboxDimming.textRatio(role, labelGray: 255, backgroundGray: background) >= WCAGContrast.normalTextAA)
            }
        }
    }

    @Test func theOldWholeListFadeFailedAA() {
        // 0.55 opacity over the system secondary label (50% black on #ECECEC): the reason for #104.
        let secondary = 236 - (236 - 0) * 0.5
        let faded = WCAGContrast.grayRatio(foreground: secondary, alpha: 0.55, background: 236)
        #expect(faded < 2.5)
    }

    @Test func increasedContrastNeverDims() {
        for role in [InboxDimming.Role.title, .context, .glyph] {
            #expect(InboxDimming.alpha(role, dimmed: true, increasedContrast: true) == 1)
            #expect(InboxDimming.alpha(role, dimmed: false, increasedContrast: false) == 1)
            #expect(InboxDimming.alpha(role, dimmed: true, increasedContrast: false) < 1)
        }
    }

    @Test func titleStaysStrongerThanContext() {
        #expect(InboxDimming.alpha(.title, dimmed: true, increasedContrast: false)
                > InboxDimming.alpha(.context, dimmed: true, increasedContrast: false))
    }

    @Test func largerTextScrollsSoonerAndNeverShrinks() {
        #expect(!InboxRowMetrics.scrolls(rows: 6, sections: 2))
        #expect(InboxRowMetrics.scrolls(rows: 6, sections: 2, textScale: 1.6))
        #expect(InboxRowMetrics.naturalListHeight(rows: 3, sections: 1, textScale: 0.5)
                == InboxRowMetrics.naturalListHeight(rows: 3, sections: 1))
    }

    @Test func authoredPullRequestHasItsOwnGlyph() {
        let symbols = ItemKind.allCases.map(\.symbolName)
        #expect(ItemKind.authoredPullRequest.symbolName == "arrow.triangle.branch")
        #expect(symbols.filter { $0 == ItemKind.authoredPullRequest.symbolName }.count == 1)
    }
}
