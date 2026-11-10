# Seerr — resume here

1. Done: Core `Packages/MarqueeCore/Sources/MarqueeCore/Seerr/` (Seerr.swift models/config/errors, SeerrClient.swift with cookie jar + CSRF + re-sign-in, SeerrRules.swift badges/seasons/requestability/Play link/Watchlist note/TMDB images), `PlexHTTPResponse.headers`; 19 tests in `SeerrTests.swift` pass on Linux.
2. Next: App: `App/Settings/SeerrView.swift` (SeerrSettings like BazarrSettings, Keychain session tied to profile uuid), SessionStorage keys, AppSession wiring (`session.seerr`, launch arg `-marquee.uitest.seerr`), Settings row.
3. Then: `App/Screens/RequestsView.swift` (Discover shelves, Search, My Requests), `SeerrTitleView` (Request/seasons/4K/Play/Watchlist note), `Route.seerrTitle`, FakePlex `seerr*` fixtures, UI test, docs (DESIGN/ARCHITECTURE/core-api).
4. Decisions: App URL session for Seerr must not handle cookies (client keeps its own); badges from media status (+ latest request for declined/failed); Play only when Seerr's ratingKey is on the signed-in server (or verified by TMDB id); Watchlist note when Pulsarr toggle on or Seerr auto-request permission.
5. Rules: never push main; "[skip ci]" in every commit; land by squashing, rebasing on origin/batch, pushing HEAD:batch, then message AppChrome.
