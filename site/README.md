# Citusmail website

The site at **https://citusmail.fluminaris.com**: a homepage, the
[privacy policy](../docs/privacy-policy.md) and the
[terms of service](../docs/terms-of-service.md). The two policy pages are
built from those files at every build, so editing them in `docs/` is all
it takes to update the site.

```bash
cd site
npm ci
npm test                # SITE_OFFLINE=1 to skip the release lookup
npm run build           # into site/dist/
python3 -m http.server -d dist 8000   # look at it (pages are *.html locally)
```

`build.mjs` renders `templates/` and `../docs/*.md`, copies `static/`, the
screenshots from `../docs/screenshots/` and the icon from `../assets/icon/`.
It looks up the latest GitHub release for direct download links and the
version number; if that fails (offline, rate limited) the buttons open the
releases page instead.

No analytics, cookies, scripts or third-party requests: fonts, images and
styles are all served from the site, and `vercel.json` sets a strict
Content-Security-Policy.

## Dependencies

| Package | Why |
| --- | --- |
| `marked` (exact version, no dependencies of its own) | Turns the policy Markdown into HTML at build time |

IBM Plex Sans comes from IBM's own Latin-1 web subset (`@ibm/plex-sans`),
under the SIL Open Font License (`static/fonts/OFL.txt`).

## Deploying (Vercel)

Vercel deploys the site from this repository: production on every push to
`main`, and a preview for each pull request. Project settings:

| Setting | Value |
| --- | --- |
| Framework preset | Other |
| Root Directory | `site`, with "Include files outside the Root Directory" on |
| Install / Build command | from `vercel.json` (`npm ci`, `npm run build`) |
| Output directory | `dist` |
| Node.js | 22.x |
| Ignored Build Step | `git diff --quiet HEAD^ HEAD -- . ../docs ../assets/icon` |
| Web Analytics, Speed Insights | off |

Domain: in Vercel → Project → Domains, add `citusmail.fluminaris.com`. At the
DNS provider for fluminaris.com, add the record Vercel shows (a `CNAME`
from `citusmail` to `cname.vercel-dns.com`).

CI (`.github/workflows/ci.yml`, job "Website") also tests and builds the
site on every pull request, so a broken template fails before Vercel sees
it.
