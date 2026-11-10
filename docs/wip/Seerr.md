# Seerr integration handoff

The Seerr branch includes discovery, search, title details, requests, settings, fake-service fixtures and UI coverage. Requests use the active Plex profile or the configured API key; session cookies are scoped to the saved address and profile. A duplicate request refreshes the title and request list.

The fake server serves Seerr and TMDB fixtures without contacting a real service. Integrate this branch with the rest of the batch before running the combined iOS build and simulator UI suite. The iOS build, simulator appearance and request flows remain unverified on this branch.
