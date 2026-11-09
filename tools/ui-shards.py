#!/usr/bin/env python3
"""Splits the UI tests into balanced shards for the CI matrix.

Every `func test...()` in UITests/*.swift is one unit, found by reading the sources, so a new test
is in a shard without anyone listing it. A unit is "accessibility" when its class or method name
contains "Accessibility": those run after the shard's standard units, with Increase Contrast and
accessibility text size on the simulator.

Prints the matrix as JSON: {"include": [{"shard": 1, "standard": "Class/test ...", "accessibility": "..."}]}.
Usage: ui-shards.py SHARDS [--no-accessibility]
"""
import json
import pathlib
import re
import sys

# Seconds per test as measured in CI on the 3-core runner (run 42559038250, 2026-11-09; the remote's from run
# 42614908575, the network wait's from run 42688112822). A test that is not listed gets the default, so a new
# test is placed roughly until its number is added here.
SECONDS = {
    "AccountAccessibilityScreenshots/testProfiles": 65,
    "AccountAccessibilityScreenshots/testSettings": 233,
    "AccountAccessibilityScreenshots/testSignIn": 27,
    "AccountLandscapeScreenshots/testProfiles": 98,
    "AccountLandscapeScreenshots/testSettings": 225,
    "AccountLandscapeScreenshots/testSignIn": 42,
    "AccountScreenshotTests/testProfilesDawn": 63,
    "AccountScreenshotTests/testProfilesRosePine": 67,
    "AccountScreenshotTests/testSettingsDawn": 159,
    "AccountScreenshotTests/testSettingsRosePine": 242,
    "AccountScreenshotTests/testSignInDawn": 29,
    "AccountScreenshotTests/testSignInRosePine": 27,
    "BrowseAccessibilityScreenshots/testLibrary": 57,
    "BrowseAccessibilityScreenshots/testSearch": 58,
    "BrowseAccessibilityScreenshots/testWatchlist": 31,
    "BrowseScreenshotTests/testLandscapeDawn": 66,
    "BrowseScreenshotTests/testLandscapeRosePine": 75,
    "BrowseScreenshotTests/testLibraryDawn": 31,
    "BrowseScreenshotTests/testLibraryRosePine": 37,
    "BrowseScreenshotTests/testSearchDawn": 49,
    "BrowseScreenshotTests/testSearchRosePine": 54,
    "BrowseScreenshotTests/testWatchlistDawn": 29,
    "BrowseScreenshotTests/testWatchlistRosePine": 32,
    "DeleteMediaTests/testDeleteFromDetailRemovesTheTitleEverywhere": 37,
    "DeleteMediaTests/testDeleteOfAWatchlistedTitleLeavesTheWatchlist": 54,
    "TrailerPreviewTests/testTheSettingTurnsItOff": 40,
    "TrailerPreviewTests/testTrailerPlaysInTheHero": 35,
    "WatchedShowTests/testMarkShowAndSeasonWatchedFromDetail": 45,
    "WatchedShowTests/testMarkShowWatchedFromContinueWatching": 35,
    "HeaderAccessibilityScreenshots/testAlphabetRail": 28,
    "HeaderAccessibilityScreenshots/testBlur": 44,
    "HeaderAccessibilityScreenshots/testTabBar": 80,
    "HeaderScreenshotTests/testAlphabetRailDawn": 17,
    "HeaderScreenshotTests/testAlphabetRailRosePine": 25,
    "HeaderScreenshotTests/testBlurDawn": 38,
    "HeaderScreenshotTests/testBlurRosePine": 41,
    "HeaderScreenshotTests/testHardDawn": 37,
    "HeaderScreenshotTests/testHardRosePine": 46,
    "HeaderScreenshotTests/testSoftDawn": 37,
    "HeaderScreenshotTests/testSoftRosePine": 38,
    "HeaderScreenshotTests/testTabBarDawn": 76,
    "HeaderScreenshotTests/testTabBarRosePine": 108,
    "HomeRowsAccessibilityScreenshots/testHomeRows": 173,
    "HomeRowsScreenshotTests/testHomeRowsDawn": 131,
    "HomeRowsScreenshotTests/testHomeRowsRosePine": 113,
    "LiveDirectScreenshotTests/testDirectPlayerRosePine": 26,
    "LiveTVAccessibilityScreenshots/testGuide": 70,
    "LiveTVAccessibilityScreenshots/testPlayer": 110,
    "LiveTVScreenshotTests/testGridDawn": 33,
    "LiveTVScreenshotTests/testGridRosePine": 23,
    "LiveTVScreenshotTests/testGuideDawn": 79,
    "LiveTVScreenshotTests/testGuideRosePine": 62,
    "LiveTVScreenshotTests/testPlayerDawn": 113,
    "LiveTVScreenshotTests/testPlayerRosePine": 79,
    "LiveTVScreenshotTests/testRecordingsDawn": 86,
    "LiveTVScreenshotTests/testRecordingsRosePine": 79,
    "PlayerAccessibilityScreenshots/testNetworkWait": 43,
    "PlayerAccessibilityScreenshots/testPausedControlsAndPanels": 75,
    "PlayerAccessibilityScreenshots/testSkipIntro": 22,
    "PlayerAccessibilityScreenshots/testUpNext": 31,
    "PlayerAccessibilityScreenshots/testWrongSubtitlesAndBazarr": 280,
    "PlayerRouteMenuScreenshots/testRouteMenuLandscape": 40,
    "PlayerRouteMenuScreenshots/testRouteMenuPortrait": 40,
    "PlayerAccessibilityScreenshots/testRouteMenu": 45,
    "PlayerScreenshotTests/testNetworkWaitOffersALowerQuality": 33,
    "PlayerScreenshotTests/testPanelsInLightTheme": 35,
    "PlayerScreenshotTests/testPausedControlsAndPanels": 66,
    "PlayerScreenshotTests/testScrubPreviewFollowsTheThumb": 39,
    "PlayerScreenshotTests/testSkipIntroCountsDownThenSkips": 14,
    "PlayerScreenshotTests/testUpNextCountsDownThenPlaysNext": 26,
    "PlayerScreenshotTests/testWatchIntroStopsTheCountdown": 40,
    "PlayerScreenshotTests/testWrongSubtitlesAndBazarr": 202,
    "PlayerScreenshotTests/testWrongSubtitlesAndBazarrInLightTheme": 147,
    "RemoteAccessibilityScreenshots/testRemote": 35,
    "RemoteScreenshotTests/testRemoteDawn": 43,
    "RemoteScreenshotTests/testRemoteRosePine": 29,
    "RemoteScreenshotTests/testSettingsSwitch": 59,
    "ScreenshotTests/testAccessibilitySettings": 22,
    "ScreenshotTests/testEmber": 20,
    "ScreenshotTests/testMatchSystemSlots": 38,
    "ScreenshotTests/testRosePineAndLiveSwitch": 70,
}
DEFAULT_SECONDS = 120

CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b")
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(\s*\)")


def discover(root):
    units = []
    for path in sorted(root.glob("*.swift")):
        current = None
        for line in path.read_text().splitlines():
            match = CLASS.match(line)
            if match:
                current = match.group(1)
                continue
            match = TEST.match(line)
            if match and current:
                units.append((current, match.group(1)))
    return units


def main():
    shards = int(sys.argv[1])
    with_accessibility = "--no-accessibility" not in sys.argv[2:]
    root = pathlib.Path(__file__).resolve().parent.parent / "UITests"

    units = []
    for cls, test in discover(root):
        accessibility = "Accessibility" in cls or "Accessibility" in test
        if accessibility and not with_accessibility:
            continue
        seconds = SECONDS.get(f"{cls}/{test}", DEFAULT_SECONDS)
        units.append((seconds, accessibility, f"{cls}/{test}"))
    if not units:
        sys.exit("No UI tests found in UITests/")

    # Longest first onto the lightest shard.
    bins = [{"seconds": 0, "standard": [], "accessibility": []} for _ in range(min(shards, len(units)))]
    for seconds, accessibility, name in sorted(units, key=lambda unit: (-unit[0], unit[2])):
        lightest = min(bins, key=lambda shard: shard["seconds"])
        lightest["seconds"] += seconds
        lightest["accessibility" if accessibility else "standard"].append(name)

    include = [
        {
            "shard": index + 1,
            "standard": " ".join(sorted(shard["standard"])),
            "accessibility": " ".join(sorted(shard["accessibility"])),
        }
        for index, shard in enumerate(bins)
    ]
    print(json.dumps({"include": include}))
    print(
        "Shards (estimated minutes): "
        + ", ".join(f"{shard['seconds'] / 60:.0f}" for shard in bins)
        + f"; {len(units)} tests",
        file=sys.stderr,
    )


main()
