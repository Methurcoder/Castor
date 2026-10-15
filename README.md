# Castor download site

Static page for GitHub Pages (`index.html`, `style.css`, `site.js`, `assets/`).
It reads the latest Release from the GitHub API in the browser, shows one
download button for the visitor's OS (Mac: the `.dmg`, or the Mac setup zip
when a release has no dmg; Windows: the setup zip) and explains every file on
the Release page. Without the API the buttons open the Release page.

- Text: Japanese in `index.html`, English in `site.js` (`EN`).
- File descriptions: `FILES` in `site.js`, matched by asset name.
- Videos: `assets/promo-*.mp4` (intro), `assets/first-launch-mac-*.mp4`
  (first-launch steps on Mac; account names are masked).

Preview locally:

    python3 -m http.server 8792 --directory .
