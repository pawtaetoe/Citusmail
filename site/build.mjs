// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Builds the Citusmail website into dist/: the homepage, and the privacy
// policy and terms of service rendered from ../docs (their only source).
// Usage: node build.mjs   (SITE_OFFLINE=1 skips looking up the latest release)

import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..');

export const site = {
  origin: 'https://citusmail.fluminaris.com',
  repo: 'https://github.com/pawtaetoe/Citusmail',
  contact: 'kungchihchia@gmail.com',
};

const releases = `${site.repo}/releases/latest`;

/// Pages built from ../docs: their path on the site and their title.
export const docs = [
  { file: 'privacy-policy.md', path: 'privacy-policy', title: 'Privacy policy' },
  { file: 'terms-of-service.md', path: 'terms-of-service', title: 'Terms of service' },
];

/// A link in a doc, as it should be on the site: other docs by their page,
/// other repository files on GitHub, anything else unchanged.
export function rewriteHref(href) {
  if (/^(?:[a-z]+:|#)/i.test(href)) return href;
  const [path, hash] = href.split('#');
  const name = path.split('/').pop();
  const doc = docs.find((d) => d.file === name);
  if (doc) return `/${doc.path}${hash ? `#${hash}` : ''}`;
  const clean = path.replace(/^(?:\.\.\/|\.\/)+/, '');
  return `${site.repo}/blob/main/${clean}${hash ? `#${hash}` : ''}`;
}

const markdown = new Marked({
  gfm: true,
  walkTokens(token) {
    if (token.type === 'link') token.href = rewriteHref(token.href);
  },
});

/// A doc's Markdown as HTML, without its top heading (the page shows it).
export function renderDoc(md) {
  const body = md.replace(/^# .*\n+/, '');
  return markdown.parse(body);
}

/// The doc's own title: its first "# " line.
export function docHeading(md) {
  return md.match(/^# (.*)$/m)?.[1] ?? '';
}

export function escapeHtml(text) {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

/// Fills {{name}} in a template; an unknown name is an error, so a typo
/// never ships as literal braces.
export function fill(template, values) {
  return template.replace(/\{\{(\w+)\}\}/g, (_, name) => {
    if (!(name in values)) throw new Error(`template value missing: ${name}`);
    return values[name];
  });
}

/// The latest release's version and direct download links, or null when it
/// can't be looked up (offline, rate limited): the buttons then open the
/// release page.
export async function latestRelease(fetchImpl = globalThis.fetch) {
  if (process.env.SITE_OFFLINE) return null;
  try {
    const response = await fetchImpl(
      'https://api.github.com/repos/pawtaetoe/Citusmail/releases/latest',
      {
        headers: { accept: 'application/vnd.github+json' },
        signal: AbortSignal.timeout(8000),
      },
    );
    if (!response.ok) return null;
    const release = await response.json();
    const find = (pattern) =>
      release.assets?.find((a) => pattern.test(a.name))?.browser_download_url;
    return {
      version: String(release.tag_name ?? '').replace(/^v/, ''),
      apk: find(/\.apk$/),
      deb: find(/_amd64\.deb$/),
      flatpak: find(/\.flatpak$/),
      exe: find(/setup.*\.exe$/),
    };
  } catch {
    return null;
  }
}

/// The values the homepage needs about downloads.
export function downloadValues(release) {
  return {
    version: release?.version
      ? `Version ${escapeHtml(release.version)} · `
      : '',
    apk: release?.apk ?? releases,
    deb: release?.deb ?? releases,
    flatpak: release?.flatpak ?? releases,
    exe: release?.exe ?? releases,
    releases,
  };
}

export async function build({
  outDir = join(here, 'dist'),
  release,
} = {}) {
  const shell = await readFile(join(here, 'templates/shell.html'), 'utf8');
  const home = await readFile(join(here, 'templates/home.html'), 'utf8');
  const year = String(new Date().getUTCFullYear());

  const page = ({ path, title, description, content, bodyClass = '' }) =>
    fill(shell, {
      title: escapeHtml(title),
      description: escapeHtml(description),
      canonical: `${site.origin}/${path}`,
      ogImage: `${site.origin}/screenshots/readme_desktop.png`,
      bodyClass,
      content,
      year,
      repo: site.repo,
      releases,
      contact: site.contact,
    });

  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });

  const downloads = downloadValues(
    release === undefined ? await latestRelease() : release,
  );
  await writeFile(
    join(outDir, 'index.html'),
    page({
      path: '',
      title: 'Citusmail: fast, private email',
      description:
        'A free, open-source mail client for Linux, Windows and Android. ' +
        'No server of ours, no tracking: your mail stays between your ' +
        'device and your mail provider.',
      content: fill(home, { ...downloads, repo: site.repo }),
      bodyClass: 'home',
    }),
  );

  for (const doc of docs) {
    const md = await readFile(join(repo, 'docs', doc.file), 'utf8');
    await writeFile(
      join(outDir, `${doc.path}.html`),
      page({
        path: doc.path,
        title: `${doc.title} · Citusmail`,
        description: `${docHeading(md)}: how Citusmail, by Fluminaris, handles this.`,
        content:
          `<article class="doc"><h1>${escapeHtml(docHeading(md))}</h1>\n` +
          `${renderDoc(md)}</article>`,
        bodyClass: 'doc-page',
      }),
    );
  }

  await writeFile(
    join(outDir, '404.html'),
    page({
      path: '404',
      title: 'Page not found · Citusmail',
      description: 'This page does not exist.',
      content:
        '<section class="narrow"><h1>Page not found</h1>' +
        '<p>This page does not exist. <a href="/">Back to Citusmail</a>.</p></section>',
    }),
  );

  await cp(join(here, 'static'), outDir, { recursive: true });
  await cp(join(repo, 'docs/screenshots'), join(outDir, 'screenshots'), {
    recursive: true,
  });
  await mkdir(join(outDir, 'icon'), { recursive: true });
  await cp(join(repo, 'assets/icon/icon.svg'), join(outDir, 'icon/icon.svg'));
  for (const size of [32, 64, 256, 512]) {
    await cp(
      join(repo, `assets/icon/png/${size}.png`),
      join(outDir, `icon/${size}.png`),
    );
  }
  return outDir;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = await build();
  console.log(`Site built in ${out}`);
}
