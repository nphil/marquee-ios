Downloads are implemented in the core, app and player, with FakePlex fixtures and UI coverage. The combined build and device behavior remain unverified.

Server conversions use the Plex download queue; originals use file byte ranges. Downloads are scoped by server and profile.
FakePlex UI-test launches use isolated temporary download storage. The small media fixture exercises the download and player hand-off, not video decoding.
