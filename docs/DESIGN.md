# Marquee iOS: design direction

**Answer first.** Marquee iOS is a calm, poster-first Plex client for iPhone. Apple's Liquid Glass (the see-through, blurred look of iOS 26 and 27) draws the bars, buttons and sheets. Marquee draws what sits inside them: posters, Manrope headings and 40 colour themes (20 dark, 20 light; Rosé Pine is the default). Every colour comes from one file, `themes.json`, and one script, `check_themes.py`, proves each theme is readable.

Status: the design direction behind the built app. The themes are checked by script in CI (§5.5) and the screens by UI-test screenshots in CI (§13); playback, gestures and heat are checked by hand on a device (`docs/DEVICE-TEST.md`).

Companion files: `behaviour-spec.md` (plain-words behaviour, cited as `B:`), `Resources/themes.json` and `tools/check_themes.py`. Citations below to `stashy-playbook.md` and `videoengine.md` refer to notes that are not in this repo.

Citation key:

- `L:n`: Lucent `LANGUAGE.md` line n; `T:key`: Lucent `tokens.json` (both in `/data/agent/managed-skills/design-language/languages/lucent/`).
- `S:path:n`: Stashy line n, under `/data/home/Stashy/ios/Stashy/`. Stashy is Nitin's own code and reusable.
- `I:n`: `/data/home/.agents/skills/impeccable/reference/ios.md` line n.
- `B:§n`: `behaviour-spec.md` section n. `C:n`: `check_themes.py` line n.
- `W26-251` and similar: Apple WWDC sessions; URLs in §14. `[INFERENCE]`: not verified.
- Clean room: no PlxNative or Marquee TV code was read or used. Behaviour comes only from `B:`.

## 1. The short version

- **Tabs:** Home, Library, Live TV, Watchlist and Search by default; each place can be switched off or moved, up to five tabs, and one that is not a tab opens from another page. Settings opens from the profile button on Home. System tab bar, system back swipe, system sheets.
- **Home:** one large Continue Watching card, then poster shelves. Posters carry the colour; everything else stays quiet.
- **Detail:** art that melts into the page, the title in Manrope, one wide Play button (it reads Resume on a part-watched title).
- **Player:** full-screen video. Controls fade after 3 seconds; one tap brings them back. Audio and subtitles share one native menu with plain track names.
- **Themes:** 40, chosen in Settings and applied instantly. By default the app follows the iPhone's light/dark setting: Rosé Pine Dawn by day, Rosé Pine at night.
- **Text size:** follows the iPhone's setting up to the largest accessibility sizes. Layouts reflow; nothing overlaps.
- **Proof so far:** 40 of 40 themes pass every required contrast rule, and no two themes of one mode are recolours of each other (§5.5).

### 1.1 Decisions already made (each is cheap to change)

| # | Decision | Why | Cost to change |
|---|---|---|---|
| 1 | Tabs by default: Home, Library, Live TV, Watchlist, Search, each changeable in Tab Bar (§7); Settings is a sheet from Home's profile button | `B:§1` lists these destinations; Lucent allows 3 to 5 (`L:160`) | one default |
| 2 | "Match system appearance" is on by default | Apple expects both appearances to be supported (`W26-251`); `I:31` | one default |
| 3 | Every player control is a 56 pt circle; play/pause is marked by a solid white fill, not by size | Lucent: one button size per screen (`L:381`) | one size |
| 4 | Hero title 34 pt, not Lucent's 48 | A long film title takes about 4 lines at 48 pt and about 3 at 34 pt on a 390 pt screen [INFERENCE: estimated from average glyph width] | one size |
| 5 | Theme is saved per device, not per Plex profile | It is a look, not a viewing preference (`B:§1` saves settings per profile) | one key |
| 6 | Skip step defaults to 10 s | Stashy's value (`S:Features/Player/PlayerControlsView.swift:191-200`); the TV default is unconfirmed (`B:§0`) | one setting |
| 7 | Playback-speed menu in the More menu, 0.5x to 2x | `B:§0` lists it for the TV app; each new item starts at Normal | one menu |

## 2. Product context (inferred)

No PRODUCT.md interview was possible. This section is inferred from the brief, Lucent, Stashy and `B:`.

- **Purpose.** Watch the household's own Plex movies and TV on an iPhone: resume fast, find something quickly, get audio and subtitles right.
- **People.** Nitin and the household, each a Plex Home profile. Couch, one hand, dim room; sometimes daylight.
- **Personality.** Composed, cinematic, unhurried.
- **Anti-references.** A website in an app shell. Autoplaying trailers beyond the one hero preview the TV has (Settings turns it off) and busy carousels. Glass on everything. A dense Plex Web clone.
- **Principles.**
  1. Posters are the colour; chrome recedes (`L:382`).
  2. The system owns navigation; Marquee owns content, type and tint (`W26-251`, `I:5`).
  3. Every screen answers "what do I watch next?".
  4. Honest states: last good data, real reasons, no fake progress (`L:287`, `L:300`).
  5. Quiet motion; the room is dark.

## 3. Mode, scene and visual world

- **Mode:** Operate (get the person to a film fast), with Experience-leaning moments: the detail hero and the player.
- **Scene:** an evening on the couch, phone in one hand, lights low. One thumb, no glare, no animation for its own sake, no audio from the app until play is pressed, save the hero trailer and a show's theme tune, each with a switch in Settings.
- **Colour strategy:** Restrained. A tinted near-black (or soft paper) canvas, one accent on at most about 10% of a screen, and poster art as the only large colour. Dark is the first design target; light gets equal verification (`I:31`).
- **Signature:** Manrope headings; a 1 pt lit rim on panels; the theme as personality; poster-first shelves with very little text.
- **Craft floor:** no kicker lines above headings, no gradient text, no side stripes, no card inside a card, no hard offset shadows, no emoji or Unicode icons (SF Symbols only), no decorative glass. Gradients exist only as functional fades behind text (hero, player).

### 3.1 Borrowed from other media apps, and avoided

Patterns only, from the best-rated iPhone media apps: no assets, logos or trade dress.

- **Apple TV app.** Borrow: wide Continue Watching cards with the progress under the art, the profile button at the top of Home, the zoom from a tapped poster into a detail page whose backdrop runs under the status bar. Avoid: autoplaying previews (the room is dark and quiet, and Lucent's phone profile has no motion previews, `L:160`) and store shelves mixed into owned titles.
- **Infuse.** Borrow: technical honesty on the detail page: format chips read from the file, a Version menu only when there are several files, the full audio and subtitle lists with codecs. Avoid: walls of coloured badges; one row of solid chips is enough.
- **Netflix.** Borrow: shelf rhythm (one poster size per shelf, the next poster peeking), skeletons shaped like the page they become, results that change while typing. Avoid: a billboard hero that pushes Continue Watching off the first screen, autoplay, rank badges over the art.
- **Plex.** Borrow: the server's own hubs in its order, the library switch in the title menu, an A–Z jump, Unwatched as a filter. Avoid: streaming and Discover titles mixed into the library, nested sort and filter screens (one View menu replaces them).
- **Channels.** Borrow: plain episode rows that scan fast (still, number and name, runtime, air date) and swipe to mark watched. Avoid: guide-grid density on a phone.
- **Letterboxd.** Borrow: the detail hierarchy: backdrop, title with one meta line, a synopsis that expands, cast as round photos, related titles as a shelf. Avoid: the social layer (reviews, friends' ratings, lists).

Apple TV and Netflix tint a page with colour taken from its artwork. Marquee does not: each theme's contrast is proved against its own roles (§5.5), and a colour taken from a poster would void that proof on every page. The art stays the only large colour and the hero fades into the theme's canvas.

## 4. Phone profile

### 4.1 Layout and touch

| Token | Value | Source |
|---|---|---|
| Reference size | 390 × 844 pt; reflows at narrower widths and at the largest text | `T:profile.phone`, `L:160` |
| Columns, gutter | 4 columns, 12 pt gutter | `T:profile.phone` |
| Screen inset | 16 pt plus the safe area, never instead of it | `L:134` |
| Space scale | 4, 8, 12, 16, 20, 24, 32, 40 | `L:132` |
| Touch target | 48 pt (Apple's floor is 44) | `T:target.min`, `I:20` |
| Row height | 56 pt minimum | `L:160` |
| Shelf spacing | 32 pt between shelves, 12 pt from header to content | derived |
| Poster | 2:3. Shelf poster 104 pt wide (three and a peek of the fourth at 390). Grid: adaptive, minimum 104 pt: 3 columns at 390 and 375, 2 at 320 | derived |
| Continue card | 16:9, about 82% of the screen width | derived |
| Safe areas | Text and controls stay inside. Canvas, hero art and video bleed to the edges. In landscape the notch side keeps its inset | `I:13` |
| Effects tier | T1: system glass on navigation only, flat fills in content, no per-cell blur, no autoplay previews. T0 (opaque fills, crossfades only) under Reduce Transparency, Reduce Motion or Low Power Mode | `L:154,160,402` |

### 4.2 Radii

| Token | pt | Use |
|---|---|---|
| sheet | 28 | custom panels over video |
| card | 24 | Continue card art, Up Next card, glass panels |
| tile | 20 | art whose short side is 96 pt or more (posters, backdrops in grids) |
| row | 18 | custom list rows (system inset-grouped rows stay system) |
| control | 14 | art with a short side under 96 pt (episode stills, search thumbnails), text fields |
| pill | 999 | buttons, chips, badges |

Inner radius = max(outer radius − inset, 6) (`L:132`). System bars, sheets and buttons keep their own shapes.

### 4.3 Type

Manrope for display and titles; the system font (SF) for everything else (`L:111`, `I:25`). Manrope ships as Medium 500 and SemiBold 600 (Lucent's label and title weights, `L:111`) plus Bold 700, used only when Bold Text is on. Sizes are at the default Large setting and scale with the iPhone's text size.

| Role | Lucent phone | Marquee | Scales as | Face | Use |
|---|---|---|---|---|---|
| display | 48 | 34 | Large Title (capped at accessibility 3) | Manrope Medium, tracking −0.02 em, line 1.0 | large titles, detail hero title |
| title | 24 | 24 | Title 2 | Manrope SemiBold, tracking −0.01 em, line 1.25 | shelf headers, sheet and page titles, empty-state titles |
| headline | none | 17 | Headline | SF Semibold | row titles, button labels |
| body | 16 | 17 | Body | SF Regular, line 1.45 | synopsis, descriptions |
| label | 14 | 15 | Subheadline | SF Medium, line 1.3 | meta lines |
| caption | 12 | 12 | Caption 1 | SF Regular, line 1.3 | poster titles, badges and format chips (Semibold), time stamps (floor 11, `I:26`) |

- Line heights and tracking follow Lucent (`L:113`); a hero title that wraps may need 1.1 [INFERENCE].
- Body and label take Apple's 17 and 15 so every Dynamic Type step matches the system. Apple's defaults at Large: Large Title 34, Title 2 22, Headline 17, Body 17, Subheadline 15, Caption 1 12; Body at accessibility 2 is 33, about 200% (HIG Typography).
- HIG: use Regular, Medium, Semibold or Bold, no light weights; custom fonts must scale with Dynamic Type, respond to Bold Text, and avoid truncation at large sizes (HIG Typography; `W26-251`).
- Time codes, remaining time and countdowns use tabular numerals (`L:113`).
- Lines stay under about 70 characters; important labels wrap; only secondary metadata truncates, with a full accessible name (`L:115`).

## 5. Themes

### 5.1 Model

One theme = Lucent's 20 colour roles (`L:85`) plus `id`, `name` and `mode`. Views read roles from one theme object; they never hold a hex value. `I:30` prefers the system's semantic colours; Marquee replaces them with theme roles on content and keeps system controls on system colours plus the accent tint. That is the price of 40 themes, which is why each theme proves its own contrast (§5.5).

| Role | Used on iPhone for |
|---|---|
| canvas | page background (opaque) |
| sheet | reading panels, custom overlays, grouped content (alpha about .91 over canvas) |
| scrim | dim behind custom overlays; a confirmation uses it at .97 or more (`T:scrim.hidesMin`, `L:103`) |
| glass, glassRaised | flat translucent fills for cards and raised controls; never per-cell blur |
| edge, edgeRaised | 1 pt lit rim on cards and panels. A highlight, not a boundary; field and chip outlines use ink2 |
| ink, ink2 | primary text; secondary text (still 4.5:1 or more) |
| ink3 | hints and disabled only, never information (2.68:1 on canvas in Dawn; lowest across themes 2.26, frost) |
| focus, focusInk | ring for Full Keyboard Access and Switch Control, selected rings, the scrubber thumb; text on a focus-filled element |
| trackOff | off and progress tracks: decoration, not a control boundary. Sliders and the scrubber use the readable track, ink mixed at .60 over the surface, which is 3:1 or more in all 40 themes (`L:98`, §5.5) |
| accent, accentInk | the one tint (an action or the current step); label on an accent fill |
| positive, warning, danger, info, live | meaning, never decoration (§5.2). `live` marks live sources (the Live TV guide's now line) |

### 5.2 Behaviour

- **Live switch.** One observable theme store; every view reads it, so a tap on a tile changes the whole app at once, never half old and half new (`L:94`). System parts follow the theme: colour scheme = the theme's `mode`, tint = `accent`. Same approach as Stashy (`S:Theme/Theme.swift:174`).
- **Match system appearance** (default on): two slots, Light (Rosé Pine Dawn) and Dark (Rosé Pine), each offering the 20 themes of its mode. Same pattern as Stashy: `S:Theme/Theme.swift:154-156,167,205-208`; `S:Features/Settings/SettingsView.swift:201-212`.
- **Bars stay translucent.** Only title and button colours come from the theme; an opaque themed bar "killed the native scroll-under-glass look" (`S:Theme/Theme.swift:233-236`).
- **Chips are solid, never glass**: glass on glass reads flat (`S:DesignSystem/FilterPill.swift:6-8`).
- **Tone means one thing** (`L:382`): danger = something is down or wrong; warning = slow or pending; info = ordinary news; positive = fine; accent = an action or the current step. Status always has an icon and words as well. Rating stars are ink2, not warning.
- **Poster art is never tinted by the theme** (`L:85`), and the theme is never derived from the art. That keeps every combination checkable.

### 5.3 Contrast, Increase Contrast, Reduce Transparency

Contrast is measured on composited colours: alpha laid over what is really behind it (`L:90-94`).

- **Text:** 4.5:1 for ink and ink2 on canvas and on sheet. **Non-text:** 3:1 for accent and focus against canvas (`T:contrast`).
- **Accent as text.** `accentText` is derived, not stored: the accent itself when it is 4.5:1 or more on canvas, otherwise the accent mixed toward ink in 5% steps until it is. Only Rosé Pine Dawn needs it (accent 3.47:1 becomes `#78658D`: 4.74:1 on canvas, 4.96:1 on the sheet). Tab labels, text buttons and links use `accentText`; fills and large glyphs use `accent`.
- **Increase Contrast** (iPhone setting): sheet and glass become opaque composites; ink2 is promoted to ink (ink is 8.99:1 or more on the opaque sheet, lowest fjord); edges rise to 3:1. No extra palettes (`L:92-93`).
- **Reduce Transparency:** translucent content fills resolve to opaque composites over canvas.
- **Over video:** glyphs and time codes are white on a black scrim of .55 or more (white against a pure-white frame behind that scrim: 4.76:1 at .55, 3.98:1 at .50). Panels use an opaque sheet; a translucent one fails the 4.5:1 check over a pure black or white frame in 9 themes (§5.5). Accent is never a thin line or glyph straight on the picture: 11 light themes have an accent under 3:1 against black (lowest snow 1.21, highest linen 2.88). Accent over video is a solid pill with an accentInk label.
- **Hero art:** the title sits where the art has faded to 85% canvas or more (ink on that fade: 6.59:1 or more).
- **Glass slider (iOS 27):** people can slide Liquid Glass between clear and opaque-tinted. Test the bars and the few custom glass buttons at both ends. Content fills do not follow it by design. [INFERENCE: first-beta reports only, §14.]

### 5.4 Rosé Pine: what follows the palette and what changed

Source: Lucent's palette file (`/data/agent/managed-skills/design-language/palettes/rose-pine/palette.json`, from rosepinetheme.com/palette). [INFERENCE: palette licence not checked; confirm before shipping the name and colours.]

- **Main (dark)** is the Lucent dark role set exactly.
- **Moon (dark)** has no role set in Lucent. It is built from the official Moon base colours with Main's recipe: canvas `#232136`, surface `#2A273F`, ink `#E0DEF4`, accent iris `#C4A7E7`, positive foam `#9CCFD8`, info pine `#3E8FB0`, warning gold `#F6C177`, danger and live love `#EB6F92`. (Main's info is foam, the same colour as its positive, so icons and words must carry the difference there.)
- **Dawn (light)** is the Lucent light role set with three changes, because the originals fail contrast:

| Role | Lucent | Marquee | Reason |
|---|---|---|---|
| accentInk | `#FFFFFF` | `#17131F` | white on iris `#907AA9` is 3.79:1; dark ink is 4.82:1 |
| focus, focusInk | `#FFFFFFF2`, dark | `#17131FF2`, `#FAF4ED` | a white ring on the cream canvas is 1.09:1 |
| warning | `#EA9D34` | `#BE7A0E` | 2.05:1 on canvas; now 3:1 or more |

Dawn's danger fill is `#B4637A`; accentInk on it is 4.36:1, so a custom danger button in Dawn sets its label Bold (large-text rule, 3:1). Confirmations use the system alert where possible.

### 5.5 Format and checker

`themes.json`: `{schema: "lucent-colour-roles/1", default: "rose-pine", roles: [20 names], themes: [{id, name, mode: "dark" or "light", colors: {20 roles}}]}`. Colours are `#RRGGBB` or `#RRGGBBAA`. There are no preview images: a picker tile is drawn from the roles. The app bundles this same file. CI runs `python3 -B tools/check_themes.py Resources/themes.json` (exit 0 on pass, 1 on a required failure) so a theme that fails breaks the build.

**Required rules**

- Schema: exactly 20 roles, unique ids and names, opaque canvas (`C:191`).
- Coverage: at least 20 dark and 20 light themes; `rose-pine`, `rose-pine-moon` and `rose-pine-dawn` present; default `rose-pine` (`C:47-49`).
- Contrast on composited colours, lowest value over all 40 themes (`C:50-53,117`): ink on canvas 10.60 and on sheet 9.13 (fjord); ink2 on canvas 4.60 (sand); ink2 on sheet 4.70, also at full opacity for panels over video (solar-day); ink on the hero fade 6.59 (fjord); accentInk on accent 4.82 (Dawn); accent on canvas 3.47 (Dawn); focus on canvas 9.30 (frost); the readable slider track (ink at .60) on canvas 3.49 and on sheet 3.60 (frost).
- Distinctness (`C:56-59,184`): hue is ignored. Every pair in a mode must differ by at least one tolerance in at least one of: canvas lightness (.03), canvas chroma (.02), surface step (.02), accent lightness (.06), accent chroma (.05), ink lightness (.03), ink chroma (.015), in OKLab units. A hue-rotated copy fails. Closest pairs now: dark lagoon~plum 1.16; light lavender~blush 1.18. The tolerances are a design choice, not a standard.

**Advisory notes** (printed, never fail): semantic roles 3:1 on canvas (none flagged); focusInk on focus (none); ink and ink2 on glass (none); ink on the .97 confirmation backdrop (none; lowest 10.71, frost); accent as small text (Dawn); accentInk on the danger fill (Dawn, 4.36); ink2 on a translucent sheet over a pure black or white frame (fjord and solar on white; sand, mint, sage, peach, lemon, solar-day and frost on black), which is why panels over video are opaque.

**Last run:** dark 20 of 20 pass, light 20 of 20 pass, required failures 0, distinctness violations 0, advisory 11 notes across 10 themes, `RESULT: PASS`.

### 5.6 Catalogue

Names are original. "Inspired" means a family resemblance only, with no endorsement and no copied palette: Fjord (Nord-like), Solar and Solar Day (Solarized-like). Rosé Pine, Moon and Dawn follow §5.4.

**Dark (20)**

| id | Name | Canvas | Accent | Character |
|---|---|---|---|---|
| `rose-pine` | Rosé Pine | `#191724` | `#A79BF5` | default; plum-black, lavender |
| `rose-pine-moon` | Rosé Pine Moon | `#232136` | `#C4A7E7` | softer and lighter; iris |
| `midnight` | Midnight Ink | `#020922` | `#6FADFD` | navy-black, azure |
| `noir` | Noir | `#000000` | `#E5E1D9` | true black (OLED), bone accent |
| `graphite` | Graphite | `#151618` | `#60E7B4` | neutral charcoal, mint |
| `hc-dark` | High Contrast Dark | `#000000` | `#FFD60A` | maximum contrast, yellow |
| `ember` | Ember | `#251109` | `#FC7A25` | warm brown, orange |
| `curtain` | Curtain | `#220109` | `#EBBD57` | velvet red-black, gold |
| `amber` | Amber | `#100A03` | `#FDAF23` | projector amber on near-black |
| `espresso` | Espresso | `#190C04` | `#7AC9BB` | coffee brown, teal |
| `forest` | Forest | `#000D05` | `#7DDA8C` | deep green-black, leaf |
| `moss` | Moss | `#151909` | `#C1E760` | olive-black, lime |
| `lagoon` | Lagoon | `#01232A` | `#FFA190` | teal-black, coral |
| `fjord` | Fjord | `#2B323D` | `#8DC4D8` | slate, ice blue (Nord-like) |
| `solar` | Solar | `#003039` | `#4DA6E9` | dark teal, cream ink (Solarized-like) |
| `indigo` | Indigo | `#16143F` | `#FD9FCB` | royal indigo, pink |
| `neon` | Neon | `#08011A` | `#2AE4F2` | ultraviolet black, cyan |
| `plum` | Plum | `#270E28` | `#FEC6A8` | aubergine, peach |
| `ash` | Ash | `#262421` | `#77BFFE` | warm grey, sky blue |
| `sakura` | Sakura | `#1B0F11` | `#F3A3BD` | dusky rose-black, blossom |

**Light (20)**

| id | Name | Canvas | Accent | Character |
|---|---|---|---|---|
| `rose-pine-dawn` | Rosé Pine Dawn | `#FAF4ED` | `#907AA9` | cream, iris; the default light |
| `paper` | Paper | `#FBFAF6` | `#2B50C7` | warm white, ink blue |
| `stock` | Stock | `#F2F2F7` | `#0863DC` | plain-iOS look, system blue |
| `snow` | Snow | `#FFFFFF` | `#1A1A1E` | pure white, monochrome |
| `sand` | Sand | `#F3E4CD` | `#A24112` | sandy cream, rust |
| `linen` | Linen | `#E0DED8` | `#4E5C26` | grey-beige, olive |
| `mint` | Mint | `#E3FAEF` | `#0B764D` | mint-white, green |
| `sage` | Sage | `#E3EBDD` | `#5A235A` | grey-green, plum |
| `sky` | Sky | `#EBF5FF` | `#1C64D7` | pale blue, blue |
| `overcast` | Overcast | `#C8D2DC` | `#1B3A6E` | blue-grey, navy; low glare |
| `lavender` | Lavender | `#EFE9FF` | `#502BB4` | pale violet, purple |
| `blush` | Blush | `#FFF6F8` | `#8E024D` | pale pink, berry |
| `peach` | Peach | `#FFDEC2` | `#046565` | peach, deep teal |
| `lemon` | Lemon | `#FDF6BF` | `#1A318A` | pale yellow, navy |
| `solar-day` | Solar Day | `#FFF6E1` | `#1B6CB0` | cream, blue (Solarized-like) |
| `stone` | Stone | `#D7D2C8` | `#8C2D2D` | warm grey, brick |
| `frost` | Frost | `#E7EDF5` | `#375F8F` | icy white, steel blue |
| `aqua` | Aqua | `#D8F5F7` | `#3B39A6` | pale cyan, indigo |
| `hc-light` | High Contrast Light | `#FFFFFF` | `#0033CC` | maximum contrast, blue |
| `dune` | Dune | `#E6D5B8` | `#1D5C63` | tan, deep teal |

## 6. Materials: Liquid Glass mapping

Apple's rule: Liquid Glass is the navigation layer, not the content layer; use regular glass for anything with text; use clear glass only over rich media with about 35% dimming (HIG Materials). Marquee follows the two-layer split (`W26-251`): the system draws the UI layer, Marquee draws the content layer.

| Lucent material (`L:52-59`) | On iPhone | How |
|---|---|---|
| Canvas, L0 | page background | `canvas` behind the scroll content, bleeding under the safe areas. Colour sits in the scroll content so system glass picks it up (`W26-251`) |
| Navigation layer | tab bar, navigation bar, toolbars, menus, alerts, partial sheets | System Liquid Glass, untouched. The theme supplies only tint and title colour. Never an opaque custom bar |
| Sheet, L1 | reading panels, grouped content | `sheet` fill (alpha about .91 over canvas) with a 1 pt `edge` rim. Partial system sheets keep the system glass (leave the sheet background unset); at full height iOS draws a sheet opaque (`W25-323`), so the content sits on `canvas` |
| Card, L2 | Up Next card, offline banner, grouped panels | `glass` flat fill, 1 pt `edge` rim, radius 24. Light themes add Lucent's soft rest shadow (2 pt offset, 4 blur, `L:61`). No blur, no card inside a card |
| Raised control, L3 | detail icon buttons, selected segment | `glassRaised` flat fill, or a system glass button |
| Well, L−1 | toggle and slider tracks | System controls tinted with accent; custom tracks use the readable track (§5.1) |
| Overlay, L4 | custom confirmations, panels over video, toasts | Opaque `sheet` (Lucent's floor is .96); a confirmation adds a `scrim` backdrop at .97 or more (`L:59,103,299`) |
| Picture | posters, hero art, video | Never tinted. Under text: a fade to canvas (hero) or a black scrim of .55 or more (player) |

- **Glass is counted by shapes, not buttons.** A cluster of buttons in one `GlassEffectContainer` is one shape; glass cannot sample other glass (`W25-323`). Content screens use at most 3 custom glass shapes; the player chrome at most 4 clusters.
- iOS 27 reportedly adds more defined glass borders in place of shadows, lighter dark glass, an ignored glass opt-out in Xcode 27 builds and a "hard" scroll-edge default (designfornative, 2026-06-10); Marquee's pages set their edge from the Header Style setting (§7.1). [INFERENCE: first-beta write-up; re-verify on the shipping release.]

## 7. Navigation model

- **Root:** a tab view of the tabs the person chose, by default Home, Library, Live TV, Watchlist and a Search tab in the search role (`W25-323`); built with the iOS 27 SDK the standard search tab sits in line with the others (`W26-292`). Settings is not a tab: the profile button at the top of Home opens it in a sheet, as in the Apple TV app.
- **Tabs** are a setting, Appearance › Tab Bar, after Apollo's: Home, Library, Live TV, Watchlist, Search, Requests (once Seerr is set up) and Downloads, each switched on or off and dragged into order (VoiceOver: Move Up, Move Down), at most five on the bar. Home stays a tab, as its profile button opens Settings, and Search stays last, where iOS draws the search tab. A place that is not a tab opens as the same page pushed onto the current tab: Live TV, Watchlist and Downloads from the Library's title menu; Search (its field ready to type) and Requests (`plus`) from buttons in the Library's header; every place off the bar from Home's title menu while the Library is off it too. Watchlist also gets a row on Home (§8.1) and a long press on Detail's bookmark (§8.3); Downloads a row in Settings (§8.7). A place that is switched on but unavailable, such as Requests without Seerr, leaves its slot to the others.
- **Tab bar on scroll** is a setting, Appearance › Tab Bar, after Apollo's: **Minimise on Scroll** (the default) shrinks the bar to the current tab while a page scrolls down (`tabBarMinimizeBehavior(.onScrollDown)`, `W25-323`); **Hide on Scroll** slides it away after 24 pt of scrolling down and brings it back after 24 pt up, within 32 pt of the top, and on every push or pop; **Always Show** keeps it. Search keeps the bar under every choice, as its results scroll while the keyboard comes and goes. Hide on Scroll follows only a browse page's main scroll view and only a finger or a fling: a programmatic scroll, a sheet or the player never moves the bar, the bar stays as it is within three touch targets of a page's end (its coming and going changes the bottom inset by up to about 90 pt), and VoiceOver keeps it shown so the tabs stay reachable. The slide is the `tabBar` motion (§9).
- **Each tab owns a navigation stack.** Detail pushes with a zoom transition from the tapped poster (`W26-251`); Reduce Motion makes it a 120 ms crossfade. The left-edge back swipe is never disabled or overlaid (`I:15`). No custom back buttons, no hamburger menu (`I:14`).
- **Player:** a full-screen cover (`I:39`). The way out is a swipe down on the picture, the Close button, or the VoiceOver escape gesture; none depends on the chrome being visible.
- **Sheets** hold short self-contained tasks: Settings, profile switcher (over Settings), version picker, tracks info. Settings, and the remote when Home Button opens it, zoom out of their button on Home and back into it (§9). Long tasks are full pages pushed inside the sheet (`L:160`). **Menus** hold short choices: sort, filter, season, tracks (with subtitle style), more. The player opens no sheet for subtitles (§8.6). **Confirmation dialog** for sign-out and removals. **Alert** only for blocking errors.
- **Search tab:** the standard variant (a landing page with recents), not the prominent variant that opens the keyboard at once (`W26-292`, `W26-269`).
- **Rotation and size:** browse screens work in every orientation [INFERENCE: WCAG 1.3.4]; the player turns as Video Orientation says (§8.6), with the phone by default, and in portrait the picture is letterboxed on black with the same chrome over it. Tabs become a sidebar in iPhone landscape (`sidebarAdaptable`) [INFERENCE: first-beta]. Layout uses size classes, layout margins and safe areas, never device or `UIScreen.main` checks, so resizable windows and the foldable iPhone Duo (on sale 2026-10-23; the inner display can be regular width) work (`W26-269`, Apple developer news 2026-10-05).
- **Bottom accessory:** the optional TV-remote mini bar appears only when its plugin is enabled, Mini Bar is selected and home presence is confirmed. Otherwise the accessory container is disabled, leaving no empty glass strip.

### 7.1 Headers

- **Titles:** the tab roots (Home, Library, Live TV, Watchlist, Search) and the Settings sheet carry a large leading title inside the bar (`toolbarTitleDisplayMode(.inlineLarge)`), so the header has one height and never collapses or moves as the page scrolls; pushed pages carry a centred inline title. A title that opens a menu (Library, Home) is a button with a chevron in the title slot: display size while the page is at the top, headline size once it has scrolled and the bar centres it, one line that truncates before the trailing buttons. Live TV pins its chips and time strip under the bar as one header with it (`safeAreaBar`, docs/LIVE-TV.md §6.4).
- **Header Style** is a setting, Appearance › Header Style, after Apollo's: the edge where the page meets the bar as it scrolls under it. **Soft** (the default) is the system's soft scroll edge, which fades the page out under the bar; **Hard** is the system's hard edge, an opaque band with a dividing line; **Blur** frosts the page under the status bar, the bar and anything pinned under it in ultra-thin material under half-strength `canvas`, solid behind the bars and fading out over 24 pt below them, and fades in over the first 24 pt of scrolling. Under Reduce Transparency Blur's band is solid `canvas`.
- Every list and grid page takes the chosen style (`scrollHeader()`), with two exceptions: partial sheets on system glass keep Soft, as Blur's band is drawn in the canvas, and the detail page keeps its hero under a clear bar on the soft edge (§8.3). Loading skeletons and the landscape Live TV grid keep the system edge.

## 8. Screens, in words

Every screen: a large title in the bar where top-level (§7.1), canvas behind, 16 pt insets, one button size, hints as glyphs with accessible names (`L:121-127`, `L:381`).

### 8.0 Sign-in and server choice (brief)

Sign-in is Plex's PIN flow: the button opens plex.tv in a browser sheet and the app polls the PIN; if the sheet cannot be used, the screen shows a 4-character code to enter at plex.tv/link. One screen: the Marquee mark, one Sign in button, nothing else. After sign-in, a server list: one 56 pt row per server (name, owner, a connection glyph with a word); choosing one is remembered; only the user's own servers are listed (`B:§1`). Empty: "No servers found" with Retry. A failed or expired sign-in has its own state (§11).

### 8.1 Home

1. **Large title** "Home" in the bar (§7.1). Trailing: the profile button, the profile’s photo at 36 pt in a 2 pt `accent` ring, 44 pt across (`Size.barButton`) and without the bar’s glass capsule, so the ring is its edge. It opens Settings in a sheet that zooms out of the button; the zoom's source is the button itself, clipped to a circle, because a bar item as the source cut the ring top and bottom on the way back. Switching profile is the first row there [INFERENCE: a protected profile may ask for a PIN]. When Home Button is selected for the enabled LumaTV remote and the phone is at home, a matching remote button stands before it and opens the remote in a sheet that zooms out of it the same way.
2. **Continue Watching** (hidden when empty, `B:§1`): a horizontal snap shelf of 16:9 cards, about 82% of the width so the next card peeks (33% from 600 pt wide, so a landscape card and its caption stay above the floating tab bar). Under each card, never over the art: a 3 pt progress bar (accent on `trackOff`), the title (Headline) and one line such as "S2 · E5 · 42 min left" in ink2 (the remaining time is the helpful context Apple asks for, `W26-250`). Tap resumes at once. Long-press opens a menu: Details, Mark watched, Remove from Continue Watching (with Undo).
3. **Hubs**, in server order, empty ones hidden (`B:§1`). Each is a title (Manrope SemiBold 24) with a trailing `chevron.right` (accessible name "See all …") over a poster shelf. Poster cell: 2:3 art, a 3 pt progress bar if part-watched, a one-line title (Caption). Badge on the art, top trailing: a solid canvas-coloured pill with ink text (unwatched episode count; a check for watched), never glass.
4. **Rows are the profile's choice.** Home shows the rows of Home Rows (§8.7) in its order: by default the server's Home hubs, with Continue Watching wherever it is placed. Long-press on a row's title (or its VoiceOver actions) offers Hide This Row (a toast with Undo) and Edit Home; Settings also opens Home Rows. With every row hidden the page is an empty state with Edit Home. Edit Home opens Home Rows in a sheet at half height, so Home above it follows each change.
5. **Places off the bar** (§7): while Watchlist is not a tab, a Watchlist row of its latest 20 titles follows Continue Watching (or leads without it), with See all when there are more; a long press removes a title from the watchlist. While the Library is not a tab either, the "Home" title is a menu of every place off the bar.
6. Pull to refresh.

### 8.2 Library

1. **Large title with a menu** in the bar (§7.1) to switch library ("Movies" with a menu chevron; each library row has a glyph by type, `film` for movies and `tv` for shows, beside the checkmark); below the libraries it lists Live TV, Watchlist and Downloads when they are not tabs. Toolbar: one View menu (sort, filter, unwatched only; every sort field and order row has a glyph, built as a checkmark toggle so the glyph and the checkmark both draw), led by Search (`magnifyingglass`) when Search is not a tab and followed by Requests (`plus`) when Requests is available and not a tab.
2. **Filter chips** appear under the title only while a filter is on: solid chips with `xmark`, full 48 pt hit height.
3. **Poster grid:** adaptive, minimum 104 pt, 12 pt gutters; 3 columns at 390. At large accessibility sizes: 2 columns, then 1.
4. **A–Z rail** on the trailing edge, only when sorted by title (`B:§1`): letters in Caption 2 Semibold, 16 pt apart. Touching it jumps letter by letter with a selection tick, and the letters around the finger swell and lean out over a lens, after Apollo's index but stronger, so the touched letter clears the thumb: the touched letter 3.6× and 46 pt out, its neighbours 2.5× and 32 pt, then 1.75× and 18 pt and 1.3× and 7 pt, the rest dimmed to 72%, blended between rows. The swollen letters part along the rail so that 4 pt of clear space stays between two capitals, and the rows beyond keep their 16 pt pitch. The lens is a `sheet` panel with an `edge` rim; the touched letter is `accentText`. Left of the lens, level with the finger and kept within the rail's height, a callout shows the touched letter in Manrope Bold 44 (Large Title, scaling to XXXL) in `accentText` on a square `sheet` panel with an `edge` rim and the card radius; it fades out after the finger lifts. Under Reduce Motion only the touched letter grows and nothing leans. VoiceOver and Switch Control adjust the rail a letter at a time, so it needs no separate menu.
5. Collections and Recommended (`B:§1`) are a system segmented control under the title (`L:269`).

### 8.3 Detail (movie or show)

```
+--------------------------------+
| <                              |   system back button on glass
|     backdrop art, 16:9         |
|     fades into the canvas      |
| Title, Manrope, up to 3 lines  |
| 2019  2 h 14 m  PG-13          |
| [4K] [HDR] [Atmos]             |
| [   Resume   42 min left   ]   |   Play pill, full width
| (bookmark) (check) (...)       |   round icon buttons
| Synopsis, three lines...    v  |
| Cast    (o) (o) (o) (o)        |
| Related [  ] [  ] [  ] [  ]    |
+--------------------------------+
```

1. **Hero:** the backdrop at its natural 16:9 ratio, full width, starting below the navigation bar so the bars hide none of it, fading to canvas over its lower half on an eased ramp that reaches 85% where the title starts (§5.3). Above it the art runs on to the top edge as a blurred mirror of its top rows, the `backgroundExtensionEffect` look (`W25-323`), so the page still bleeds under the status bar. No portrait crop, so faces are not cut. With no backdrop: the poster, blurred, as the fallback [INFERENCE]. In landscape a full-width hero would be taller than the screen, so the backdrop becomes a rounded 16:9 card on the leading half with the title block and actions beside it, and Play stays on the first screen.
2. **Title block** on the faded part: for an episode, the show's name above the title as the link to the show (title role in `accentText` with a trailing chevron, no pill), then the title (display; wraps up to 3 lines), a meta line in ink2 (year, runtime, content rating, then a star glyph and the rating), and solid format chips (4K, HDR, Atmos) as small Caption badges in ink2, so they never read as the Version or Season menus.
3. **Action row, one size (48):** a full-width **Play** pill in accent ("Play", or "Resume · 42 min left"; for a show "Play S1 · E1" or "Resume S2 · E5"), then round icon buttons: watchlist (`bookmark`), watched (`checkmark.circle`), More (`ellipsis`: Play from beginning, Version, Tracks, Share). Watched and watchlist apply at once with a toast and Undo (`L:365`). While Watchlist is not a tab, a long press on the bookmark offers Watchlist.
4. **Version** menu ("4K HDR · 12 GB" with a chevron) only when the title has more than one version.
5. **Synopsis:** Body, 3 lines, then a `chevron.down` to expand; capped near 70 characters per line.
6. **Tracks** row opens a sheet with the full audio and subtitle list in technical terms: codec, channels, PCM and Dolby chips, and image-format chips (PGS, VOBSUB) only on image subtitles (`B:§3`).
7. **Cast** (circular photos, 72 pt, Caption names; the person's initials where the server has no photo) and **Related** (poster shelf), when the server provides them.
8. The navigation bar is transparent at rest and gains glass as the page scrolls under it (`scrollEdgeEffectStyle`, `W25-323`).
9. **Watchlist** items that are not on the user's server open this same screen with no Play pill and one line, "Not on your servers" [INFERENCE: not in `B:`].
10. **Theme music:** a show's page and its seasons' play the show's theme tune from the server while the page is on screen, fading in over 1.5 s and out over 1 s (volume follows the gain squared, heard as an even fade). It waits while other audio plays, while the player holds the sound and while the trailer plays with sound; a trailer that starts while the tune plays stays muted. Covered by another page it pauses and resumes; after the player it starts over; it never repeats. It mixes with other apps and Silent mode silences it. Settings › Video & playback turns it off and sets its volume (50% by default).

### 8.4 Seasons and episodes (inside a show's detail)

1. **Season menu:** a pill "Season 2" with a menu chevron under the action row; the selected season has a check.
2. **Episode rows,** 56 pt minimum: a 16:9 still (128 × 72, control radius) with a 3 pt progress bar if part-watched; beside it the title "5 · Name" (Headline, wraps), runtime and air date (ink2) and two lines of synopsis (ink2). Trailing: a watched check and `ellipsis` (Mark watched or unwatched, Play from beginning, Details).
3. Tap plays and resumes (`B:§4`). Swipe actions mark watched or unwatched, each with Undo (`swipeActionsContainer` lets swipe actions work outside lists, `W26-269`).
4. At accessibility sizes the still moves above its text; nothing overlaps (`L:387`).
5. The unwatched count is total episodes minus watched (`B:§1`), shown on the show's poster and in the season menu rows.

### 8.5 Search (a tab)

1. **Search field** at the top of the landing page, always shown (the standard search tab, `W26-292`), prompt "Search your library": it searches only the user's own servers (`B:§1`).
2. **Landing (empty query):** recents inline, the last 4 kept (`B:§1`), swipe to remove, a Clear at the end (`W26-292`). Nothing else: no trending, no ads.
3. **Typing:** results as the text changes, grouped Movies, Shows, Episodes, People. A scope control under the field: All, Movies, Shows, Episodes (`W26-292`). Result row: a 56 × 84 poster, the title (Headline), "Movie · 2019" (ink2).
4. **No results:** the system no-results view with the typed text and the magnifier kept, one short line (`W26-292`).

### 8.6 Player

```
+---------------------------------------------------------------+
| (v)  Title                              S2 E5         (airplay) |
|                                                               |
|              (<<10)          (> / ||)          (10>>)         |
|                                                               |
| 0:42:10  =====================o--------------------  -1:03:22 |
|                                                (tracks) (...)  |
+---------------------------------------------------------------+
```

Round brackets are 56 pt glass buttons; the picture runs behind everything.

**Rules for a picture screen** (`L:248,296,404`)

- The picture is an AVPlayer layer; the chrome is custom, on the pattern Stashy already uses (`S:Features/Player/PlayerControlsView.swift`). It copies the system player's behaviour so it reads at once (HIG Playing video), keeps the video's original aspect ratio (HIG Playing video) and uses pure black bars. [INFERENCE: the Marquee-only offers below do not fit the system transport bar.]
- Chrome fades after 3 seconds without input, only while the picture moves: playing, not loading, waiting for data or landing a new stream, not scrubbing, with no menu open (the Stashy rule, `S:Features/Player/ScenePlayerView.swift:340-346`), and returns on the next touch. A still picture keeps the chrome whatever stopped it (a pause from the lock screen, a call, a lost route, a failed start, a new item), and a wait for a seek or a new stream brings it back after 2 seconds with the loading ring. Only a tap on the picture hides it from a paused frame, to look at the frame or zoom in; the next tap brings it back. While the picture loads or waits, a tap only shows the chrome.
- The first tap only reveals the chrome; hidden controls take no touch (`L:248`).
- The way out never depends on the chrome: swipe down on the picture, or the VoiceOver escape gesture. With VoiceOver or Switch Control on, the chrome stays visible.
- The chrome is always in the dark colour scheme, so glass over video stays dark in every theme. Panels that open from the player use the theme's own mode.
- Subtitles lift above the bottom chrome while it shows; they are never hidden behind it.

**Chrome** (one control size: 56 pt circles, `Size.control`; every glyph, AirPlay's included, 22 pt semibold, `Size.controlGlyph`, 40% of the circle; play/pause is a solid white fill with a dark glyph). Glyphs grow with Dynamic Type to 28 pt (`Size.controlGlyphMax`) and stop there; the circles keep 56 pt so the chrome fits a 375 pt-tall phone on its side, and past the cap a long press shows the large content viewer. The top row carries at most four controls and the bottom row at most five; everything else is in More. Icon-only controls keep their accessibility labels and a 44 pt target.

1. **Scrims:** black gradients, .55 or more at the very top and bottom edges, fading to clear. Glass clusters sit on them (clear glass over media with at least 35% dimming, HIG Materials).
2. **Top row:** Close (`xmark`, labelled "Close") leading; the title block in the middle (title, "S2 · E5" in white at 70%); trailing Picture in Picture (`pip.enter`, when the video allows it and nothing is cast) and the route button, as in Apple's own player (`airplayvideo`). The glyph is drawn like the others and turns accent while sound and picture go to a receiver; the system route picker lies over it, tinted clear, and takes the tap.
3. **Centre transport:** skip back (`gobackward.N`), Play/Pause, skip forward (`goforward.N`), with N from the skip setting (5, 10, 15, 30 or 60 s, `B:§4`; default 10). Glyph names to check in the SF Symbols app.
4. **Scrubber:** a 6 pt readable track (§5.1) with a 56 pt-tall hit area and a white thumb; elapsed time leading, remaining time trailing (Caption, tabular). Dragging shows, at touch-down and without a fade, a 224 pt, 16:9 scene thumbnail with the time under it, 12 pt above the thumb and centred on it; it is clamped 16 pt inside the safe area at both ends of the track. It ticks once per preview frame, and moving the finger away vertically slows the scrub (`S:Features/Player/PlayerControlsView.swift:513-534`). Intro and credits ranges from the server cut the track into segments, a 2 pt gap at each edge, with an accessible label (`B:§2`).
5. **Bottom row:** Restart (`backward.end.fill`), Episodes (`rectangle.stack`) and Next (`forward.end.fill`) leading, icon only, for episodes and queues (a movie has none of them); Tracks (`captions.bubble`) and More (`ellipsis`) trailing. Restart works as a music player's previous: the first press goes to the start of the episode; a second within 3 s, or a press in the first 3 s, goes to the previous episode (`PreviousPress`, label "Previous episode" while that is next). Next is dimmed with no target. The menus take the theme's ink as their tint.
6. **More menu:** three groups read top down, each row with its current value under its title and its list in a submenu: Quality (Auto, the default, shown with the rung playing, "Auto · 8 Mbps 1080p", or a fixed preset; docs/adaptive-playback.md) and Aspect (Fit, Fill, Original, Zoom, Stretch, `B:§4`); Speed and Audio Enhancements (Boost dialog, Normalize loudness; Plex Pass servers only); Playback Info and Stats for Nerds.
7. **Episodes panel,** from the Episodes button, over the playing video, which keeps playing and stays visible. On a landscape screen it is a compact panel on the trailing edge, about 40% of the width (340 pt at least), with rounded leading corners, closed by its Close button, a swipe right on it or a tap on the picture. On a portrait screen it is a half-height sheet (large on drag) with a drag indicator, and the picture above it stays live. On the panel the content runs to the screen's edge on the side away from the Dynamic Island and keeps clear of the safe inset on the side that holds it (the panel grows by that inset, so the content keeps its width); the header has no divider. Either way the header is pinned above the list: the season menu (the season's name when the show has one) and Close, so changing season never needs a scroll up. A lazy list of episode rows follows as in 8.4; the playing episode carries a raised-glass fill, an accent edge and an animated "Now playing" glyph (still under Reduce Motion), and is scrolled into view once the list loads. Stills of the next six rows are prefetched. At accessibility sizes the larger still moves above its text.

What moved where when the chrome went to three controls per edge:

| Control | Was | Now |
|---|---|---|
| Picture in Picture | top row | More, then top row beside the route button |
| Previous, Episodes, Next | bottom row, leading | More, then bottom row, leading, icon only |
| Boost dialog, Normalize loudness | Tracks › Audio | More › Audio Enhancements |
| AirPlay glyph | the route picker's own, smaller and lighter | the player glyph |
| Glyph size | 26 pt, fixed | 22 pt, scaling to 28 pt |

On its side the phone has no top safe area, so the rows keep 16 pt from the top and bottom edges (8 pt upright, where the safe area adds to it) and 16 pt beyond the side safe areas.

On the smallest iPhones (375 × 667 pt), upright, the top row leaves the title 207 pt (139 pt before), the bottom row's two buttons take 124 of 343 pt (328 before), and the transport takes 248 pt.

**Stats for nerds:** More › Stats for Nerds, or a long press on the title, lays a glass panel over the top leading corner, refreshed twice a second: the route and why, the server address (local, remote or relay, then its IP, read out of a plex.direct name, and the port when it is not 32400), file, video, picture (dynamic range and whether this iPhone decodes it in hardware), audio (copied or converted), subtitles; then display size, network, buffer, dropped frames and stalls, player errors, the remux lead or the server's transcode (speed, throttling, decisions, GPU), the stuck remux runs restarted (how many; the last one's place, cause and output in hand), heat and memory. Two columns in landscape. Only its Copy button takes touches, so the picture's gestures still work through it, and it sits under the chrome and offers, so the controls stay legible over it. Copy sits at the top beside the lines, where the transport and bottom row never cover it, even when large text runs the panel down behind them. Copy, and Playback Info's Copy Diagnostics, put the same lines on the clipboard with the engine's recent measurements and this iPhone's hardware report, for bug reports.

**Tracks menu:** one native menu, read top down. Everything for subtitles stays in it, over the picture, with no sheet or full-screen panel; audio opens from one row.

- **Subtitles** section: Off and the viewer's language (the subtitle setting, else English). That row puts the usual track on screen: the regular full track ahead of SDH and forced ones (`SubtitlePicker.usual`). With no track in that language it reads "None yet. Choose to find them." and runs Find Subtitles. A track on screen that neither row stands for, such as a forced track the file turned on, shows ticked under them. Other languages and the SDH and on-screen-text variants are not offered.
- **Audio** row, when the file has more than one track, with the playing track under it. Its submenu has one row per track, the language first and a plain channel word only where needed to tell rows apart ("English", "English, 5.1", "English (commentary)"); the wanted-language track is first and the playing one has a check. Codec names live only on the Tracks info sheet (`B:§3`).
- **Tools,** the last section: Find Subtitles in the viewer's language; Subtitle Style; Subtitle Timing, with the offset under it, while a subtitle the phone draws is on. Style and Timing dim, with the reason, while the server draws the subtitle into the picture.
- **Find Subtitles** is one action with no source or file to choose (`B:§3`). Bazarr, when set up, goes first and gets 20 s; Plex's own agents, asked at the same time, step in when Bazarr can't be reached, runs out of time or has nothing in the language. A banner over the picture names the source being asked, then the file put on screen and where it came from, or why nothing came. Asking again brings another file. Bazarr's providers took 15–18 s warm and 80–100 s cold per search (measured 2026-11), so the 20 s bounds the wait, not Bazarr.
- A subtitle generated on-device (iOS 27) carries `sparkles`. Apple's own example adds the word "Translated" to translated tracks; Marquee labels a track transcribed from the audio "Generated" [INFERENCE: Marquee's own wording]. Authored subtitles are preferred and rank first (`W26-256`). [INFERENCE: generated subtitles need the AVPlayer subtitle path; the video-engine plan serves text subtitles as WebVTT (`videoengine.md` §3.4), which should qualify.]
- **Style** is a submenu of the same menu: Look (the presets), Size, Colour, Position and Reveal as Spoken, each a submenu whose choices apply at once and keep the menu up, so the subtitles behind it show the change. The rest of the look is in Settings › Audio & Subtitles. Image subtitles (PGS, VOBSUB, DVB) take only Colour and Soften Brightness (`L:367`). Custom controls must offer subtitle choice (`W26-256`); this menu does.
- Track labels are "English", "English (dub)", "English (on-screen text)", "(commentary)"; "Track N" tells identical rows apart; no codec names or file titles in the subtitle rows (`B:§3`).

**Offers** (bottom trailing, one at a time, 220 ms in; not part of the auto-hiding chrome, they stay while their marker or wait lasts and take touch while visible)

- **Skip intro:** a solid accent pill, 56 pt tall (the one control size), accentInk label, with a thin countdown ring when auto-skip is on. Manual by default; "Watch intro" cancels auto-skip for that episode (`B:§4`).
- **Up Next:** at a credits marker with a queued next episode, an opaque-sheet card (poster, "S2 · E6 · Name", a countdown ring around a play glyph, a text button "Watch credits"). Pause, buffering, menus and input stop the countdown (`B:§4`). With Autoplay Next Episode off the card only waits for a tap; with Skip Credits Instantly there is no card and the next episode starts at the marker. An episode with no credits marker plays the next one when it ends, if autoplay is on (not after "Watch credits"). On a phone on its side the card covers the middle of the screen, so while it shows the transport steps aside: the card carries play, and "Watch credits" brings the transport back.
- **Play at lower quality:** at a fixed quality, after 10 s of waiting on the network in mid-play, an accent pill like Skip intro; it goes when the wait ends. Taken, playback goes on at the highest preset at or below half the rate playing now, for this playback only: More › Quality shows it, and picking a quality there lifts it. Not offered under Auto, which steps down by itself, or Force Direct Play.
- **End of item:** the last frame stays, the chrome stays, one line "Finished" with Replay and Close [INFERENCE: `B:§1` lists an end-of-item notice without its wording].

**Gestures:** tap toggles the chrome; double-tap the left or right third skips back or forward, with the skip glyph flashing on that side. Video & playback › Skip Gesture picks the rule: Double-Tap only (the default), where a single tap always shows or hides the controls, or Double-Tap Then Keep Tapping (repeat taps within 1.5 s of a skip add up, the TV's skip rule, `B:§4`; `SkipTaps` in Core); swipe down closes. Each gesture is a shortcut for a visible control. Starting playback fades to black over 220 ms, then video. Loading shows a turning arc and, after 1 second, what the start waits for: "Connecting to Living Room", "Opening the file", "Living Room is preparing the video", "Buffering 42%", "Starting". While an on-device remux builds its start, the arc gives way to a ring that fills with the measured share of it; every other wait has no measure and keeps the turning arc, so no percentage is made up (`L:282`). Arc and ring cross-fade over 250 ms and the fill follows the share; the caption fades only when the stage changes. Under Reduce Motion the arc does not turn and the cross-fade is 120 ms linear. While playback waits on data in mid-play, a tap on the picture only brings the chrome: a still picture invites taps, which would otherwise read as skips. A wait on the network brings the chrome up with the arc round play and "Waiting for the network" under the transport after 2 s, and the lower-quality offer after 10 s; while an offer shows, the caption gives it the band below the transport. A stuck on-device remux restarts at the playhead without a word, keeping the audio and subtitle choices.

**Orientation:** Video & playback › Video Orientation sets how the screen turns while the film or live player is open. **Follow Device** (the default) leaves it to turn with the phone. **Start in Landscape** opens the player on its side and keeps it there until the phone has been turned on its side once; from then on the screen turns with the phone, upright included. **Lock to Landscape** keeps the screen on its side until the player closes. Closing the player gives the screen back to the app, upright if the phone is held upright; so does the film player leaving for Picture in Picture, and coming back from it applies the setting again. The rule is `OrientationHold` in Core. The Picture in Picture window and an AirPlay or external screen are iOS's own. [INFERENCE: with the iPhone's Portrait Orientation Lock on, iOS reports no turns, so Start in Landscape stays on its side and Follow Device stays upright.]

**Picture in Picture:** leaving the app while a film or a live channel plays moves the picture into the system's window, from the player upright or on its side (`canStartPictureInPictureAutomaticallyFromInline`; Settings › General › Picture in Picture on the iPhone can turn that off). A paused or finished picture stays in the app [INFERENCE: so does one still loading, which has no picture to move], and nothing else opens the window but the film player's button (item 2). The film player's screen closes under the window; the window's restore button opens it again at the same time, under the orientation setting, and closing the window ends the film. The live player has no button and keeps its screen, and the way it is turned, under the window, which hands the picture back to it; closing the window away from the app ends the tune (`docs/LIVE-TV.md` §3.3). A Chromecast and AirPlay video have no window: the picture is on the receiver.

**Format badge:** when an item first starts, a small glass capsule in the top trailing corner, inside the safe area and the controls' own margins, names what plays. It waits for the controls to fade, so they never cover it (with VoiceOver or Switch Control, which keep the controls up, it shows at once), stays 1 s and fades; the controls coming back remove it. It fades in and out (opacity only under Reduce Motion): picture size by width (SD, 720p, 1080p, 1440p, 4K, 8K), range (HDR10, HDR10+, HLG, Dolby Vision; the HDR10 base layer for Dolby Vision profile 7; none when the server re-encodes) and sound (Dolby Atmos, 5.1, 7.1; only where the audio is passed through), decided by `FormatBadge` in Core. Glyphs are vectors drawn in `FormatBadgeView` (a lens for Dolby Vision and arcs for Atmos beside tracked wordmarks, outlined tags for size and HDR, the `speaker.wave.3.fill` symbol for 5.1/7.1), coloured by the theme; the text scales with Dynamic Type (up to 2.2x) and with the screen (1x to 1.5x), and the badge stacks vertically when it no longer fits. It shows once per item: seeks, stalls and restarts do not repeat it, and a file that says nothing known shows nothing. VoiceOver reads it as one label.

**System surfaces:** Picture in Picture and AirPlay (HIG Playing video); title and description supplied as external metadata so the system shows them without covering playback (HIG Playing video); Lock Screen and Control Center show the poster, title and skip commands through the system Now Playing integration [INFERENCE: API details to confirm].

### 8.7 Settings and the theme picker

Settings opens from Home's profile button in a sheet with Done (§7). It is a system inset-grouped list (`I:40`), rows 56 pt minimum. Top to bottom:

1. **Account:** profile name and server name; opens the profile switcher.
2. **Appearance:** one row reading the active theme's name, opening a short list: Theme, Tab Bar, Header Style, each a row with its current value that opens its own page, and Show Scroll Bars as a switch (below).
3. **Home:** Rows, reading Default or Custom, opens Home Rows: every row Home can show (the server's Home hubs, then each movie and TV library's hubs, named "Top Rated in Movies"), each with a small preview of its first posters, its first titles and a switch. The list is always in edit mode, so a row drags by its handle; VoiceOver offers Move Up and Move Down. A library's rows start off. Reset to Default restores the server's rows and order. Changes save at once for the profile, keyed by each hub's `hubIdentifier` (a library's prefixed with its uuid); a hub the server adds later shows at the end, and a library with no shown row is never asked for its hubs.
4. **Video & playback** (`B:§1`): skip interval (the live player's skips too), intro skip (manual or auto, countdown), **Autoplay Next Episode** (on by default; Credits: Countdown with 3, 5, 10, 15 or 30 s, or Skip Credits Instantly; §8.6), direct play mode (Auto, Disabled, Force; Force asks for confirmation with Cancel first), default aspect (`B:§4`), **Video Orientation** (Follow Device, Start in Landscape, Lock to Landscape; §8.6), Play Trailers Automatically, **Play Theme Music** with its volume (§8.3); under **Live TV**, **Direct from Tuner** (on by default; off, every channel plays through Plex, docs/LIVE-TV.md §2.2).
5. **Audio & subtitles** (`B:§1`): preferred audio language, subtitle mode, follow-dub rule, remember choices, **Subtitle style** with a live preview (`B:§3`).
6. **Integrations:** each is off until enabled and has its own page; plugins supply data, never styling (`/data/home/lgtv/CLAUDE.md`). Entries: the optional SpeechDock address (`B:§1`), Bazarr, **Chromecast**, the **LumaTV remote** and **Linked Phones** (§8.10). With Chromecast on, the player's route circle shows the Cast mark (accent while a Chromecast plays) and opens a popover: This iPhone, the Chromecasts found, and AirPlay & Bluetooth (the system picker). Every row has its icon in one fixed-width column (`Size.menuGlyph`, scaling with text) so the labels share one start line, and the check or spinner in a column of the same width at the trailing margin. The popover takes the room between the top row and the bottom controls and scrolls when the rows are taller, so a phone on its side never clips the first or last row. The phone looks for receivers only while the player or the Chromecast page is open. While casting, the picture area says "Playing on <name>", More hides Picture in Picture, Aspect and Speed, and the receiver plays the file itself when it can (MP4, video it decodes, AAC or MP3) or the server's HLS with subtitles burned in; it gets a transient token, never the account's. The LumaTV remote's page has one switch, which puts the remote button on Home. The remote is LumaRemoteKit's (`github.com/nphil/LumaRemoteKit`), drawn with the theme's canvas, glass, inks, accent and status roles, card and control radii, and Manrope for titles. Marquee registers `lumaremote://`, the link in the TV's pairing QR code: opening one turns the remote on and opens it at the pairing confirmation.
   **Seerr:** its page takes the service address and either the current Plex profile or an API key, tests the connection and identifies the account. Plain HTTP is limited to home-network addresses. A Pulsarr switch notes when adding a title to the Plex Watchlist also requests it; Forget removes the connection. Saving a connection makes Requests available (§8.8).
7. **About:** version, open-source notices. **Sign out** is destructive: a confirmation dialog that names what is removed.

The LumaTV remote’s Remote Access setting selects Mini Bar (default) or Home Button. The native tab-bar accessory shows the TV name and connection state in a compact glass capsule, adapting inline when the tab bar minimises; tap or swipe up opens the remote, and swipe down closes it. Both automatic entries are hidden away from home or when presence is unknown. The integration page keeps pairing and opening the remote available regardless of presence. The remote is a large sheet. Its bar keeps the same 16 pt margin below the sheet’s top edge as at its sides, so the close and power buttons clear the system’s rounded corners (a 38 pt continuous curve, measured on iOS 27); in landscape the sheet is full screen and the side safe areas keep them off the display corners. From Home Button the sheet zooms out of the button (§9); from the mini bar, a pairing link or Settings it is a plain sheet. The link to the TV belongs to the app, not the sheet, so closing the sheet does not reconnect and the mini bar’s status does not change.

**Theme picker** (Appearance › Theme)

1. **Match system appearance** toggle, on by default (`S:Features/Settings/SettingsView.swift:201`). On: two rows, Light and Dark, each showing a preview tile and the theme name and opening that mode's 20-theme grid. Off: one grid with a Dark | Light segmented control above it.
2. **Grid:** adaptive columns, minimum tile width 104 pt (3 at 390), 16 pt spacing (`S:Features/Settings/SettingsView.swift:213`). A tile is a rounded 3:4 preview drawn from the theme's own roles: canvas fill, two ink lines, a sheet-coloured panel holding an accent pill and three small poster blocks. The name sits under the tile (Caption). No images, no blur, no shadows, so scrolling stays smooth.
3. **Selecting:** the tile gets a ring in the theme's `focus` colour plus a check mark (never colour alone); the app re-themes instantly with a selection tick and no animation.
4. At large accessibility sizes the grid goes to 2 columns, then 1; names wrap.
5. The Appearance page holds what is not a theme. **Header Style** (§7.1) opens an inline picker with a one-line footer saying what its choices do. **Tab Bar** (§7) is a row reading "5 Tabs" that opens its page: each place with its tab icon, a line saying where it opens when it is not a tab, and a switch, in edit mode so a row drags by its handle (Search stays last and has none), then the On Scroll choice. **Show Scroll Bars**, on by default, shows the system scroll indicator on every page and sheet; the A–Z rail shows either way. All apply at once, without rebuilding the page under them, and are kept with the theme, not per profile.

### 8.8 Requests

Requests is available once Seerr is configured. It can be a tab or open from the Library toolbar; it uses the same navigation, theme and poster cells as the rest of Marquee.

1. **Discover | My Requests** selects between the Discover page and the signed-in account’s requests. Search finds movies and series. Discover follows Seerr’s order: Trending, Popular Movies, Movie Genres, Upcoming Movies, Popular Series, Series Genres and Upcoming Series. A title row is Home’s shelf, its chevron opening the whole list; a genre row is one 16:9 backdrop card per genre. A row loads when it nears the screen, shows a skeleton until its titles arrive and leaves no gap when it fails or is empty; a complete failure offers a retry.
2. **Browse** is a poster grid that pages as it scrolls, opened by a row’s chevron or a genre card. A Movies | Series switch sits under the title, then a strip of genre chips: a card’s genre arrives chosen, and switching kind clears it. As in the Library (§8.2), one View menu holds the rest and each filter that is on shows as a removable chip: Sort By (Popularity, Release Date, Rating, Title) with its order, Release by decade, Original Language, Rating from 5+ to 9+, Runtime in three bands, Streaming Service with its Region, and Upcoming Only. Trending opens as the grid alone.
3. **Request rows and title pages** show the available status and requester, with 4K or season information where relevant. A title page uses its backdrop and poster, synopsis and metadata. An available Plex item can open in the Library or play; a link without a server identity must first match the title’s TMDB identifier on the selected server.
4. **Request** opens a sheet for the permitted quality and, when the server permits partial requests, the seasons to request. Unavailable choices explain their status. The server decides approval and quota; success refreshes the title and My Requests. If Seerr or Pulsarr automatically requests Watchlist additions, the title page says so.

### 8.9 Big screen: XR glasses and TV

A plugin, off until **Big Screen** is turned on in Settings › **XR Glasses & TV** (page title "Big Screen: XR Glasses & TV"). Its page holds the switch, **When a Display Connects** (Ask, Use Marquee's TV Screen, Mirror), **Display Type** (XR Glasses, TV), **Remembered Displays** and **Tilt While Holding**. XR glasses such as the Viture Pro, or a TV on USB-C video out or an HDMI adapter, reach the iPhone as an external display; with the plugin off or Mirror chosen, iOS mirrors the phone as before. AirPlay mirroring is out of scope: it is not a wired display and nothing here claims to handle it.

**What a display is.** iOS reports a display's pixel size and refresh rate, never whether it is glasses or a TV, and exposes no display name; the only name available is the audio route's port name over HDMI, used when it is more than the word "HDMI". A display is therefore identified by its size and refresh rate (`DisplayIdentity.key`), and Display Type says what it is. The first connection with the page on Ask asks on the phone "Use Marquee on "name"?" or, with no name, "Use Marquee on this 3840 × 2160 display?" (or "this display" if no size is known), with Use as XR Glasses, Use as TV and Mirror. The answer is kept for that display (`DisplayMemory`) and wins over the page's choice from then on; a display with no kept answer follows the page's choice, taken for the Display Type shown on the page while none is connected. While a display is connected, Display Type is that display's and is kept. Remembered Displays lists the kept answers; a swipe forgets one and the next connection asks again. A display answered Mirror hands itself back to iOS and stays off until it is unplugged.

1. **The screen** is Marquee's own canvas, always 1080 pt high, scaled to the display's pixels (`BigScreenLayout`, `GlassesCanvas`, `GlassesText`); every layout token is the same on glasses and a TV, so the proportions never change. **Glasses**: 1920 × 1080. The birdbath optics show black as see-through, so the canvas is pure black and surfaces with nothing behind them to blur are opaque; colours, radii and type otherwise come from the active theme's dark side and change with it. The edges look soft through the lenses, so content keeps 144 pt in from the sides and 88 pt from top and bottom. **TV**: the canvas takes the display's aspect (4:3 to 64:27; beyond that it is letterboxed), so a 16:9 TV, at 1080p or 4K alike, is 1920 × 1080 scaled up and drawn at the display's own pixels, and a 21:9 one is 2560 × 1080. The canvas is the theme's own dark canvas, not black; surfaces are made opaque over it as on glasses. Content keeps 5 % in from every edge for overscan: 96 pt and 54 pt on a 16:9 TV. Type runs from 24 pt (caption) to 76 pt (display); Bold Text applies, Dynamic Type does not. There is one highlight: the focused tile grows 8 % and takes a 6 pt ring in the theme's focus colour. The focused title is named large above the rows, so a glance says what a tap will do.
2. **Pages** read the session's own library, Seerr, downloads and Live TV. Home starts with a row of cards (Search, each movie and show library, Requests when Seerr is set up, Downloads once something is downloaded, Live TV), then Home's rows as arranged on the phone, with the focus on Continue Watching. A library or collection is a poster grid. A title opens on its backdrop, facts and overview, with Play or Resume and Play from Start, then a show's seasons; a season lists its episodes as 16:9 tiles. Search types on a letter board and shows results by kind, then Seerr titles to request. Requests has Seerr's Discover rows; a title's page offers Request for the permitted quality, or Play once it is on the server. Downloads and Live TV (channels on now, then recordings) are grids.
3. **The player** fits the picture to the canvas, with subtitles in the profile's style. While the controls show, the title sits at the top and a large timeline at the bottom. Options lists Subtitles and Audio, then Playback: Next Episode for an episode, and Use the Phone App; Live TV's Options offers Go Live. A volume bar shows while the buttons change the level. When the glasses go, what played carries on on the phone, paused. On a TV the video plays on the external screen at its own resolution: the stream is asked for the display's pixels (a 4K TV is not given 1080p), and HDR is decided by the TV, not the phone: an HDR title is direct-played only if the TV reports EDR headroom, else it is tone-mapped. Glasses decide as the phone does.
4. **The phone as remote.** When the display connects with Marquee in the foreground, the phone becomes their remote on its own; iOS cannot open an app from the background, so otherwise it happens when Marquee next comes forward. The remote is a window over the app: the whole screen is one touch surface with no targets, on the theme's dark canvas, with the focused title in large type for a glance and the gestures listed faintly. The screen dims to 15 % while it shows and gets its own level back when it goes or Marquee leaves the foreground. Every Options list includes **Use the Phone App**; while glasses are on, Home's TV remote button becomes a glasses button that brings the remote back. The volume buttons keep their job, and the phone stays awake while the glasses show Marquee.
5. **Gestures**, all usable without looking:

| Gesture | Does |
|---|---|
| Swipe | One focus step per 52 pt across or 70 pt down; the first 12 pt lock the axis, and sliding back steps back |
| Flick | A flick faster than 300 pt/s steps once even when short; above 1000 pt/s the focus coasts on, keeping 85 % of its speed a step, up to 40 steps, and stops at the end of a list |
| Tap | Chooses the focused thing |
| Swipe in from the left edge | Back: a touch starting within 20 pt of the edge that travels 80 pt right |
| Hold (450 ms) | Options for the focused title; in the player, starts a scrub |
| Hold and slide, in the player | Scrubs: the phone's width spans up to ten minutes, with a detent every 10 s |
| Hold still after a swipe (350 ms), with tilt on | Tilting keeps scrolling, up to 12 steps a second |
| Tilt while scrubbing, with tilt on | Fine-tunes, up to 30 s a second |

Tilt reads Core Motion only while the thumb is down, counts from where the phone was when it went down, ignores the first 8 degrees so a hand's tremor moves nothing, and reaches its top rate at 34 degrees.

6. **Haptics** use Core Haptics, one distinct pattern per cue: focus step, a light crisp tap; end of a row or list, a short dull buzz; select, a full crisp tap; back, a strong dull tap and a softer one; scrub detent, a faint sharp tick; play or pause, two rising taps; error, three strong dull taps. A coast plays a step for each tile it passes.
7. **Input hook.** Every remote input is a `GlassesInput` (move, select, back, hold began, hold ended, slide, nudge) handed to `GlassesNavigator.handle(_:)`, which returns the haptic cue to play. The iPhone's own touch surface sends it, and another phone's link maps its messages to it; the navigator knows nothing of the source and works the same on glasses and a TV.
8. **VoiceOver.** The surface is one direct-interaction element, so the gestures still reach it with VoiceOver on. It reads the focused title and announces each change; its actions are Back, Options and Use the Phone App.

### 8.10 Linked phones

A plugin, off until **Linked Phones** is turned on in Settings. Two iPhones with Marquee, linked once, control each other on the same Wi-Fi: the one driving a TV or XR glasses, or playing on its own screen, is the host, and the other is its remote. Either can be either. The page holds the switch, this iPhone's name (by default the profile's name with "’s iPhone"), the linked phones with whether each is connected and a Control button while it has something to control, **Show Link Code** and **Scan Link Code**.

1. **Linking.** One phone shows a QR code, `marquee-link://pair?v=1&id=<id>&n=<name>&s=<secret>`, made when the screen opens, good for one phone and gone when the screen closes; it is dark on white whatever the theme, since scanners read only that reliably. The other phone reads it with Marquee's own camera and asks "Link with <name>?" first. It then calls the first phone, both prove they hold the secret with a Noise NNpsk0 handshake keyed from it, and each sends its id, name and a random 32-byte share. Both keep a link key derived from the secret, both ids and both shares (HKDF-SHA256, a label per use). This phone's id and the link keys stay in the Keychain.
2. **Finding each other.** While the plugin is on, Marquee is in front and a phone is linked or a code shows, each phone advertises `_marquee-link._tcp` under its id and browses for its linked phones. The phone with the larger id waits 1.5 s before calling, so usually one connection is made; when both call, both keep the one the smaller id made. Failed calls retry after 2, 4, 8 … s, at most a minute apart. A phone refused Local Network access says so on the page.
3. **The connection** is TCP with the same handshake keyed by a session key from the link key, so a phone that is not linked fails it, and each session gets keys of its own. Messages are JSON in sealed frames: the name, the remote's inputs, player commands, haptic cues and status. Status (the screen driven, the focused title, the player's title, playhead, play state, Next and subtitles) goes out when it changes, when the playhead strays a second from where the other phone runs it on to, and every 5 s; a link silent for 15 s is dropped and found again.
4. **Control.** While a linked phone has something to control, Home shows **Control <name>** in the place of the TV remote and glasses buttons. For a TV or glasses it opens §8.9's eyes-free remote over the app, the same surface, gestures and haptics, with each input sent to the other phone's navigator and its cue and focused title coming back. For a phone playing on its own screen it opens a few controls: the title and where it is, skip back and forward by the Skip Interval, play or pause, Next when there is one, and Subtitles. Done closes either. Both follow the active theme's dark side.
5. **Unlinking** on either phone removes the link on both when they are connected; the other phone otherwise lists it until it is unlinked there too. Delete All Local Data unlinks the connected phones and forgets every link.

## 9. Motion and haptics

Motion tokens come from Lucent (`T:motion`, `L:214-227`); native adapters use these values.

| Use | Token | Value |
|---|---|---|
| Press on poster, card or button | press | scale .97 over 90 ms; commits on release inside, cancels if the finger leaves (`L:72`) |
| Text or glyph swap (Play to Resume, bookmark fill) | label | 120 ms crossfade |
| Focus ring appears | focus | 150 ms |
| Custom overlay arrives (track panel, toast, Skip intro) | layer | 220 ms, travels 16 pt (toast 8 pt) |
| Overlay leaves; chrome fades out | exit | 180 ms |
| Chrome fades in | label | 120 ms |
| Programmatic scroll (A–Z jump, "go to current episode") | scroll | 300 ms at most; a drag follows the finger without easing (`L:222`) |
| Shelf posters first appear | stagger | 30 ms apart, at most 6 |
| Zoom to detail; a card that grows | spring | response 260 ms, critically damped, no overshoot (`T:motion.spring`) |
| Settings, or the remote from Home Button, opens from its button on Home (§7) | system | the system's zoom transition grows the sheet out of the button; Done, Close or a swipe down shrinks it back into it; Reduce Motion keeps the plain sheet |
| Tab bar slides away or back (Hide on Scroll, §7) | tabBar | spring, response 300 ms, critically damped; under Reduce Motion it goes and comes without sliding |
| A–Z rail lens follows the finger (§8.2) | follow | interactive spring, response 150 ms, damping .86 |
| Reduce Motion | reduce | 120 ms linear opacity at most; no scale, parallax, zoom or travel; a press shows a wash (focusWash .07 dark, .06 light) in place of the scale (`L:235`) |

Theme change: instant and atomic. Nothing loops at rest; no autoplay; no motion previews (`L:160`). Poster art fades in over 120 ms when it lands and the cell keeps its shape meanwhile (`L:295`).

**Frame rate.** The app limits no frame rate. `CADisableMinimumFrameDurationOnPhone` is set, so on a 120 Hz iPhone animation runs at the display's rate, and the app holds no display link or frame-rate range of its own. iOS paces the picture: AVPlayer's layer for films and Live TV through Plex, and for Live TV read from the tuner a sample-buffer renderer on a clock that follows the stream's timestamps, with an interlaced station shown one picture per field. Two views redraw slower on purpose: Stats for Nerds twice a second, so its text is not composited over the video every frame, and a countdown ring once a second under Reduce Motion. One route rule concerns frame rate: video above 60 fps plays as it is on Direct Play, and is converted by the server where it would have to go out as HLS (`PlaybackRoute`). Smoothness itself is checked on an iPhone (`docs/DEVICE-TEST.md` check 19).

**Haptics.** Stashy's wrapper is reusable: shared generators kept warm, selection ticks rate-limited to one per 12 ms (`S:Services/Haptics.swift:11-55`).

| Moment | Feedback |
|---|---|
| Play or pause | medium impact (`S:Features/Player/PlayerControlsView.swift:70`) |
| Skip, track pick | light impact (`S:Features/Player/PlayerControlsView.swift:195`) |
| Scrub preview frame, A–Z letter, theme tile | selection tick (`S:Features/Player/PlayerControlsView.swift:527,533`) |
| Server confirms a watched, watchlist or settings change | success, only after the confirmation (`L:75`) |
| Failure and rollback | error |

No haptic on loads, countdowns or auto-skips. No interface sounds. [INFERENCE: haptics follow the iPhone's System Haptics setting.]

## 10. Accessibility

- **Text size:** every text uses a Dynamic Type style (§4.3). Test at default, XXL, accessibility 2 (about 200%) and the largest size; labels wrap, nothing clips (`L:115,387`). Text stops growing only where it would break a fixed shape or hide the picture: the hero title (accessibility 3), the PIN keys, the A–Z rail and the stats panel (XXXL).
- **Contrast:** 4.5:1 for text and 3:1 for non-text on composited colours in all 40 themes (§5.3, §5.5). Increase Contrast and Reduce Transparency follow §5.3.
- **Reduce Motion:** §9. **Bold Text:** Manrope steps up one cut (design choice; the HIG sets no step). **Differentiate Without Colour:** every status pairs a glyph with words; selection uses a check, not only a ring colour.
- **Targets:** 48 pt, at least 12 pt apart.
- **VoiceOver:** a poster reads "Title, movie, 2019, 42 minutes left". Shelf titles are headings (rotor). Swipe actions have accessible alternatives, and the A–Z rail is adjustable (swipe up or down a letter). The scrubber is adjustable (up and down step by the skip interval) and the magic tap toggles play/pause. The player's escape gesture closes it. Toasts are announced politely; Undo stays reachable for at least 5 seconds (`L:278`). Every glyph button has a name that says what it does ("Skip forward 10 seconds", `L:126`). Hide on Scroll leaves the tab bar shown while VoiceOver runs (§7).
- **Captions:** the system caption style is respected by default; the in-app style is an override (`W26-256`).
- **Keyboard and Switch Control:** the focus ring uses `focus` (9.30:1 or more on canvas in every theme).

## 11. States

Little copy: a title and one short line, one action (`L:380`). Icons are SF Symbols. Skeletons are static fills with fixed geometry (`hoverWash` .04 per `L:288`; raise to `trackOff` if too faint on a device [INFERENCE]), swapped atomically when data lands. A blocking failure stays on screen, not as a toast alone, and keeps the last good content with its age (`L:287,300`).

| State | Look | Words | Action |
|---|---|---|---|
| Loading, first | static poster-shaped fills | after 1 s: "Loading" (`L:282`) | none |
| Loading, slow | the same, plus a stage word | "Still loading" | after a real timeout, Retry |
| Empty library | `film.stack` glyph, title | "No movies yet" and "Add some on the server." | Refresh |
| Empty watchlist | `bookmark` glyph | "Nothing saved" | none |
| Search, no results | magnifier kept, the typed text | "No results for 'x'" | none |
| Offline or server unreachable | last good content stays; a pinned banner row | "Can't reach Living Room. Showing 12 min ago." | Retry |
| Signed out or expired | its own state, not "offline" | "Sign in again" | Sign in |
| Image missing | `photo` glyph on `trackOff` | none | none |
| Playback failed | stays in the player | "Can't play this" and the reason in one line | Retry, Close |
| Undoable change | toast above the tab bar, one at a time | "Marked watched" | Undo (5 s or more) |
| Destructive | confirmation dialog in the system's destructive style, or the danger button | names what is removed | Cancel is the safe choice |

## 12. Component map and icons

| Lucent (`L:259-300`) | iPhone |
|---|---|
| Home or dashboard | scroll view of shelves; do not fill every slot |
| Rail, bottom nav, tabs | system tab view (3 to 5 items) |
| Settings, rows, drill-in | system inset-grouped list and navigation push |
| Buttons, icon buttons | custom styles: accent pill 48, round 48; glass styles on a few controls only |
| Toggle, slider, segmented, stepper | system controls, tint = accent |
| Choice popup, context menu | system menu and context menu |
| Bottom sheet | system sheet with detents; a custom opaque panel only over video |
| Dialog, alert | system alert or confirmation dialog; the danger button only in a custom confirmation |
| Toast, Undo | custom overlay above the tab bar, one at a time, 5 s or more |
| Search field | system search (top of the Search tab's landing page) |
| Chip, badge | solid chip, never glass; meaning survives without colour |
| Empty, error, skeleton | system content-unavailable view; static skeleton |
| Picture grid | adaptive poster grid (§8.2) |
| Full-screen media | the player (§8.6) |

Icons: SF Symbols only. [INFERENCE: every name needs a check in the SF Symbols app.]

| Meaning | Symbol |
|---|---|
| Tabs | `house`, `rectangle.stack`, `play.tv`, `bookmark`, `magnifyingglass`, `rectangle.stack.badge.plus` (Requests), `arrow.down.circle` (Downloads); the Library's Requests button `plus` |
| Profile, close, expand, more, see all | `person.crop.circle`, `chevron.down`, `chevron.down`, `ellipsis`, `chevron.right` |
| Watched, remove filter | `checkmark.circle`, `xmark` |
| Player | `play.fill`, `pause.fill`, `gobackward.N`, `goforward.N`, `backward.end.fill`, `forward.end.fill`, `captions.bubble`, `airplayvideo`, `pip.enter` |
| Generated subtitle | `sparkles` |
| States | `film.stack`, `photo`, `wifi.slash`, `exclamationmark.triangle`, `arrow.clockwise` |

## 13. Verification plan

1. **Theme gallery in CI.** A UI test launched with a theme id screenshots Home, Detail, the player chrome and Settings for each of the 40 themes and uploads the PNGs, so Nitin can review without a Mac [INFERENCE: feasible on the macOS runner].
2. **Dark and light, each at** default text, accessibility 2 (about 200%) and the largest size (`I:50`), on a 390 pt screen and a narrower one. Screenshots with `xcrun simctl io booted screenshot` (`I:49`); appearance with `xcrun simctl ui booted appearance dark` (`I:50`); text size and Increase Contrast through `xcrun simctl ui` [INFERENCE: option names to confirm with `xcrun simctl ui --help`]; Reduce Motion and Reduce Transparency by hand in Simulator settings.
3. **Overlap check at 100% and 200% text** on every screen (`L:387`).
4. **Glass slider:** both ends, on a build against the shipping iOS 27, because §5.3 and §6 rely on first-beta reports.
5. **A real iPhone, not the Simulator,** for gestures, haptics, scroll smoothness and Picture in Picture (`I:51`). No "faster" or "smoother" claim without a measured frame result (`/data/home/lgtv/CLAUDE.md`).
6. **Checker in CI:** `python3 -B tools/check_themes.py Resources/themes.json` prints `RESULT: PASS`.
7. Every case checked on the real device is recorded; the rest are listed as untested.

## 14. Sources and [INFERENCE] ledger

**Apple**

- `W26-251` Communicate your brand identity on iOS: https://developer.apple.com/videos/play/wwdc2026/251/
- `W26-250` Principles of great design: https://developer.apple.com/videos/play/wwdc2026/250/
- `W26-292` Design intuitive search experiences: https://developer.apple.com/videos/play/wwdc2026/292/
- `W26-256` Generated subtitles and subtitle styles: https://developer.apple.com/videos/play/wwdc2026/256/
- `W26-269` What's new in SwiftUI: https://developer.apple.com/videos/play/wwdc2026/269/
- `W25-323` Build a SwiftUI app with the new design: https://developer.apple.com/videos/play/wwdc2025/323/
- Adopting Liquid Glass: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- HIG Materials: https://developer.apple.com/design/human-interface-guidelines/materials
- HIG Typography: https://developer.apple.com/design/human-interface-guidelines/typography
- HIG Playing video: https://developer.apple.com/design/human-interface-guidelines/playing-video
- iPhone Duo (Apple developer news, 2026-10-05): https://developer.apple.com/news/?id=kkphp5qo

**Third party, first beta (June 2026):** designfornative.com, "What Designers Need to Know About iOS 27" (https://designfornative.com/what-designers-need-to-know-about-ios-27); 9to5Mac, 2026-06-08 (https://9to5mac.com/2026/06/08/apple-updates-liquid-glass-ui-in-ios-27-with-new-slider-to-customize-how-it-looks).

**[INFERENCE] ledger (re-verify before building)**

1. iOS 27 glass details: the glass slider, lighter dark glass, hard scroll-edge default, ignored opt-out, sidebar in iPhone landscape (§5.3, §6, §7).
2. Reflow target: 375 pt with the largest text stands in for the 320 pt rule; real device widths were not checked.
3. Generated subtitles through the AVPlayer WebVTT path (§8.6).
4. SF Symbol names, including `gobackward.N` for N = 5, 10, 15, 30 and 60 (§8.6, §12).
5. Manrope in the system large title is set through the navigation-bar appearance and scales only if the font is built with `UIFontMetrics`; if it does not, the title falls back to SF. Manrope licence file to confirm when bundling.
6. Poster thumbnails should be requested at display size × scale from the server's photo transcoder; the endpoint is not in `B:`.
7. Haptics honouring the System Haptics setting; zoom-transition behaviour under Reduce Motion.
8. The launch screen is a static colour that follows the iPhone's appearance, not the chosen theme, so a mismatched theme shows one brief flash.
9. The 4-item recents limit and the 1.5 s tap accumulation are TV behaviours carried over (`B:§1`, `B:§4`); the phone may want different values.
10. Open behaviour gaps from `B:§0` that block layout: the phone sign-in flow, the server connection order and the default skip interval.
