# Event Scout

A phone-friendly web app that finds events near you in the next 30 days —
music, racing (demolition derby, hit to pass…), comedy, sports, and local
deals like wing nights.

## How to open it

If this repository is published with GitHub Pages, the app lives at:

```
https://<your-username>.github.io/Receipts/events/
```

Open that on your phone, allow location access, and use your browser's
**Add to Home Screen** so it installs like an app (same as Receipt Keeper).

## No setup required

Event Scout searches automatically, with no API keys and no configuration:

- **Eventbrite** — reads Eventbrite's public nearby-events pages for your city
  (concerts, comedy, community events, festivals).
- **Race tracks near you** — automatically discovered from OpenStreetMap
  (speedways, raceways, motocross tracks within your radius). Tracks with
  websites get scanned for dates and racing keywords (demolition derby,
  hit to pass, enduro, …). A "Race tracks near you" card lists every track
  found, with schedule links.
- **Web sweep** — DuckDuckGo searches for your keywords near your city,
  including a query targeted at publicly indexed **facebook.com event pages**
  and one for **wing night / wing specials**. A "see on Google" link runs the
  same search on Google in your browser.

### Optional boosters (free API keys)

Adding keys in **⚙ Settings** brings in the big official ticket listings:

1. **Ticketmaster** — sign up free at https://developer.ticketmaster.com,
   copy the **Consumer Key** from "My Apps".
2. **SeatGeek** (resale listings, similar to StubHub) — sign up at
   https://seatgeek.com/account/develop and copy the **Client ID**.

Keys are stored only on your phone (localStorage) — never uploaded anywhere.

## About Facebook & Instagram

Facebook removed public event search for all apps in 2018 and Instagram has no
event API, so no app can search inside them without you logging in. Event
Scout's web sweep finds publicly indexed Facebook event pages (which usually
open without an account), and the auto-discovered track websites cover most
racing orgs that mainly post on Facebook. Private group posts are out of reach
for every app. You can also add extra pages (racing orgs, MyRacePass pages,
restaurant specials pages) under **Settings → Extra tracked pages**.

## Features

- 📍 Phone GPS location, or type a city/ZIP
- Adjustable search radius (5–300 miles)
- 30-day window with a day picker strip (with per-day event counts)
- Category filters: Racing, Music, Comedy, Sports, Arts, Deals, Other
- Each event shows date/time, price, venue, distance from you, description,
  category, and a link to the event page
- Keyword watchlist with highlighted matches
- Works as an installable PWA; the app shell loads offline

## Notes & limits

- Ticket sites don't list free community events or bar deals — that's what the
  tracked-pages feature is for.
- Tracked-page scanning is best effort (it reads the public page through a
  proxy and looks for dates); always verify via the link.
- StubHub has no public API; SeatGeek covers similar resale inventory.
