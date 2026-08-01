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

## One-time setup (about 2 minutes)

Real event data comes from free APIs. In the app, tap **⚙ Settings** and add:

1. **Ticketmaster API key** (concerts, sports, motorsports, comedy)
   - Sign up free at https://developer.ticketmaster.com
   - Open "My Apps" and copy the **Consumer Key**, paste it into Settings.
2. **SeatGeek Client ID** (optional — adds resale listings, similar to StubHub)
   - Sign up at https://seatgeek.com/account/develop and copy the **Client ID**.

Keys are stored only on your phone (localStorage) — they are never uploaded
anywhere.

## Finding racing events that hide on Facebook

Facebook removed public event search for all apps in 2018 and Instagram has no
event API, so no app can search them without you logging in. The workaround:

- Most racing orgs also post schedules on their **own website** or on
  **MyRacePass** (https://www.myracepass.com — search your track's name).
- In **Settings → My tracked pages**, add those page URLs. Event Scout scans
  each page for dates in the next 30 days and your watch keywords
  (demolition derby, hit to pass, wing night, …) and shows matches as orange
  **unconfirmed** cards — tap through to verify on the page itself.

The same trick works for restaurant wing-night pages.

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
