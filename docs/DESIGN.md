# Marquee iOS: design direction

**Answer first.** Marquee iOS is a calm, poster-first Plex client for iPhone. Apple's Liquid Glass (the see-through, blurred look of iOS 26 and 27) draws the bars, buttons and sheets. Marquee draws what sits inside them: posters, Manrope headings and 40 colour themes (20 dark, 20 light; Rosé Pine is the default). Every colour comes from one file, `themes.json`, and one script, `check_themes.py`, proves each theme is readable.

Status: design direction only. Nothing is built and nothing has run on a device. Only the themes are checked by script (§5.5).

This slice produced `DESIGN.md`, `themes.json` and `check_themes.py`. Sibling slices in the same folder: `behaviour-spec.md` (plain-words behaviour, cited as `B:`), `stashy-playbook.md`, `videoengine.md`.

Citation key:

- `L:n`: Lucent `LANGUAGE.md` line n; `T:key`: Lucent `tokens.json` (both in `/data/agent/managed-skills/design-language/languages/lucent/`).
- `S:path:n`: Stashy line n, under `/data/home/Stashy/ios/Stashy/`. Stashy is Nitin's own code and reusable.
- `I:n`: `/data/home/.agents/skills/impeccable/reference/ios.md` line n.
- `B:§n`: `behaviour-spec.md` section n. `C:n`: `check_themes.py` line n.
- `W26-251` and similar: Apple WWDC sessions; URLs in §14. `[INFERENCE]`: not verified.
- Clean room: no PlxNative or Marquee TV code was read or used. Behaviour comes only from `B:`.

## 1. The short version

- **Five tabs:** Home, Library, Watchlist, Settings and Search. System tab bar, system back swipe, system sheets.
- **Home:** one large Continue Watching card, then poster shelves. Posters carry the colour; everything else stays quiet.
- **Detail:** art that melts into the page, the title in Manrope, one wide Play button (it reads Resume on a part-watched title).
- **Player:** full-screen video. Controls fade after 3 seconds; one tap brings them back. Audio and subtitles share one native menu with plain track names.
- **Themes:** 40, chosen in Settings and applied instantly. By default the app follows the iPhone's light/dark setting: Rosé Pine Dawn by day, Rosé Pine at night.
- **Text size:** follows the iPhone's setting up to the largest accessibility sizes. Layouts reflow; nothing overlaps.
- **Proof so far:** 40 of 40 themes pass every required contrast rule, and no two themes of one mode are recolours of each other (§5.5).

### 1.1 Decisions already made (each is cheap to change)

| # | Decision | Why | Cost to change |
|---|---|---|---|
| 1 | Tabs: Home, Library, Watchlist, Settings, Search | `B:§1` lists these destinations; Lucent allows 3 to 5 (`L:160`). Watchlist could fold into Library | one tab |
| 2 | "Match system appearance" is on by default | Apple expects both appearances to be supported (`W26-251`); `I:31` | one default |
| 3 | Every player control is a 56 pt circle; play/pause is marked by a solid white fill, not by size | Lucent: one button size per screen (`L:381`) | one size |
| 4 | Hero title 34 pt, not Lucent's 48 | A long film title takes about 4 lines at 48 pt and about 3 at 34 pt on a 390 pt screen [INFERENCE: estimated from average glyph width] | one size |
| 5 | Theme is saved per device, not per Plex profile | It is a look, not a viewing preference (`B:§1` saves settings per profile) | one key |
| 6 | Skip step defaults to 10 s | Stashy's value (`S:Features/Player/PlayerControlsView.swift:191-200`); the TV default is unconfirmed (`B:§0`) | one setting |
| 7 | No playback-speed menu in the first build | The TV app has none (`B:§0`); Stashy has one (`S:Features/Player/PlayerControlsView.swift:253-256`) and it can be reused | one menu |

## 2. Product context (inferred)

No PRODUCT.md interview was possible. This section is inferred from the brief, Lucent, Stashy and `B:`.

- **Purpose.** Watch the household's own Plex movies and TV on an iPhone: resume fast, find something quickly, get audio and subtitles right.
- **People.** Nitin and the household, each a Plex Home profile. Couch, one hand, dim room; sometimes daylight.
- **Personality.** Composed, cinematic, unhurried.
- **Anti-references.** A website in an app shell. Autoplaying trailers and busy carousels. Glass on everything. A dense Plex Web clone.
- **Principles.**
  1. Posters are the colour; chrome recedes (`L:382`).
  2. The system owns navigation; Marquee owns content, type and tint (`W26-251`, `I:5`).
  3. Every screen answers "what do I watch next?".
  4. Honest states: last good data, real reasons, no fake progress (`L:287`, `L:300`).
  5. Quiet motion; the room is dark.

## 3. Mode, scene and visual world

- **Mode:** Operate (get the person to a film fast), with Experience-leaning moments: the detail hero and the player.
- **Scene:** an evening on the couch, phone in one hand, lights low. One thumb, no glare, no animation for its own sake, no audio from the app until play is pressed.
- **Colour strategy:** Restrained. A tinted near-black (or soft paper) canvas, one accent on at most about 10% of a screen, and poster art as the only large colour. Dark is the first design target; light gets equal verification (`I:31`).
- **Signature:** Manrope headings; a 1 pt lit rim on panels; the theme as personality; poster-first shelves with very little text.
- **Craft floor:** no kicker lines above headings, no gradient text, no side stripes, no card inside a card, no hard offset shadows, no emoji or Unicode icons (SF Symbols only), no decorative glass. Gradients exist only as functional fades behind text (hero, player).

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
| label | 14 | 15 | Subheadline | SF Medium, line 1.3 | meta lines, chips |
| caption | 12 | 12 | Caption 1 | SF Regular, line 1.3 | poster titles, badges, time stamps (floor 11, `I:26`) |

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
| positive, warning, danger, info, live | meaning, never decoration (§5.2). `live` is reserved for live sources and is unused for now |

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

`themes.json`: `{schema: "lucent-colour-roles/1", default: "rose-pine", roles: [20 names], themes: [{id, name, mode: "dark" or "light", colors: {20 roles}}]}`. Colours are `#RRGGBB` or `#RRGGBBAA`. There are no preview images: a picker tile is drawn from the roles. The app bundles this same file. CI should run `python3 -B check_themes.py [themes.json]` (exit 0 on pass, 1 on a required failure) so a theme that fails breaks the build.

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
- iOS 27 reportedly adds more defined glass borders in place of shadows, lighter dark glass, an ignored glass opt-out in Xcode 27 builds and a "hard" scroll-edge default (set soft only on the detail hero) (designfornative, 2026-06-10). [INFERENCE: first-beta write-up; re-verify on the shipping release.]

## 7. Navigation model

- **Root:** a tab view with Home, Library, Live TV, Watchlist and a Search tab in the search role (the separate search bubble) (`W25-323`). The tab bar collapses on scroll down on Home and Library (`tabBarMinimizeBehavior`, `W25-323`) and stays put elsewhere. Settings is not a tab: the profile button at the top of Home opens it in a sheet, as in the Apple TV app.
- **Each tab owns a navigation stack.** Detail pushes with a zoom transition from the tapped poster (`W26-251`); Reduce Motion makes it a 120 ms crossfade. The left-edge back swipe is never disabled or overlaid (`I:15`). No custom back buttons, no hamburger menu (`I:14`).
- **Player:** a full-screen cover (`I:39`). The way out is a swipe down on the picture, the Close button, or the VoiceOver escape gesture; none depends on the chrome being visible.
- **Sheets** hold short self-contained tasks: Settings, profile switcher (over Settings), subtitle style, subtitle timing, version picker, tracks info. Long tasks (subtitle search) are full pages pushed inside the sheet (`L:160`). **Menus** hold short choices: sort, filter, season, tracks, more. **Confirmation dialog** for sign-out and removals. **Alert** only for blocking errors.
- **Search tab:** the standard variant (a landing page with recents), not the prominent variant that opens the keyboard at once (`W26-292`, `W26-269`).
- **Rotation and size:** browse screens work in every orientation [INFERENCE: WCAG 1.3.4]; the player follows the phone, and in portrait the picture is letterboxed on black with the same chrome over it. Tabs become a sidebar in iPhone landscape (`sidebarAdaptable`) [INFERENCE: first-beta]. Layout uses size classes, layout margins and safe areas, never device or `UIScreen.main` checks, so resizable windows and the foldable iPhone Duo (on sale 2026-10-23; the inner display can be regular width) work (`W26-269`, Apple developer news 2026-10-05).
- **Unused:** the tab-bar bottom accessory (`tabViewBottomAccessory`) is kept free for a possible mini-player or a future TV-remote strip [INFERENCE: no design exists for either].

## 8. Screens, in words

Every screen: large title where top-level, canvas behind, 16 pt insets, one button size, hints as glyphs with accessible names (`L:121-127`, `L:381`).

### 8.0 Sign-in and server choice (brief)

The phone sign-in mechanism is not confirmed (`B:§0`), so only the screen is specified. One screen: the Marquee mark, one Sign in button, nothing else. After sign-in, a server list: one 56 pt row per server (name, owner, a connection glyph with a word); choosing one is remembered; only the user's own servers are listed (`B:§1`). Empty: "No servers found" with Retry. A failed or expired sign-in has its own state (§11).

### 8.1 Home

1. **Large title** "Home". Trailing: the profile button (`person.crop.circle`), which opens the profile switcher sheet [INFERENCE: a protected profile may ask for a PIN].
2. **Continue Watching** (hidden when empty, `B:§1`): a horizontal snap shelf of 16:9 cards, about 82% of the width so the next card peeks. Under each card, never over the art: a 3 pt progress bar (accent on `trackOff`), the title (Headline) and one line such as "S2 · E5 · 42 min left" in ink2 (the remaining time is the helpful context Apple asks for, `W26-250`). Tap resumes at once. Long-press opens a menu: Details, Mark watched, Remove from Continue Watching (with Undo).
3. **Hubs**, in server order, empty ones hidden (`B:§1`). Each is a title (Manrope SemiBold 24) with a trailing `chevron.right` (accessible name "See all …") over a poster shelf. Poster cell: 2:3 art, a 3 pt progress bar if part-watched, a one-line title (Caption). Badge on the art, top trailing: a solid canvas-coloured pill with ink text (unwatched episode count; a check for watched), never glass.
4. Pull to refresh.

### 8.2 Library

1. **Large title with a menu** to switch library ("Movies" with a menu chevron). Toolbar: one View menu (sort, filter, unwatched only).
2. **Filter chips** appear under the title only while a filter is on: solid chips with `xmark`, full 48 pt hit height.
3. **Poster grid:** adaptive, minimum 104 pt, 12 pt gutters; 3 columns at 390. At large accessibility sizes: 2 columns, then 1.
4. **A–Z rail** on the trailing edge, only when sorted by title (`B:§1`): letters in Caption; dragging selects with a selection tick per letter. A "Jump to" toolbar menu is the accessible alternative.
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

1. **Hero:** the backdrop at its natural 16:9 ratio, full width, bleeding to the top edge under the status bar, fading to canvas over its lower 45% or so (§5.3). No portrait crop, so faces are not cut. Where the art is narrower than the screen (iPad width, folded), `backgroundExtensionEffect` fills the sides (`W25-323`). With no backdrop: the poster, blurred, as the fallback [INFERENCE].
2. **Title block** on the faded part: the title (display; wraps up to 3 lines), a meta line (year, runtime, content rating), solid format chips (4K, HDR, Atmos) and a star glyph with the rating in ink2.
3. **Action row, one size (48):** a full-width **Play** pill in accent ("Play", or "Resume · 42 min left"; for a show "Play S1 · E1" or "Resume S2 · E5"), then round icon buttons: watchlist (`bookmark`), watched (`checkmark.circle`), More (`ellipsis`: Play from beginning, Version, Tracks, Share). Watched and watchlist apply at once with a toast and Undo (`L:365`).
4. **Version** menu ("4K HDR · 12 GB" with a chevron) only when the title has more than one version.
5. **Synopsis:** Body, 3 lines, then a `chevron.down` to expand; capped near 70 characters per line.
6. **Tracks** row opens a sheet with the full audio and subtitle list in technical terms: codec, channels, PCM and Dolby chips, and image-format chips (PGS, VOBSUB) only on image subtitles (`B:§3`).
7. **Cast** (circular photos, 72 pt, Caption names) and **Related** (poster shelf), when the server provides them.
8. The navigation bar is transparent at rest and gains glass as the page scrolls under it (`scrollEdgeEffectStyle`, `W25-323`).
9. **Watchlist** items that are not on the user's server open this same screen with no Play pill and one line, "Not on your servers" [INFERENCE: not in `B:`].

### 8.4 Seasons and episodes (inside a show's detail)

1. **Season menu:** a pill "Season 2" with a menu chevron under the action row; the selected season has a check.
2. **Episode rows,** 56 pt minimum: a 16:9 still (128 × 72, control radius) with a 3 pt progress bar if part-watched; beside it the title "5 · Name" (Headline, wraps), runtime and air date (ink2) and two lines of synopsis (ink2). Trailing: a watched check and `ellipsis` (Mark watched or unwatched, Play from beginning, Details).
3. Tap plays and resumes (`B:§4`). Swipe actions mark watched or unwatched, each with Undo (`swipeActionsContainer` lets swipe actions work outside lists, `W26-269`).
4. At accessibility sizes the still moves above its text; nothing overlaps (`L:387`).
5. The unwatched count is total episodes minus watched (`B:§1`), shown on the show's poster and in the season menu rows.

### 8.5 Search (a tab)

1. **Search field** in the bottom toolbar (Apple's preferred placement, `W26-292`), prompt "Search your library": it searches only the user's own servers (`B:§1`).
2. **Landing (empty query):** recents inline, the last 4 kept (`B:§1`), swipe to remove, a Clear at the end (`W26-292`). Nothing else: no trending, no ads.
3. **Typing:** results as the text changes, grouped Movies, Shows, Episodes, People. A scope control under the field: All, Movies, Shows, Episodes (`W26-292`). Result row: a 56 × 84 poster, the title (Headline), "Movie · 2019" (ink2).
4. **No results:** the system no-results view with the typed text and the magnifier kept, one short line (`W26-292`).

### 8.6 Player

```
+---------------------------------------------------------------+
| (v)  Title                              S2 E5   (airplay) (pip) |
|                                                               |
|              (<<10)          (> / ||)          (10>>)         |
|                                                               |
| 0:42:10  =====================o--------------------  -1:03:22 |
| (|<) (>|)                                      (tracks) (...)  |
+---------------------------------------------------------------+
```

Round brackets are 56 pt glass buttons; the picture runs behind everything.

**Rules for a picture screen** (`L:248,296,404`)

- The picture is an AVPlayer layer; the chrome is custom, on the pattern Stashy already uses (`S:Features/Player/PlayerControlsView.swift`). It copies the system player's behaviour so it reads at once (HIG Playing video), keeps the video's original aspect ratio (HIG Playing video) and uses pure black bars. [INFERENCE: the Marquee-only offers below do not fit the system transport bar.]
- Chrome fades after 3 seconds without input, only while playing and not scrubbing (the Stashy rule, `S:Features/Player/ScenePlayerView.swift:340-346`), and returns on the next touch.
- The first tap only reveals the chrome; hidden controls take no touch (`L:248`).
- The way out never depends on the chrome: swipe down on the picture, or the VoiceOver escape gesture. With VoiceOver or Switch Control on, the chrome stays visible.
- The chrome is always in the dark colour scheme, so glass over video stays dark in every theme. Panels that open from the player use the theme's own mode.
- Subtitles lift above the bottom chrome while it shows; they are never hidden behind it.

**Chrome** (one control size: 56 pt circles, glyphs 26 pt semibold; play/pause is a solid white fill with a dark glyph)

1. **Scrims:** black gradients, .55 or more at the very top and bottom edges, fading to clear. Glass clusters sit on them (clear glass over media with at least 35% dimming, HIG Materials).
2. **Top row:** Close (`chevron.down`) leading; the title block in the middle (title, "S2 · E5" in white at 70%); trailing AirPlay (`airplayvideo`, system route picker) and Picture in Picture (`pip.enter`).
3. **Centre transport:** skip back (`gobackward.N`), Play/Pause, skip forward (`goforward.N`), with N from the skip setting (5, 10, 15, 30 or 60 s, `B:§4`; default 10). Glyph names to check in the SF Symbols app.
4. **Scrubber:** a 6 pt readable track (§5.1) with a 56 pt-tall hit area and a white thumb; elapsed time leading, remaining time trailing (Caption, tabular). Dragging shows the scene-thumbnail preview and the time above the thumb, a selection tick per preview frame, and moving the finger away vertically slows the scrub (`S:Features/Player/PlayerControlsView.swift:513-534`). Intro and credits ranges from the server show as small tick segments with an accessible label (`B:§2`).
5. **Bottom row:** Previous (`backward.end.fill`) and Next (`forward.end.fill`) leading; Tracks (`captions.bubble`) and More (`ellipsis`) trailing. Previous restarts the item when 5 s or more in, otherwise goes to the previous item (`B:§4`). A button with no target is dimmed, and VoiceOver reads "unavailable" (`B:§4`, `L:74`). More: Aspect (Fit, Fill, Original, Zoom, Stretch, `B:§4`), Playback info.

**Tracks menu:** one native menu; audio and subtitles together, as Apple's own player does.

- **Audio** section: one row per track, the language first and a plain channel word only where needed to tell rows apart ("English", "English, 5.1", "English (commentary)"); the wanted-language track is first and the playing one has a check. Codec names live only on the Tracks info sheet (`B:§3`).
- **Subtitles** section: Off; "On-screen text only" (forced); one group per language, ranked Full, SDH, Forced, Commentary; "Other languages (N)" as a submenu; then Style, Timing and Search subtitles (only when Bazarr is set up) (`B:§3`). When a downloaded subtitle is playing, "Wrong subtitles?" appears here too (`B:§3`).
- A subtitle generated on-device (iOS 27) carries `sparkles`. Apple's own example adds the word "Translated" to translated tracks; Marquee labels a track transcribed from the audio "Generated" [INFERENCE: Marquee's own wording]. Authored subtitles are preferred and rank first (`W26-256`). [INFERENCE: generated subtitles need the AVPlayer subtitle path; the video-engine plan serves text subtitles as WebVTT (`videoengine.md` §3.4), which should qualify.]
- **Style** opens a sheet (size, position, colour, background) with a live preview (`AVPlayerLayer.setCaptionPreviewProfileID`, `W26-256`). It applies to text subtitles; for image subtitles (PGS, VOBSUB, DVB) the row is disabled with the reason "Image subtitles can't be restyled" (`L:367`). Custom controls must offer subtitle choice (`W26-256`); this menu does.
- Track labels are "English", "English (dub)", "English (on-screen text)", "(commentary)"; "Track N" tells identical rows apart; no codec names or file titles in the subtitle rows (`B:§3`).

**Offers** (bottom trailing, one at a time, 220 ms in; not part of the auto-hiding chrome, they stay while their marker is active and take touch while visible)

- **Skip intro:** a solid accent pill, 56 pt tall (the one control size), accentInk label, with a thin countdown ring when auto-skip is on. Manual by default; "Watch intro" cancels auto-skip for that episode (`B:§4`).
- **Up Next:** at a credits marker with a queued next episode, an opaque-sheet card (poster, "S2 · E6 · Name", a countdown ring around a play glyph, a text button "Watch credits"). Pause, buffering, menus and input stop the countdown (`B:§4`).
- **End of item:** the last frame stays, the chrome stays, one line "Finished" with Replay and Close [INFERENCE: `B:§1` lists an end-of-item notice without its wording].

**Gestures:** tap toggles the chrome; double-tap the left or right third skips back or forward, repeat taps within 1.5 s add up (the TV's skip rule, `B:§4`), with the skip glyph flashing on that side; swipe down closes. Each gesture is a shortcut for a visible control. Starting playback fades to black over 220 ms, then video. Loading shows a small static arc, and after 1 second a stage word ("Connecting", then "Preparing"); never a made-up percentage (`L:282`).

**System surfaces:** Picture in Picture and AirPlay (HIG Playing video); title and description supplied as external metadata so the system shows them without covering playback (HIG Playing video); Lock Screen and Control Center show the poster, title and skip commands through the system Now Playing integration [INFERENCE: API details to confirm].

### 8.7 Settings and the theme picker

Settings opens from Home's profile button in a sheet with Done (§7). It is a system inset-grouped list (`I:40`), rows 56 pt minimum. Top to bottom:

1. **Account:** profile name and server name; opens the profile switcher.
2. **Appearance:** the theme picker (below).
3. **Video & playback** (`B:§1`): skip interval, intro skip (manual or auto, countdown), credits and auto-next delay, direct play mode (Auto, Disabled, Force; Force asks for confirmation with Cancel first), default aspect (`B:§4`).
4. **Audio & subtitles** (`B:§1`): preferred audio language, subtitle mode, follow-dub rule, remember choices, **Subtitle style** with a live preview (`B:§3`).
5. **Integrations:** each is off until enabled and has its own page; plugins supply data, never styling (`/data/home/lgtv/CLAUDE.md`). First entry: the optional SpeechDock address (`B:§1`).
6. **About:** version, open-source notices. **Sign out** is destructive: a confirmation dialog that names what is removed.

**Theme picker** (Appearance page)

1. **Match system appearance** toggle, on by default (`S:Features/Settings/SettingsView.swift:201`). On: two rows, Light and Dark, each showing a preview tile and the theme name and opening that mode's 20-theme grid. Off: one grid with a Dark | Light segmented control above it.
2. **Grid:** adaptive columns, minimum tile width 104 pt (3 at 390), 16 pt spacing (`S:Features/Settings/SettingsView.swift:213`). A tile is a rounded 3:4 preview drawn from the theme's own roles: canvas fill, two ink lines, a sheet-coloured panel holding an accent pill and three small poster blocks. The name sits under the tile (Caption). No images, no blur, no shadows, so scrolling stays smooth.
3. **Selecting:** the tile gets a ring in the theme's `focus` colour plus a check mark (never colour alone); the app re-themes instantly with a selection tick and no animation.
4. At large accessibility sizes the grid goes to 2 columns, then 1; names wrap.

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
| Reduce Motion | reduce | 120 ms linear opacity at most; no scale, parallax, zoom or travel; a press shows a wash (focusWash .07 dark, .06 light) in place of the scale (`L:235`) |

Theme change: instant and atomic. Nothing loops at rest; no autoplay; no motion previews (`L:160`). Poster art fades in over 120 ms when it lands and the cell keeps its shape meanwhile (`L:295`).

**Haptics.** Stashy's wrapper is reusable: shared generators kept warm, selection ticks rate-limited to one per 12 ms (`S:Services/Haptics.swift:11-55`).

| Moment | Feedback |
|---|---|
| Play or pause | medium impact (`S:Features/Player/PlayerControlsView.swift:70`) |
| Skip, track pick | light impact (`S:Features/Player/PlayerControlsView.swift:195`) |
| Scrub preview frame, A–Z letter, theme tile | selection tick (`S:Features/Player/PlayerControlsView.swift:527,533`) |
| Server confirms a watched, watchlist or settings change | success, only after the confirmation (`L:75`) |
| Failure and rollback | error |

No haptic on loads, countdowns or auto-skips. No sound from the app. [INFERENCE: haptics follow the iPhone's System Haptics setting.]

## 10. Accessibility

- **Text size:** every text uses a Dynamic Type style (§4.3). Test at default, XXL, accessibility 2 (about 200%) and the largest size; labels wrap, nothing clips (`L:115,387`). The hero title is the only capped text.
- **Contrast:** 4.5:1 for text and 3:1 for non-text on composited colours in all 40 themes (§5.3, §5.5). Increase Contrast and Reduce Transparency follow §5.3.
- **Reduce Motion:** §9. **Bold Text:** Manrope steps up one cut (design choice; the HIG sets no step). **Differentiate Without Colour:** every status pairs a glyph with words; selection uses a check, not only a ring colour.
- **Targets:** 48 pt, at least 12 pt apart.
- **VoiceOver:** a poster reads "Title, movie, 2019, 42 minutes left". Shelf titles are headings (rotor). Swipe actions and the A–Z rail have accessible alternatives. The scrubber is adjustable (up and down step by the skip interval) and the magic tap toggles play/pause. The player's escape gesture closes it. Toasts are announced politely; Undo stays reachable for at least 5 seconds (`L:278`). Every glyph button has a name that says what it does ("Skip forward 10 seconds", `L:126`).
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
| Search field | system search (bottom toolbar, Search tab) |
| Chip, badge | solid chip, never glass; meaning survives without colour |
| Empty, error, skeleton | system content-unavailable view; static skeleton |
| Picture grid | adaptive poster grid (§8.2) |
| Full-screen media | the player (§8.6) |

Icons: SF Symbols only. [INFERENCE: every name needs a check in the SF Symbols app.]

| Meaning | Symbol |
|---|---|
| Tabs | `house`, `rectangle.stack`, `bookmark`, `gearshape`, `magnifyingglass` |
| Profile, close, expand, more, see all | `person.crop.circle`, `chevron.down`, `chevron.down`, `ellipsis`, `chevron.right` |
| Watched, remove filter | `checkmark.circle`, `xmark` |
| Player | `play.fill`, `pause.fill`, `gobackward.N`, `goforward.N`, `backward.end.fill`, `forward.end.fill`, `captions.bubble`, `airplayvideo`, `pip.enter` |
| Generated subtitle | `sparkles` |
| States | `film.stack`, `photo`, `wifi.slash`, `exclamationmark.triangle`, `arrow.clockwise` |

## 13. Verification plan (not run yet)

1. **Theme gallery in CI.** A UI test launched with a theme id screenshots Home, Detail, the player chrome and Settings for each of the 40 themes and uploads the PNGs, so Nitin can review without a Mac [INFERENCE: feasible on the macOS runner].
2. **Dark and light, each at** default text, accessibility 2 (about 200%) and the largest size (`I:50`), on a 390 pt screen and a narrower one. Screenshots with `xcrun simctl io booted screenshot` (`I:49`); appearance with `xcrun simctl ui booted appearance dark` (`I:50`); text size and Increase Contrast through `xcrun simctl ui` [INFERENCE: option names to confirm with `xcrun simctl ui --help`]; Reduce Motion and Reduce Transparency by hand in Simulator settings.
3. **Overlap check at 100% and 200% text** on every screen (`L:387`).
4. **Glass slider:** both ends, on a build against the shipping iOS 27, because §5.3 and §6 rely on first-beta reports.
5. **A real iPhone, not the Simulator,** for gestures, haptics, scroll smoothness and Picture in Picture (`I:51`). No "faster" or "smoother" claim without a measured frame result (`/data/home/lgtv/CLAUDE.md`).
6. **Checker in CI:** `python3 -B check_themes.py` prints `RESULT: PASS`.
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
