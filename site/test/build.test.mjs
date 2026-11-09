// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import {
  build,
  docHeading,
  downloadValues,
  fill,
  latestRelease,
  renderDoc,
  rewriteHref,
} from '../build.mjs';

const repoUrl = 'https://github.com/pawtaetoe/Citusmail';

test('links between docs go to their pages; other files to GitHub', () => {
  assert.equal(rewriteHref('terms-of-service.md'), '/terms-of-service');
  assert.equal(rewriteHref('privacy-policy.md#children'), '/privacy-policy#children');
  assert.equal(rewriteHref('../LICENSE'), `${repoUrl}/blob/main/LICENSE`);
  assert.equal(rewriteHref('https://example.com/x'), 'https://example.com/x');
  assert.equal(rewriteHref('mailto:a@b.c'), 'mailto:a@b.c');
  assert.equal(rewriteHref('#top'), '#top');
});

test('a doc renders without its title, with rewritten links', () => {
  const md = '# Title\n\nSee the [terms](terms-of-service.md).\n';
  assert.equal(docHeading(md), 'Title');
  const html = renderDoc(md);
  assert.ok(!html.includes('<h1'));
  assert.ok(html.includes('href="/terms-of-service"'));
});

test('a missing template value is an error, not literal braces', () => {
  assert.equal(fill('Hi {{name}}', { name: 'you' }), 'Hi you');
  assert.throws(() => fill('Hi {{nme}}', { name: 'you' }), /nme/);
});

test('downloads: direct links when the release is known, else its page', () => {
  const none = downloadValues(null);
  assert.equal(none.deb, `${repoUrl}/releases/latest`);
  assert.equal(none.version, '');
  const known = downloadValues({ version: '0.4.5', deb: 'https://x/a.deb' });
  assert.equal(known.deb, 'https://x/a.deb');
  assert.equal(known.apk, `${repoUrl}/releases/latest`);
  assert.match(known.version, /0\.4\.5/);
});

test('the latest release lookup picks each package and survives failure', async () => {
  const asset = (name) => ({ name, browser_download_url: `https://dl/${name}` });
  const ok = async () => ({
    ok: true,
    json: async () => ({
      tag_name: 'v0.4.5',
      assets: [
        asset('citusmail-0.4.5-armeabi-v7a.apk'),
        asset('citusmail-0.4.5-x86_64.apk'),
        asset('citusmail-0.4.5.apk'),
        asset('citusmail_0.4.5-12_amd64.deb'),
        asset('citusmail-0.4.5.flatpak'),
        asset('citusmail-setup-0.4.5.exe'),
        asset('SHA256SUMS'),
      ],
    }),
  });
  const offline = process.env.SITE_OFFLINE;
  delete process.env.SITE_OFFLINE;
  try {
    const release = await latestRelease(ok);
    assert.equal(release.version, '0.4.5');
    assert.equal(release.apk, 'https://dl/citusmail-0.4.5.apk', 'the arm64 APK, not another processor type');
    assert.equal(release.deb, 'https://dl/citusmail_0.4.5-12_amd64.deb');
    assert.equal(release.exe, 'https://dl/citusmail-setup-0.4.5.exe');
    assert.equal(await latestRelease(async () => { throw new Error('offline'); }), null);
    assert.equal(await latestRelease(async () => ({ ok: false })), null);
  } finally {
    if (offline !== undefined) process.env.SITE_OFFLINE = offline;
  }
});

let out;
before(async () => {
  out = await mkdtemp(join(tmpdir(), 'citusmail-site-'));
  await build({ outDir: out, release: null });
});
after(() => rm(out, { recursive: true, force: true }));

test('every page and asset is built', async () => {
  const files = await readdir(out, { recursive: true });
  for (const f of [
    'index.html',
    'privacy-policy.html',
    'terms-of-service.html',
    '404.html',
    'site.css',
    'icon/icon.svg',
    'fonts/IBMPlexSans-Regular-Latin1.woff2',
    'fonts/OFL.txt',
    'screenshots/readme_desktop.png',
  ]) {
    assert.ok(files.includes(f), `missing ${f}`);
  }
});

test('the policy pages carry the docs, and link each other', async () => {
  const privacy = await readFile(join(out, 'privacy-policy.html'), 'utf8');
  assert.match(privacy, /<h1>Citusmail Privacy Policy<\/h1>/);
  assert.match(privacy, /<h2[^>]*>Google user data<\/h2>/);
  assert.match(privacy, /href="\/terms-of-service"/);
  const terms = await readFile(join(out, 'terms-of-service.html'), 'utf8');
  assert.match(terms, /<h1>Citusmail Terms of Service<\/h1>/);
  assert.match(terms, /href="\/privacy-policy"/);
  assert.ok(!terms.includes('.md"'), 'no links to .md files');
});

test('pages load nothing from elsewhere: no remote scripts, styles, fonts or images', async () => {
  for (const page of ['index.html', 'privacy-policy.html', 'terms-of-service.html', '404.html']) {
    const html = await readFile(join(out, page), 'utf8');
    assert.ok(!/<script/i.test(html), `${page} has a script`);
    assert.ok(!/\{\{\w+\}\}/.test(html), `${page} has an unfilled value`);
    const loads = [
      ...html.matchAll(/<(?:img|source|iframe)\b[^>]*\bsrc="([^"]+)"/gi),
      ...html.matchAll(/<link\b[^>]*\brel="(?:stylesheet|icon|preload|apple-touch-icon)"[^>]*\bhref="([^"]+)"/gi),
    ].map((m) => m[1]);
    for (const url of loads) {
      assert.ok(url.startsWith('/'), `${page} loads ${url}`);
    }
  }
  const css = await readFile(join(out, 'site.css'), 'utf8');
  for (const [, url] of css.matchAll(/url\("?([^")]+)"?\)/g)) {
    assert.ok(url.startsWith('/'), `site.css loads ${url}`);
  }
});
