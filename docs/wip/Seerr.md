# Seerr — resume here

1. Done: design settled (Core folder `Packages/MarqueeCore/Sources/MarqueeCore/Seerr/`: config, client with cookie jar + CSRF, models, badge/request/play rules; App: Settings › Integrations › Seerr page, Requests page in BrowseStack, `Route.seerrTitle`, FakePlex `seerr*` host fixtures). No code written yet.
2. Next: write Core (SeerrConfig/SeerrClient/SeerrModels/SeerrRules) + tests in `Tests/MarqueeCoreTests/SeerrTests.swift`, run `swift test --filter Seerr`.
3. Then App: `App/Settings/SeerrView.swift` (SeerrSettings like BazarrSettings), `App/Screens/RequestsView.swift`, title page, AppSession wiring (`session.seerr`, launch arg `-marquee.uitest.seerr`), FakePlex fixtures, UI test.
4. Decisions: Plex sign-in posts the profile's Plex token to `/api/v1/auth/plex`, cookie kept in Keychain tied to the profile uuid; badges from media status (+ latest request for declined/failed); Play only when Seerr's ratingKey is on the signed-in server; Watchlist note when Pulsarr toggle on or the user has Seerr auto-request permission.
5. Rules: never push main; no GitHub CI per branch (Main runs one); land by rebasing on origin/batch and pushing HEAD:batch, then message AppChrome.
