# Design review, 7 November 2026

A second pass over the iPhone build against DESIGN.md and the reference apps, from the CI screenshots of main at f3932e5: portrait at 402 pt in Rosé Pine and Dawn, accessibility size 2 with Increase Contrast, and landscape. Ranked by impact.

1. **High: the detail hero was a thin strip.** The 16:9 backdrop started at the top of the screen, so the status and navigation bars covered its top third, and its fade began at 55%: about 60 pt of clear art showed, and the title sat on 68% canvas where §5.3 asks for 85%. `App/Browse/DetailView.swift`, `DetailHero`. Fixed: the backdrop starts below the bars, whole; a blurred mirror of its top edge fills the bars; the fade is eased and reaches 85% where the title starts.
2. **Medium: format chips looked like controls.** "4K", "Dolby Vision" and "Atmos" used the capsule, outline and near-same type as the Version and Season menus under them, so they read as tappable. `App/DesignSystem/Chips.swift`, `Chip`. Fixed: small Caption Semibold badges in ink2.
3. **Medium: cast without photos was a row of identical silhouettes.** `CastShelf` in `DetailView.swift`. Fixed: the person's initials on the placeholder fill.
4. **Medium: in landscape the tab bar covered Continue Watching.** The cards were 42% of the width, so each title and its time left sat under the floating bar at rest. `App/Screens/HomeView.swift`, `cardWidth`. Fixed: a third of the width.
5. **Low: a rating with no format chips stood alone on its own line** (every show). Fixed: the rating ends the meta line.
6. **Low: in landscape the tab bar covers the top of the Version menu on a movie.** It is the first row below the fold, and the bar tucks away on scroll in Home and Library. Unchanged.
7. **Low: the Library's Jump To menu shows `textformat.abc`,** which reads as the word "Abc" beside the View menu. It is the accessible twin of the A–Z rail. Unchanged.
8. **Low: episode synopses are Caption (12 pt),** small for the only prose in the row. Unchanged.

Grey art tiles in the screenshots are the trackOff fill of art still loading when the shot was taken (§11), not missing art. Sign-in, the PIN pad, server and profile lists, Settings and its pages, empty Search and the Watchlist title that is not on the server hold up against §8 and the reference apps.
