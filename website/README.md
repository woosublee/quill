# Quill Website

Static public website for Quill and Google OAuth production verification.

## Files

- `index.html` - Quill app homepage with SEO metadata and Google Calendar integration summary.
- `privacy/index.html` - privacy policy for Google OAuth consent and user data handling.
- `terms/index.html` - lightweight terms of service.
- `support/index.html` - public support and privacy-safe issue reporting guidance.
- `assets/quill-app-icon.png` - app icon used by the page and social metadata.
- `assets/demo.gif` - product demo shown on the homepage.
- `assets/site.css` - shared static styles.
- `llms.txt` - concise project summary for AI agents and answer engines.
- `robots.txt` - crawler policy and sitemap pointer.
- `sitemap.xml` - sitemap for `https://quill.vicals.com/`.

## Deploy

Serve this directory as the web root for `https://quill.vicals.com/`.

Recommended Cloudflare Pages settings:

- Build command: none
- Build output directory: `website`
- Custom domain: `quill.vicals.com`

## Google OAuth consent URLs

Use these URLs after deployment:

- App homepage: `https://quill.vicals.com/`
- Privacy policy: `https://quill.vicals.com/privacy/`
- Terms of service: `https://quill.vicals.com/terms/`
- Support page: `https://quill.vicals.com/support/`
- Authorized domain: `vicals.com`

Keep OAuth client secrets, deployment credentials, and environment-specific secret values out of source control.
