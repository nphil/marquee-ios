Downloads are implemented in the core, app and player, with FakePlex fixtures and UI coverage. The combined build and device behavior remain unverified.

Originals use file byte ranges. High, Medium and Low are sized per title from HomeLabber's quality map or an estimate, and stream the server's HLS conversion segment by segment into one `.ts`; the Plex download queue makes them when the server will not stream. Downloads are scoped by server and profile.
FakePlex UI-test launches use isolated temporary download storage. The small media fixture exercises the download and player hand-off, not video decoding.
