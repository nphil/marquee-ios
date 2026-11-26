import Foundation
import Testing
@testable import MarqueeCore

/// Builders shared by the Recordings tests.
enum RecordingsFixtures {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func at(_ minutes: Double) -> Date { LiveFixtures.at(minutes: minutes) }

    /// "2027-01-15" for the day `minutes` falls on, `days` later.
    static func day(_ minutes: Double = 0, days: Int = 0) -> String {
        let date = utc.date(byAdding: .day, value: days, to: at(minutes))!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func grab(
        _ id: String, rule: String? = nil, channel: String = "a", status: ScheduledRecording.Status = .scheduled,
        from: Double, to: Double, title: String = "Show", episodeTitle: String? = nil, guid: String? = nil, first: String? = nil
    ) -> ScheduledRecording {
        ScheduledRecording(
            id: id, ruleID: rule ?? id, status: status, channelKey: channel, channelNumber: "7.1", channelCallSign: "WABC",
            title: title, episodeTitle: episodeTitle, guid: guid, start: at(from), end: at(to), originallyAvailableAt: first
        )
    }

    static func rule(_ id: String, type: Int = 2, title: String = "Show", settings: [RecordSetting] = []) -> RecordingRule {
        RecordingRule(id: id, type: type, title: title, settings: settings)
    }

    static func dvr(tuners: Int = 1, padding: (Int, Int) = (0, 0)) -> LiveDVR {
        let device = TunerDevice(
            key: "21", uuid: "device://tv.plex.grabbers.hdhomerun/1", uri: URL(string: "http://192.0.2.42:5004")!,
            name: "Tuner", tunerCount: tuners, isAlive: true
        )
        return LiveDVR(
            key: "12", uuid: "u", title: "Antenna", epgIdentifier: LiveTVTests.epg, devices: [device], mappings: [],
            startOffsetMinutes: padding.0, endOffsetMinutes: padding.1
        )
    }

    static func setting(
        _ id: String, _ type: String, _ value: String, label: String = "", choices: String? = nil, hidden: Bool = false, base: String? = nil
    ) -> RecordSetting {
        RecordSetting(
            id: id, label: label, type: type, value: value, isHidden: hidden, defaultValue: base,
            choices: RecordSetting.choices(choices)
        )
    }

    /// A template like the home server's, with every row the sheet knows.
    static func settings(oneShot: Bool, onlyNew: Bool = false) -> [RecordSetting] {
        var all = [
            setting("startOffsetMinutes", "int", "0"),
            setting("endOffsetMinutes", "int", "0"),
            setting("minVideoQuality", "int", "0", label: "Resolution", choices: "0:Prefer HD|720:HD Only|1080:Full HD Only"),
            setting("replaceLowerQuality", "bool", "false"),
            setting("recordPartials", "bool", "false"),
            setting("comskipEnabled", "bool", "false"),
            setting("comskipMethod", "int", "0", choices: "0:Detect only|1:Remove commercials"),
            setting("autoDeletionItemPolicyUnwatchedLibrary", "int", "0"),
            setting("autoDeletionItemPolicyWatchedLibrary", "int", "0", choices: "0:Never|1:After a day|7:After a week|100:On next refresh"),
            setting("lineupChannel", "text", ""),
            setting("oneShot", "bool", oneShot ? "true" : "false", hidden: true),
        ]
        if onlyNew { all.append(setting("onlyNewAirings", "int", "1", label: "Airings", choices: "0:New and Repeat Airings|1:New Airings Only")) }
        return all
    }

    static func options(libraryID: Int = 2, locationID: Int = 3) -> [RecordOption] {
        [
            RecordOption(type: 4, title: "This Episode", targetLibrarySectionID: libraryID, targetSectionLocationID: locationID,
                         settings: settings(oneShot: true), parameters: "hints%5Bguid%5D=plex%3A%2F%2Fepisode%2F1"),
            RecordOption(type: 2, title: "All Episodes", targetLibrarySectionID: libraryID, targetSectionLocationID: locationID,
                         settings: settings(oneShot: false, onlyNew: true), parameters: "hints%5Bguid%5D=plex%3A%2F%2Fshow%2F1"),
        ]
    }

    static func airing(title: String = "Jimmy Kimmel Live!", genres: [String] = ["Talk"], guid: String = "plex://episode/1") -> LiveAiring {
        LiveAiring(
            id: "air-1", channelKey: "aaa-0701", guid: guid, kind: .episode, title: title, episodeTitle: "Tonight",
            start: at(120), end: at(180), isNew: true, genres: genres
        )
    }

    static let channel = LiveChannel(
        id: "aaa-0701", dvrKey: "12", number: "7.1", callSign: "WABC", title: "ABC", logo: nil, isHD: true, device: RouteCase.luma
    )

    static func draft(
        _ airing: LiveAiring = airing(), options: [RecordOption] = options(), libraries: [RecordingLibrary] = []
    ) -> RecordingDraft {
        RecordingDraft(airing: airing, channel: channel, options: options, libraries: libraries)!
    }
}

struct RecordingPlanTests {
    typealias F = RecordingsFixtures

    @Test func freshnessComparesTheOriginalAirDateWithTheAiringDay() {
        #expect(F.grab("a", from: 0, to: 60, first: F.day()).freshness(calendar: F.utc) == .new)
        #expect(F.grab("a", from: 0, to: 60, first: F.day(days: 2)).freshness(calendar: F.utc) == .new)
        #expect(F.grab("a", from: 0, to: 60, first: F.day(days: -3)).freshness(calendar: F.utc) == .rerun)
        #expect(F.grab("a", from: 0, to: 60).freshness(calendar: F.utc) == nil)
        #expect(AiringFreshness.new.badge == "NEW" && AiringFreshness.rerun.badge == "RERUN")
    }

    @Test func upcomingGroupsByDayAndSkipsWhatIsOver() {
        let recordings = LiveRecordings(rules: [], scheduled: [
            F.grab("late", from: 1_500, to: 1_560),
            F.grab("now", status: .inprogress, from: 0, to: 60),
            F.grab("soon", from: 120, to: 180),
            F.grab("done", status: .complete, from: -120, to: -60),
            F.grab("over", from: -60, to: 5),
            F.grab("far", from: 3_000, to: 3_060),
        ])

        let days = RecordingPlan(recordings, dvr: nil).upcoming(now: F.at(10), calendar: F.utc)

        #expect(days.map(\.id) == [F.day(), F.day(days: 1), F.day(days: 2)])
        #expect(days.map { $0.items.map(\.id) } == [["now", "soon"], ["late"], ["far"]])
        #expect(days.map { $0.heading(now: F.at(10), calendar: F.utc) } == ["Today", "Tomorrow", "Sunday, Jan 17"])
        #expect(days[0].items.map(\.status) == [.recording, .scheduled])
        #expect(days[0].items[0].status.label == "Recording now")
    }

    @Test func overlappingAiringsOnTwoChannelsConflictOnOneTuner() {
        let recordings = LiveRecordings(
            rules: [F.rule("one", title: "Show A"), F.rule("two", title: "Show B")],
            scheduled: [F.grab("one", channel: "a", from: 100, to: 160, title: "Show A"), F.grab("two", channel: "b", from: 130, to: 190, title: "Show B")]
        )
        let plan = RecordingPlan(recordings, dvr: F.dvr())

        let conflicts = plan.conflicts(now: F.at(0))

        let conflict = try! #require(conflicts.first)
        #expect(conflicts.count == 1 && conflict.grabs.map(\.id) == ["one", "two"] && conflict.losers.map(\.id) == ["two"])
        #expect(conflict.window == DateInterval(start: F.at(130), end: F.at(160)))
        #expect(conflict.sentence == "Show B won't record: Show A has the only tuner then.")
        let rows = plan.upcoming(now: F.at(0), calendar: F.utc).flatMap(\.items)
        #expect(rows.map(\.isConflict) == [true, true] && rows.map(\.losesToConflict) == [false, true])
        #expect(RecordingPlan(recordings, dvr: nil).conflicts(now: F.at(0)).isEmpty)
        #expect(RecordingPlan(recordings, dvr: F.dvr(tuners: 2)).conflicts(now: F.at(0)).isEmpty)
    }

    @Test func rulePriorityDecidesWhoLosesUnlessOneIsAlreadyRecording() {
        let rules = [F.rule("one"), F.rule("two")]
        let higher = F.grab("two", channel: "b", from: 100, to: 160)
        let lower = F.grab("one", channel: "a", from: 130, to: 190)

        let byRule = RecordingPlan(LiveRecordings(rules: rules, scheduled: [higher, lower]), dvr: F.dvr())
        let running = RecordingPlan(
            LiveRecordings(rules: rules, scheduled: [{ var running = higher; running.status = .inprogress; return running }(), lower]),
            dvr: F.dvr()
        )

        #expect(byRule.conflicts(now: F.at(0)).first?.losers.map(\.id) == ["two"])
        #expect(running.conflicts(now: F.at(0)).first?.losers.map(\.id) == ["one"])
    }

    @Test func airingsOnOneChannelShareATuner() {
        let recordings = LiveRecordings(rules: [], scheduled: [
            F.grab("one", from: 100, to: 160), F.grab("two", from: 130, to: 190), F.grab("three", channel: "b", from: 300, to: 360),
        ])

        #expect(RecordingPlan(recordings, dvr: F.dvr()).conflicts(now: F.at(0)).isEmpty)
    }

    @Test func paddingTurnsBackToBackAiringsIntoAConflict() {
        func plan(end: Int) -> RecordingPlan {
            let rule = F.rule("one", settings: [F.setting("endOffsetMinutes", "int", String(end))])
            let recordings = LiveRecordings(
                rules: [rule, F.rule("two")],
                scheduled: [F.grab("one", channel: "a", from: 100, to: 160), F.grab("two", channel: "b", from: 160, to: 220)]
            )
            return RecordingPlan(recordings, dvr: F.dvr())
        }

        #expect(plan(end: 0).conflicts(now: F.at(0)).isEmpty)
        let padded = plan(end: 5).conflicts(now: F.at(0))
        #expect(padded.first?.window == DateInterval(start: F.at(160), end: F.at(165)) && padded.first?.losers.map(\.id) == ["two"])
        #expect(plan(end: 5).padding(of: F.grab("two", from: 0, to: 1)) == (0, 0))
        let defaults = RecordingPlan(LiveRecordings(scheduled: [F.grab("x", from: 0, to: 1)]), dvr: F.dvr(padding: (2, 5)))
        #expect(defaults.padding(of: F.grab("x", from: 0, to: 1)) == (2, 5))
    }

    @Test func anotherAiringOfTheSameEpisodeFreesTheTuner() {
        let rules = [F.rule("one", title: "Show A"), F.rule("two", title: "Show B")]
        let loser = F.grab("two", channel: "b", from: 130, to: 190, title: "Show B", episodeTitle: "Pilot", guid: "plex://episode/p")
        let recordings = LiveRecordings(rules: rules, scheduled: [F.grab("one", channel: "a", from: 100, to: 160, title: "Show A"), loser])
        let plan = RecordingPlan(recordings, dvr: F.dvr())
        func airing(_ id: String, channel: String, from: Double, guid: String = "plex://episode/p") -> LiveAiring {
            LiveAiring(id: id, channelKey: channel, guid: guid, title: "Show B", episodeTitle: "Pilot", start: F.at(from), end: F.at(from + 60))
        }
        let guide = [
            airing("later", channel: "c", from: 400),
            airing("same", channel: "b", from: 130),
            airing("clash", channel: "c", from: 110),
            airing("other", channel: "c", from: 300, guid: "plex://episode/q"),
            airing("past", channel: "c", from: -300),
            airing("earlier", channel: "d", from: 200),
        ]

        let found = plan.alternatives(to: loser, in: guide, now: F.at(0))

        #expect(found.map(\.id) == ["earlier", "later"])
    }

    @Test func aTunerCountComesFromTheLiveDevices() {
        let live = TunerDevice(key: "1", uuid: "u1", uri: URL(string: "http://a")!, name: "A", tunerCount: 1, isAlive: true)
        let dead = TunerDevice(key: "2", uuid: "u2", uri: URL(string: "http://b")!, name: "B", tunerCount: 2, isAlive: false)
        func dvr(_ devices: [TunerDevice]) -> LiveDVR {
            LiveDVR(key: "12", uuid: "u", title: "T", epgIdentifier: "e", devices: devices, mappings: [])
        }

        #expect(dvr([live, dead]).tuners == 1 && dvr([dead]).tuners == 2 && dvr([]).tuners == 1)
    }

    @Test func liveEventsAreSportsAndLiveGenres() {
        func airing(_ genres: [String]) -> LiveAiring {
            LiveAiring(id: "1", channelKey: "a", title: "T", start: F.at(0), end: F.at(60), genres: genres)
        }

        #expect(airing(["Sports"]).isLiveEvent && airing(["Sports event"]).isLiveEvent && airing(["Live"]).isLiveEvent)
        #expect(airing(["Football"]).isLiveEvent && !airing(["News"]).isLiveEvent && !airing([]).isLiveEvent)
    }

    @Test func layoutSplitsFromSixHundredPointsAndRulesReorderBehindTheirNeighbour() {
        #expect(RecordingsLayout.layout(width: 430) == .stack && RecordingsLayout.layout(width: 599) == .stack)
        #expect(RecordingsLayout.layout(width: 600) == .split && RecordingsLayout.layout(width: 1_024) == .split)
        let rules = ["a", "b", "c"].map { F.rule($0) }

        #expect(RuleOrder.move(rules, from: 2, to: 0)?.rules.map(\.id) == ["c", "a", "b"])
        #expect(RuleOrder.move(rules, from: 2, to: 0)?.after == nil)
        #expect(RuleOrder.move(rules, from: 0, to: 1)?.rules.map(\.id) == ["b", "a", "c"])
        #expect(RuleOrder.move(rules, from: 0, to: 2)?.after?.id == "c")
        #expect(RuleOrder.move(rules, from: 1, to: 1) == nil && RuleOrder.move(rules, from: 1, to: 3) == nil)
    }
}

struct RecordingDraftTests {
    typealias F = RecordingsFixtures

    @Test func threeChoicesLeadAndThisEpisodeIsTheDefault() {
        var draft = F.draft()

        #expect(draft.scopes.map(\.title) == ["This Episode", "New Episodes", "All Episodes"])
        #expect(draft.scope == .episode && draft.submission?.option.type == 4)
        draft.choose(scope: .new)
        #expect(draft.submission?.option.type == 2 && draft.submission?.values == [:])
        draft.choose(scope: .all)
        #expect(draft.submission?.values == ["onlyNewAirings": "0"])
    }

    @Test func aShowOnlyTemplateStartsOnNewEpisodesAndAMovieOnTheMovie() {
        let showOnly = [F.options()[1]]
        let movie = [RecordOption(type: 1, title: "This Movie", settings: F.settings(oneShot: true))]

        #expect(F.draft(options: showOnly).scope == .new)
        let draft = F.draft(F.airing(title: "Casablanca"), options: movie)
        #expect(draft.scope == .movie && draft.scopes.map(\.title) == ["This Movie"])
        #expect(RecordingDraft(airing: F.airing(), channel: nil, options: [])?.scope == nil)
    }

    @Test func theSummaryReadsBackWhatWillBeRecorded() {
        var draft = F.draft()

        #expect(draft.summary == "Records this episode of Jimmy Kimmel Live! on any channel.")
        draft.choose(scope: .new)
        draft.choose(.start, "2")
        draft.choose(.keep, "latest:5")
        #expect(draft.summary == "Records new episodes of Jimmy Kimmel Live! on any channel, starts 2 min early, keeps the latest 5.")
        draft.choose(scope: .all)
        draft.choose(.channel, "this")
        draft.choose(.end, "15")
        draft.set(.replace, on: true)
        draft.set(.commercials, on: true)
        draft.set(.partials, on: true)
        draft.choose(.resolution, "720")
        draft.choose(.keep, "watched")
        #expect(draft.summary == "Records all episodes of Jimmy Kimmel Live! on 7.1 WABC only, starts 2 min early, ends 15 min late, "
            + "only records HD, swaps in a better copy when one airs, removes commercials, records partial airings, "
            + "deletes each one once it is watched.")
    }

    @Test func rowsComeFromTheTemplateAndTakeItsChoices() {
        var draft = F.draft()

        #expect(draft.rows.map(\.id) == [.channel, .resolution, .replace, .start, .end, .keep, .commercials, .partials])
        let rows = Dictionary(uniqueKeysWithValues: draft.rows.map { ($0.id, $0) })
        #expect(rows[.resolution]?.title == "Resolution" && rows[.resolution]?.choices.map(\.label) == ["Prefer HD", "HD Only", "Full HD Only"])
        #expect(rows[.start]?.choices.map(\.id) == ["0", "2", "5", "15", "30"] && rows[.start]?.choices.first?.label == "Off")
        #expect(rows[.replace]?.control == .toggle(false) && rows[.commercials]?.control == .toggle(false))
        #expect(rows[.keep]?.choices.map(\.id) == ["all", "latest:1", "latest:3", "latest:5", "days:3", "days:7", "days:30", "watched"])
        draft.set(.replace, on: true)
        #expect(draft.rows.first { $0.id == .replace }?.control == .toggle(true))
        let bare = [RecordOption(type: 4, title: "This Episode", settings: [F.setting("startOffsetMinutes", "int", "0")])]
        #expect(F.draft(options: bare).rows.map(\.id) == [.start])
        let hd = [F.setting("minVideoQuality", "int", "0", choices: "0:Prefer HD|720:HD Only")]
        let toggle = F.draft(options: [RecordOption(type: 4, title: "This Episode", settings: hd)])
        #expect(toggle.rows.first?.title == "Prefer HD" && toggle.rows.first?.control == .toggle(true))
    }

    @Test func keepWritesPlexsTwoDeletionSettings() {
        var draft = F.draft()

        draft.choose(.keep, "latest:5")
        #expect(draft.submission?.values == ["autoDeletionItemPolicyUnwatchedLibrary": "5"])
        draft.choose(.keep, "days:7")
        #expect(draft.submission?.values == ["autoDeletionItemPolicyUnwatchedLibrary": "-7"])
        draft.choose(.keep, "watched")
        #expect(draft.submission?.values == ["autoDeletionItemPolicyWatchedLibrary": "100"])
        #expect(draft.rows.first { $0.id == .keep }?.control == .menu(selected: "watched"))
        draft.choose(.keep, "all")
        #expect(draft.submission?.values == [:])
    }

    @Test func commercialsSwitchOnTheCutMethodToo() {
        var draft = F.draft()

        draft.set(.commercials, on: true)

        #expect(draft.submission?.values == ["comskipEnabled": "true", "comskipMethod": "1"])
        draft.set(.commercials, on: false)
        #expect(draft.submission?.values["comskipEnabled"] == nil)
    }

    @Test func sportsGetAnHourOfEndPaddingTheUserCanChange() {
        var draft = F.draft(F.airing(title: "College Football", genres: ["Sports event"]))

        #expect(draft.scopes.map(\.title) == ["This Event", "New Events", "All Events"])
        #expect(draft.submission?.values == ["endOffsetMinutes": "60"] && draft.padsLiveEvent)
        let end = draft.rows.first { $0.id == .end }
        #expect(end?.control == .menu(selected: "60") && end?.choices.last?.label == "1 hour late" && end?.note != nil)
        #expect(draft.summary == "Records this event of College Football on any channel, ends 1 hour late.")
        draft.choose(.end, "0")
        #expect(draft.submission?.values == [:] && !draft.padsLiveEvent && draft.rows.first { $0.id == .end }?.note == nil)
        #expect(RecordingDraft.quickValues(for: F.airing(genres: ["Sports"]), option: F.options()[0]) == ["endOffsetMinutes": "60"])
        #expect(RecordingDraft.quickValues(for: F.airing(), option: F.options()[0]).isEmpty)
        let long = RecordOption(type: 4, title: "x", settings: [F.setting("endOffsetMinutes", "int", "90")])
        #expect(RecordingDraft.quickValues(for: F.airing(genres: ["Sports"]), option: long).isEmpty)
    }

    @Test func aLibraryRowAppearsWithMoreThanOneAndChangesTheTarget() {
        let libraries = [
            RecordingLibrary(id: 2, locationID: 3, title: "TV Shows", kind: .show),
            RecordingLibrary(id: 5, locationID: 6, title: "Kids", kind: .show),
            RecordingLibrary(id: 1, locationID: 9, title: "Movies", kind: .movie),
        ]
        var draft = F.draft(libraries: libraries)

        let row = draft.rows.first { $0.id == .library }
        #expect(row?.choices.map(\.label) == ["TV Shows", "Kids"] && row?.control == .menu(selected: "2"))
        draft.choose(.library, "5")
        #expect(draft.submission?.option.targetLibrarySectionID == 5 && draft.submission?.option.targetSectionLocationID == 6)
        #expect(draft.summary == "Records this episode of Jimmy Kimmel Live! on any channel, saves to Kids.")
        #expect(F.draft(libraries: [libraries[0], libraries[2]]).rows.contains { $0.id == .library } == false)
    }

    @Test func thisChannelOnlyUsesTheAiringsChannel() {
        var draft = F.draft()

        draft.choose(.channel, "this")

        #expect(draft.submission?.values == ["lineupChannel": "aaa-0701"])
        #expect(draft.rows.first { $0.id == .channel }?.control == .menu(selected: "this"))
        draft.choose(.channel, "any")
        #expect(draft.submission?.values == [:])
    }

    @Test func editingARuleUsesTheSameSheetAndSendsOnlyChanges() {
        let settings = [F.setting("onlyNewAirings", "int", "1", choices: "0:New and Repeat Airings|1:New Airings Only"),
                        F.setting("startOffsetMinutes", "int", "2")]
        var series = RecordingDraft(editing: F.rule("9", title: "Evening News", settings: settings))
        let oneOff = RecordingDraft(editing: F.rule("8", type: 4, title: "Evening News", settings: [F.setting("oneShot", "bool", "true", hidden: true)]))

        #expect(series.scopes.map(\.title) == ["New Episodes", "All Episodes"] && series.scope == .new && !series.isChanged)
        #expect(series.summary == "Records new episodes of Evening News on any channel, starts 2 min early.")
        series.choose(scope: .all)
        series.choose(.start, "5")
        #expect(series.isChanged && series.submission?.values == ["onlyNewAirings": "0", "startOffsetMinutes": "5"])
        #expect(oneOff.scopes.map(\.title) == ["This Episode"] && oneOff.summary == "Records this episode of Evening News on any channel.")
        #expect(F.rule("9", settings: settings).summary == "Records new episodes of Show on any channel, starts 2 min early.")
    }
}

struct RecordingJournalTests {
    typealias F = RecordingsFixtures

    @Test func theFirstLookReportsNothingAndThenStartsAndFinishesAreEvents() {
        var journal = RecordingJournal()
        let rule = F.rule("g")
        func look(_ status: ScheduledRecording.Status?, _ minutes: Double) -> [RecordingEvent] {
            let grabs = status.map { [F.grab("g", status: $0, from: 30, to: 90, title: "Jimmy Kimmel Live!")] } ?? []
            return journal.observe(LiveRecordings(rules: [rule], scheduled: grabs), dvr: F.dvr(), now: F.at(minutes))
        }

        #expect(look(.scheduled, 0).isEmpty)
        let started = look(.inprogress, 31)
        #expect(started.map(\.kind) == [.started] && started[0].title == "Recording started")
        #expect(started[0].body == "Jimmy Kimmel Live! · 7.1 WABC" && started[0].id == "g.started")
        #expect(look(.inprogress, 60).isEmpty)
        let finished = look(nil, 91)
        #expect(finished.map(\.kind) == [.finished] && finished[0].title == "Recording finished")
        #expect(journal.history.isEmpty && look(nil, 120).isEmpty)
    }

    @Test func anErrorIsAFailureWithItsReason() {
        var journal = RecordingJournal()
        let failing = F.grab("g", status: .error, from: 30, to: 90, title: "Show")
        _ = journal.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(0))

        let events = journal.observe(LiveRecordings(rules: [F.rule("g")], scheduled: [failing]), dvr: F.dvr(), now: F.at(40))

        #expect(events.map(\.kind) == [.failed] && events[0].title == "Recording failed")
        #expect(events[0].body == "Show · 7.1 WABC. Plex couldn't record this airing.")
        #expect(journal.history.map(\.outcome) == [.failed] && journal.history[0].reason == "Plex couldn't record this airing.")
        #expect(journal.observe(LiveRecordings(rules: [F.rule("g")], scheduled: [failing]), dvr: F.dvr(), now: F.at(50)).isEmpty)
        var deadTuner = F.dvr()
        deadTuner.devices[0].isAlive = false
        var other = RecordingJournal()
        _ = other.observe(LiveRecordings(), dvr: deadTuner, now: F.at(0))
        _ = other.observe(LiveRecordings(scheduled: [failing]), dvr: deadTuner, now: F.at(40))
        #expect(other.history.first?.reason == "The tuner wasn't responding.")
    }

    @Test func aRecordingThatDisappearsBeforeItsEndStoppedEarly() {
        var journal = RecordingJournal()
        let grabs = [F.grab("g", status: .inprogress, from: 0, to: 60, title: "Show")]
        _ = journal.observe(LiveRecordings(scheduled: grabs), dvr: F.dvr(), now: F.at(1))

        let events = journal.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(20))

        #expect(events.map(\.kind) == [.failed] && events[0].title == "Recording stopped early")
        #expect(journal.history.map(\.outcome) == [.stopped])
    }

    @Test func anAiringThatVanishedIsSkippedOrMissedWithTheReason() {
        var journal = RecordingJournal()
        let one = F.grab("one", channel: "a", from: 100, to: 160)
        let two = F.grab("two", channel: "b", from: 130, to: 190)
        let busy = LiveRecordings(rules: [F.rule("one"), F.rule("two")], scheduled: [one, two])
        _ = journal.observe(busy, dvr: F.dvr(), now: F.at(0))

        _ = journal.observe(LiveRecordings(rules: [F.rule("one")], scheduled: [one]), dvr: F.dvr(), now: F.at(10))
        let skipped = journal.history.first
        _ = journal.observe(LiveRecordings(rules: [F.rule("one")], scheduled: [one]), dvr: F.dvr(), now: F.at(20))
        _ = journal.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(120))

        #expect(skipped?.outcome == .skipped && skipped?.reason == "Another recording was using the only tuner at that time.")
        #expect(journal.history.map(\.outcome) == [.missed, .skipped])
        #expect(journal.history[0].reason == "Plex didn't start this recording.")
        var late = RecordingJournal()
        _ = late.observe(LiveRecordings(scheduled: [one]), dvr: F.dvr(), now: F.at(0))
        #expect(late.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(200)).isEmpty && late.history.isEmpty)
    }

    @Test func skippingInTheAppIsNotReportedTwice() {
        var journal = RecordingJournal()
        let one = F.grab("one", from: 100, to: 160)
        _ = journal.observe(LiveRecordings(scheduled: [one]), dvr: F.dvr(), now: F.at(0))

        journal.noteSkipped(one, at: F.at(5))
        _ = journal.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(10))

        #expect(journal.history.map(\.reason) == ["You skipped this airing."] && journal.history.first?.outcome == .skipped)
    }

    @Test func historyIsCappedAndSurvivesEncoding() throws {
        var journal = RecordingJournal()
        _ = journal.observe(LiveRecordings(), dvr: F.dvr(), now: F.at(0))
        let grabs = (0..<60).map { F.grab("g\($0)", status: .error, from: 30, to: 90) }
        _ = journal.observe(LiveRecordings(scheduled: grabs), dvr: F.dvr(), now: F.at(40))

        let copy = RecordingJournal.decoded(journal.encoded())

        #expect(journal.history.count == 50 && copy == journal)
        #expect(RecordingJournal.decoded(nil) == RecordingJournal() && RecordingJournal.decoded(Data("nope".utf8)) == RecordingJournal())
    }

    @Test func aOneOffForAnotherEpisodeExplainsWhyTonightsShowIsNotRecorded() {
        let rule = F.rule("k", type: 4, title: "Jimmy Kimmel Live!")
        let recordings = LiveRecordings(rules: [rule], scheduled: [
            F.grab("k", from: 1_440, to: 1_500, title: "Jimmy Kimmel Live!", episodeTitle: "Old Show", guid: "plex://episode/old"),
        ])
        let tonight = F.airing(guid: "plex://episode/tonight")
        let journal = RecordingJournal()

        let entries = journal.entries(recordings: recordings, guide: [tonight], now: F.at(0))

        #expect(entries.count == 1 && entries[0].outcome == .skipped && entries[0].title == "Jimmy Kimmel Live!")
        #expect(entries[0].reason == "This rule only records “Old Show”. This airing is a different episode, so it isn't recorded. "
            + "Edit the rule and choose New Episodes to record it.")
        #expect(journal.entries(recordings: recordings, guide: [F.airing(guid: "plex://episode/old")], now: F.at(0)).isEmpty)
        let scheduled = LiveRecordings(rules: [rule], scheduled: recordings.scheduled + [F.grab("t", channel: "aaa-0701", from: 120, to: 180)])
        #expect(journal.entries(recordings: scheduled, guide: [tonight], now: F.at(0)).isEmpty)
    }
}

struct RecordingStorageTests {
    @Test func theLineSaysWhatIsUsedAndThatFreeSpaceIsUnknown() {
        let storage = RecordingStorage(usedBytes: 41_200_000_000, recordedSeconds: 244_800)

        #expect(storage.line == "Recordings use 41.2 GB, about 68 hours of video. Plex does not report free space, so how many hours are left cannot be shown.")
        #expect(RecordingStorage(usedBytes: 999, recordedSeconds: 0).line.hasPrefix("Recordings use 999 bytes."))
        #expect([RecordingStorage.format(bytes: 2_000_000_000), RecordingStorage.format(bytes: 1_300_000_000_000)] == ["2 GB", "1.3 TB"])
    }
}

struct RecordingsPlexTests {
    typealias F = RecordingsFixtures

    @Test func grabsAndSettingsKeepWhatPlexSays() async throws {
        let (live, _) = LiveTVTests.live { request in
            switch request.url.path {
            case "/media/subscriptions/scheduled":
                container(["MediaGrabOperation": [[
                    "id": "g1", "mediaSubscriptionID": 4, "status": "scheduled",
                    "Metadata": [
                        "type": "episode", "title": "Tonight", "grandparentTitle": "Jimmy Kimmel Live!", "originallyAvailableAt": "2027-01-15",
                        "Media": [["beginsAt": LiveFixtures.seconds(30), "endsAt": LiveFixtures.seconds(90), "channelIdentifier": "aaa-0701"]],
                    ],
                ]]])
            case "/media/subscriptions/template":
                container(["SubscriptionTemplate": [["MediaSubscription": [[
                    "parameters": "hints%5Bguid%5D=x", "type": 4, "title": "This Episode",
                    "Setting": [["id": "startOffsetMinutes", "type": "int", "value": "0", "default": "2"],
                                ["id": "recordPartials", "type": "bool", "value": false, "default": false]],
                ]]]]])
            default: nil
            }
        }

        let grab = try #require(try await live.scheduled().first)
        let option = try #require(try await live.recordOptions(F.airing()).first)

        #expect(grab.originallyAvailableAt == "2027-01-15" && grab.title == "Jimmy Kimmel Live!")
        #expect(option.setting("startOffsetMinutes")?.defaultValue == "2" && option.setting("recordPartials")?.defaultValue == "false")
    }

    @Test func movingARuleSendsAfterAndFirstPlaceSendsNone() async throws {
        let (live, transport) = LiveTVTests.live()

        try await live.move(F.rule("42"), after: F.rule("41"))
        try await live.move(F.rule("43"), after: nil)

        let first = try #require(await transport.requests(to: "/media/subscriptions/42/move").first)
        #expect(first.method == .put && first.url.query("after") == "41")
        let second = try #require(await transport.requests(to: "/media/subscriptions/43/move").first)
        #expect(second.method == .put && second.url.query("after") == nil)
    }

    @Test func storageAndLibrariesComeFromTheProviderAndTheSections() async throws {
        let (live, transport) = LiveTVTests.live { request in
            switch request.url.path {
            case "/media/providers":
                container(["MediaProvider": [["identifier": "com.plexapp.plugins.library", "Feature": [[
                    "type": "content",
                    "Directory": [
                        ["id": "2", "storageTotal": 41_200_000_000, "durationTotal": 244_800_000],
                        ["id": "1", "storageTotal": 9_000_000_000, "durationTotal": 3_600_000],
                    ],
                ]]]]])
            case "/library/sections":
                container(["Directory": [
                    ["key": "2", "title": "TV Shows", "type": "show", "Location": [["id": 3, "path": "/tv"]]],
                    ["key": "1", "title": "Movies", "type": "movie", "Location": [["id": 9, "path": "/movies"]]],
                    ["key": "7", "title": "Music", "type": "artist"],
                ]])
            default: nil
            }
        }

        let storage = try await live.storage(for: [F.rule("1", settings: []).withLibrary(2)])
        let libraries = try await live.recordingLibraries()

        #expect(storage == RecordingStorage(usedBytes: 41_200_000_000, recordedSeconds: 244_800))
        #expect(try await live.storage(for: [F.rule("2")]) == nil)
        #expect(await transport.requests(to: "/media/providers").first?.url.query("includeStorage") == "1")
        #expect(libraries == [
            RecordingLibrary(id: 2, locationID: 3, title: "TV Shows", kind: .show),
            RecordingLibrary(id: 1, locationID: 9, title: "Movies", kind: .movie),
        ])
    }

    @Test func switchingRecordsTheOtherAiringFirstThenDropsTheOldOne() async throws {
        let (live, transport) = LiveTVTests.live()
        let oneOff = F.rule("4", type: 4)
        let grab = F.grab("g1", rule: "4", from: 100, to: 160)
        let later = LiveAiring(id: "alt", channelKey: "aaa-0201", guid: "plex://episode/news12", title: "Evening News", start: F.at(400), end: F.at(460))

        try await live.switchRecording(grab, to: later, in: LiveRecordings(rules: [oneOff], scheduled: [grab]))

        let sent = await transport.requests.filter { $0.method != .get }.map { "\($0.method.rawValue) \($0.url.path)" }
        #expect(sent == ["POST /media/subscriptions", "DELETE /media/subscriptions/4"])
        let (series, seriesTransport) = LiveTVTests.live()
        try await series.switchRecording(grab, to: later, in: LiveRecordings(rules: [F.rule("4")], scheduled: [grab]))
        let seriesSent = await seriesTransport.requests.filter { $0.method != .get }.map { "\($0.method.rawValue) \($0.url.path)" }
        #expect(seriesSent == ["POST /media/subscriptions", "DELETE /media/grabbers/operations/g1"])
    }

    @Test func recordingAlertStateStaysOutOfTheBackup() {
        #expect(BackupScope.phone.classify(store: BackupScope.Phone.defaults, key: "marquee.recordings.journal") == nil)
        #expect(BackupScope.phone.classify(store: BackupScope.Phone.defaults, key: "marquee.recordings.alerts") == nil)
    }
}

private extension RecordingRule {
    func withLibrary(_ id: Int) -> RecordingRule {
        var copy = self
        copy.targetLibrarySectionID = id
        return copy
    }
}
