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
    "AccountAccessibilityScreenshots/testSettings": 108,
    "AccountAccessibilityScreenshots/testSignIn": 35,
    "AccountAccessibilityScreenshots/testSubtitleAppearance": 54,
    "AccountLandscapeScreenshots/testProfiles": 95,
    "AccountLandscapeScreenshots/testSettings": 257,
    "AccountLandscapeScreenshots/testSignIn": 38,
    "AccountScreenshotTests/testProfilesDawn": 77,
    "AccountScreenshotTests/testProfilesRosePine": 65,
    "AccountScreenshotTests/testSettingsDawn": 147,
    "AccountScreenshotTests/testSettingsRosePine": 120,
    "AccountScreenshotTests/testSignInDawn": 29,
    "AccountScreenshotTests/testSignInRosePine": 33,
    "BrowseAccessibilityScreenshots/testLibrary": 43,
    "BrowseAccessibilityScreenshots/testSearch": 56,
    "BrowseAccessibilityScreenshots/testWatchlist": 38,
    "BrowseScreenshotTests/testLandscapeDawn": 158,
    "BrowseScreenshotTests/testLandscapeRosePine": 92,
    "BrowseScreenshotTests/testLibraryDawn": 69,
    "BrowseScreenshotTests/testLibraryRosePine": 37,
    "BrowseScreenshotTests/testSearchDawn": 53,
    "BrowseScreenshotTests/testSearchRosePine": 76,
    "BrowseScreenshotTests/testWatchlistDawn": 36,
    "BrowseScreenshotTests/testWatchlistRosePine": 39,
    "DeleteMediaTests/testDeleteFromDetailRemovesTheTitleEverywhere": 94,
    "DeleteMediaTests/testDeleteOfAWatchlistedTitleLeavesTheWatchlist": 64,
    "DownloadFlowTests/testDownloadPlaybackDark": 92,
    "DownloadFlowTests/testDownloadPlaybackLight": 105,
    "EpisodeSeasonTests/testSwitchingSeasonsShowsOnlySelectedEpisodes": 48,
    "GlassesScreenshotTests/testDownloads": 30,
    "GlassesScreenshotTests/testFirstConnectionAsks": 35,
    "GlassesScreenshotTests/testFirstConnectionAsksOnATV": 35,
    "GlassesScreenshotTests/testHome": 30,
    "GlassesScreenshotTests/testHomeButtonOpensTheRemote": 35,
    "GlassesScreenshotTests/testHomeEmber": 30,
    "GlassesScreenshotTests/testLibrary": 30,
    "GlassesScreenshotTests/testLiveTV": 30,
    "GlassesScreenshotTests/testMovie": 30,
    "GlassesScreenshotTests/testOptions": 30,
    "GlassesScreenshotTests/testPlayer": 40,
    "GlassesScreenshotTests/testRemoteSwipeAndTap": 40,
    "GlassesScreenshotTests/testRequest": 30,
    "GlassesScreenshotTests/testRequests": 30,
    "GlassesScreenshotTests/testSearch": 30,
    "GlassesScreenshotTests/testSeason": 30,
    "GlassesScreenshotTests/testSettings": 40,
    "GlassesScreenshotTests/testShow": 30,
    "GlassesScreenshotTests/testTracks": 40,
    "GlassesScreenshotTests/testTVHome": 30,
    "GlassesScreenshotTests/testTVHomeEmber": 30,
    "GlassesScreenshotTests/testTVMovie": 30,
    "GlassesScreenshotTests/testTVOptions": 30,
    "GlassesScreenshotTests/testTVPlayer": 40,
    "GlassesScreenshotTests/testTVUltrawide": 30,
    "HeaderAccessibilityScreenshots/testAlphabetRail": 22,
    "HeaderAccessibilityScreenshots/testBlur": 52,
    "HeaderAccessibilityScreenshots/testTabBar": 113,
    "HeaderScreenshotTests/testAlphabetRailDawn": 22,
    "HeaderScreenshotTests/testAlphabetRailRosePine": 22,
    "HeaderScreenshotTests/testBlurDawn": 54,
    "HeaderScreenshotTests/testBlurRosePine": 47,
    "HeaderScreenshotTests/testHardDawn": 51,
    "HeaderScreenshotTests/testHardRosePine": 45,
    "HeaderScreenshotTests/testSoftDawn": 47,
    "HeaderScreenshotTests/testSoftRosePine": 47,
    "HeaderScreenshotTests/testTabBarDawn": 126,
    "HeaderScreenshotTests/testTabBarRosePine": 96,
    "HomeRowsAccessibilityScreenshots/testHomeRows": 123,
    "HomeRowsScreenshotTests/testHomeRowsDawn": 101,
    "HomeRowsScreenshotTests/testHomeRowsRosePine": 140,
    "LiveDirectScreenshotTests/testDirectPlayerRosePine": 54,
    "LiveTVAccessibilityScreenshots/testGuide": 96,
    "LiveTVAccessibilityScreenshots/testPlayer": 98,
    "LiveTVScreenshotTests/testGridDawn": 30,
    "LiveTVScreenshotTests/testGridRosePine": 36,
    "LiveTVScreenshotTests/testGuideDawn": 70,
    "LiveTVScreenshotTests/testGuideRosePine": 85,
    "LiveTVScreenshotTests/testPlayerDawn": 112,
    "LiveTVScreenshotTests/testPlayerRosePine": 110,
    "LiveTVScreenshotTests/testRecordingsDawn": 99,
    "LiveTVScreenshotTests/testRecordingsRosePine": 88,
    "PlayerAccessibilityScreenshots/testNetworkWait": 95,
    "PlayerAccessibilityScreenshots/testPausedControlsAndPanels": 189,
    "PlayerAccessibilityScreenshots/testRouteMenu": 36,
    "PlayerAccessibilityScreenshots/testSkipIntro": 20,
    "PlayerAccessibilityScreenshots/testUpNext": 33,
    "PlayerLoadingRingTests/testCaptionAtAccessibilitySize": 18,
    "PlayerLoadingRingTests/testRingFillsWhileBuffering": 19,
    "PlayerLoadingRingTests/testRingTurnsWhileConnecting": 18,
    "PlayerRouteMenuScreenshots/testRouteMenuLandscape": 46,
    "PlayerRouteMenuScreenshots/testRouteMenuPortrait": 36,
    "PlayerScreenshotTests/testAutoBuffersInsteadOfDroppingBelowPictureFloor": 141,
    "PlayerScreenshotTests/testCastsToAChromecastAndBack": 28,
    "PlayerScreenshotTests/testFormatBadgeShowsOnFirstStart": 23,
    "PlayerScreenshotTests/testNetworkWaitOffersALowerQuality": 103,
    "PlayerScreenshotTests/testPanelsInLightTheme": 106,
    "PlayerScreenshotTests/testPausedControlsAndPanels": 176,
    "PlayerScreenshotTests/testScrubPreviewFollowsTheThumb": 52,
    "PlayerScreenshotTests/testSkipIntroCountsDownThenSkips": 19,
    "PlayerScreenshotTests/testUpNextCountsDownThenPlaysNext": 28,
    "PlayerScreenshotTests/testWatchIntroStopsTheCountdown": 37,
    "PlayerStartTimingTests/testDirectPlayStart": 64,
    "PlayerStartTimingTests/testServerTranscodeStart": 73,
    "RemoteAccessibilityScreenshots/testHomeButton": 72,
    "RemoteAccessibilityScreenshots/testMiniBar": 46,
    "RemoteAccessibilityScreenshots/testRemote": 39,
    "RemoteScreenshotTests/testHomeButtonChoice": 139,
    "RemoteScreenshotTests/testMiniBarSwipe": 45,
    "RemoteScreenshotTests/testMiniBarTap": 49,
    "RemoteScreenshotTests/testRemoteDawn": 44,
    "RemoteScreenshotTests/testRemoteHiddenAwayAndWhenPresenceUnknown": 83,
    "RemoteScreenshotTests/testRemoteRosePine": 43,
    "RemoteScreenshotTests/testSettingsSwitch": 49,
    "ScreenshotTests/testAccessibilitySettings": 34,
    "ScreenshotTests/testEmber": 29,
    "ScreenshotTests/testMatchSystemSlots": 36,
    "ScreenshotTests/testRosePineAndLiveSwitch": 72,
    "SeerrScreenshotTests/testRequestsDark": 36,
    "SeerrScreenshotTests/testRequestsLight": 43,
    "SeerrScreenshotTests/testSearch": 58,
    "SeerrScreenshotTests/testSeasonChoices": 31,
    "SubtitleAppearanceScreenshots/testDark": 65,
    "SubtitleAppearanceScreenshots/testLandscape": 60,
    "SubtitleAppearanceScreenshots/testLight": 55,
    "TabLayoutAccessibilityScreenshots/testPlacesOffTheBar": 56,
    "TabLayoutScreenshotTests/testPlacesOffTheBarDawn": 55,
    "TabLayoutScreenshotTests/testPlacesOffTheBarRosePine": 75,
    "ThemeMusicAccessibilityScreenshots/testThemeMusicSetting": 56,
    "ThemeMusicSettingsTests/testThemeMusicSettingDawn": 49,
    "ThemeMusicSettingsTests/testThemeMusicSettingRosePine": 44,
    "TrailerPreviewTests/testTheSettingTurnsItOff": 57,
    "TrailerPreviewTests/testTrailerPlaysInTheHero": 31,
    "WatchedShowTests/testMarkShowAndSeasonWatchedFromDetail": 58,
    "WatchedShowTests/testMarkShowWatchedFromContinueWatching": 21,
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
