import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

const server = spawn(process.execPath, ['scripts/server.mjs'], { env: { ...process.env, PORT: '8768' }, stdio: 'pipe', windowsHide: true });
let browser;
async function wait(check, seconds = 120) {
  for (let i = 0; i < seconds * 5; i++) { if (await check()) return; await delay(200); }
  throw new Error('Erwarteter Vergleichszustand nicht erreicht.');
}
async function frame(page) { await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); }
async function login(page, user, password) {
  await page.goto('http://127.0.0.1:8768'); await page.locator('#username').fill(user); await page.locator('#password').fill(password); await page.locator('#login').click();
  await wait(async () => await page.locator('#load-data').isEnabled());
}
async function apply(page, start, end, raw, requests) {
  await page.locator('#range-start').fill(start); await page.locator('#range-end').fill(end); await page.locator('#apply-range').click(); await frame(page);
  await wait(async () => await page.locator('#range-results').getAttribute('data-start') === start && await page.locator('#range-results').getAttribute('data-end') === end);
  assert.equal(await page.locator('#range-results').getAttribute('data-resolution'), raw ? 'raw' : 'daily');
  if (raw) await wait(async () => await page.locator('#range-progress').getAttribute('data-completed') === String(requests));
}
function csv(text) {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const fields = line => line.split(';').map(value => value.replace(/^"|"$/g, ''));
  const keys = fields(lines.shift()); return lines.map(line => Object.fromEntries(fields(line).map((value, index) => [keys[index], value])));
}

try {
  await wait(async () => { try { return (await fetch('http://127.0.0.1:8768')).ok; } catch { return false; } }, 10);
  browser = await chromium.launch({ headless: true });
  const errors = [];
  if (process.env.INFOVIS_USER && process.env.INFOVIS_PASSWORD) {
    const live = await browser.newPage(); live.on('pageerror', error => errors.push(error.message));
    await login(live, process.env.INFOVIS_USER, process.env.INFOVIS_PASSWORD);
    await live.locator('#load-year').click(); await wait(async () => await live.locator('#year-progress').getAttribute('data-completed') === '48');
    await live.locator('#difference-mode').check(); await frame(live);
    const reference = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/stationsdifferenzen.csv', import.meta.url), 'utf8'));
    const names = { 722: 'Brocken', 1975: 'Hamburg-Fuhlsbuettel', 2932: 'Leipzig/Halle', 5629: 'Wittenberg' };
    let comparisons = 0;
    for (const [a, b] of [[722, 1975], [722, 2932], [722, 5629], [1975, 2932], [1975, 5629], [2932, 5629]]) {
      // Erst das Gegenfeld wegsetzen, falls die gewünschte A-Station derzeit B ist.
      const currentA = Number(await live.locator('#station-a').inputValue());
      if (Number(await live.locator('#station-b').inputValue()) === a) await live.locator('#station-b').selectOption(String([722, 1975, 2932, 5629].find(id => id !== a && id !== currentA)));
      await live.locator('#station-a').selectOption(String(a)); await frame(live);
      await live.locator('#station-b').selectOption(String(b)); await frame(live);
      const actual = await live.locator('[data-year-station="0"] button[data-date]').evaluateAll(cells => cells.map(cell => ({ ...cell.dataset })));
      assert.equal(actual.length, 366);
      for (const row of actual) {
        const expected = reference.find(item => item.StationA === names[a] && item.StationB === names[b] && item.Date === row.date);
        assert.ok(expected); assert.equal(Number(row.count), Number(expected.CommonValid)); assert.equal(Number(row.gap), Number(expected.MaxGapMinutes));
        if (expected.Usable === 'True') assert.ok(Math.abs(Number(row.mean) - Number(expected.DifferenceAminusB.replace(',', '.'))) < 1e-9);
        else assert.equal(row.mean, '');
        comparisons++;
      }
    }
    // Umkehrung prüft das Vorzeichen an einem vollständigen Tag.
    await live.locator('#station-b').selectOption('722'); await frame(live);
    await live.locator('#station-a').selectOption('5629'); await frame(live);
    const positive = Number(await live.locator('[data-year-station="0"] [data-date="2024-07-15"]').getAttribute('data-mean'));
    assert.ok(positive > 0);
    await mkdir('../Bericht/Abbildungen', { recursive: true });
    // Der Bericht zeigt das Raster groß; die Legende wird lesbar in LaTeX gesetzt.
    await live.locator('#annual .year-panel').screenshot({ path: '../Bericht/Abbildungen/differenzmodus.png' });
    await apply(live, '2024-07-15', '2024-07-21', true, 14);
    for (const station of [5629, 722]) assert.equal(await live.locator(`[data-range-count="${station}"]`).innerText(), '1008 / 1008');
    assert.equal(await live.locator('#annual [data-in-range="true"]').count(), 7);
    await live.locator('#range-results svg').screenshot({ path: '../Bericht/Abbildungen/mehrtagesansicht.png' });
    await apply(live, '2024-07-15', '2024-07-22', false);
    assert.equal(await live.locator('#range-results').getAttribute('data-days'), '8');
    for (const station of [5629, 722]) assert.equal(await live.locator(`[data-range-count="${station}"]`).innerText(), '8 / 8');
    await live.locator('#load-profiles').click(); await wait(async () => await live.locator('#profile-progress').getAttribute('data-completed') === '96');
    assert.equal(await live.locator('#profile-count').getAttribute('data-total'), '16');
    assert.equal(await live.locator('#profile-count').getAttribute('data-excluded'), '0');
    await live.locator('#reset-selection').click(); await frame(live);
    assert.equal(await live.locator('#range-results').count(), 0); assert.equal(await live.locator('#difference-mode').isChecked(), false);
    assert.equal(await live.locator('#profile-count').getAttribute('data-total'), '1442');
    await apply(live, '2024-12-30', '2024-12-31', true, 8);
    assert.equal(await live.locator('#range-results').getAttribute('data-days'), '2');
    await mkdir('test-results', { recursive: true });
    await writeFile('test-results/vergleichspruefung.json', JSON.stringify({ checkedAt: new Date().toISOString(), pairDays: comparisons, positiveWittenbergMinusBrockenJuly15: positive, sevenDaysRaw: 1008, eightDaysDaily: 8 }, null, 2));
    console.log(`Live-Vergleichsprüfung bestanden: ${comparisons} Paar-/Tagesdifferenzen samt gemeinsamer Abdeckung, Vorzeichen, 7/8-Tage-Grenze, Zeitraumfilter, Jahresende und globales Zurücksetzen.`);
  } else console.log('Live-Vergleichsprüfung ausgelassen: Zugangsdaten fehlen.');

  const mock = await browser.newPage(); mock.on('pageerror', error => errors.push(error.message));
  let held = null, oldRequests = 0, dayRequests = 0;
  await mock.route('https://dbs.informatik.uni-halle.de/sciencedata/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith('/token')) { await route.fulfill({ json: { token: 'comparison-test-token' } }); return; }
    const station = Number(url.searchParams.get('station_id').slice(3));
    const bounds = url.searchParams.getAll('timestamp'); const start = bounds[0].slice(4), end = bounds[1].slice(3);
    const dayQuery = url.searchParams.get('limit') === '145';
    if (dayQuery) dayRequests++;
    if (held && dayQuery && start.startsWith('2024-01')) { oldRequests++; await held; }
    if (dayQuery && station === 5629 && start.startsWith('2024-03-03')) { await route.fulfill({ status: 503, json: {} }); return; }
    const rows = [];
    for (let time = Date.parse(start + 'Z'); time < Date.parse(end + 'Z'); time += 600000) {
      const timestamp = new Date(time).toISOString().slice(0, 19);
      const missing = station === 5629 && timestamp.startsWith('2024-03-02');
      rows.push({ station_id: station, timestamp, lufttemperatur_c: missing ? null : station === 722 ? 10 : 15, rel_feuchte_prozent: 50, quality_class_id: 3 });
    }
    const offset = Number(url.searchParams.get('offset') || 0);
    await route.fulfill({ json: rows.slice(offset, offset + Number(url.searchParams.get('limit'))) });
  });
  await login(mock, 'test', 'test');
  await mock.locator('#range-start').fill('2024-03-01'); await mock.locator('#range-end').fill('2024-03-08'); await mock.locator('#apply-range').click(); await frame(mock);
  assert.equal(await mock.locator('#range-results').count(), 0);
  assert.match(await mock.locator('.controls .feedback').innerText(), /Jahresdaten/);
  await mock.locator('#load-year').click(); await wait(async () => await mock.locator('#year-progress').getAttribute('data-completed') === '48');
  await mock.locator('#difference-mode').check(); await frame(mock);
  assert.equal(await mock.locator('[data-year-station="0"] [data-date="2024-03-02"]').getAttribute('data-count'), '0');
  assert.equal(await mock.locator('[data-year-station="0"] [data-date="2024-03-02"]').getAttribute('data-mean'), '');
  await apply(mock, '2024-03-01', '2024-03-03', true, 6);
  assert.match(await mock.locator('#range-results .error').innerText(), /HTTP 503/);
  assert.equal(await mock.locator('[data-range-series="5629"][data-layer="context"] polyline').count(), 1);
  await apply(mock, '2024-03-01', '2024-03-08', false);
  assert.equal(await mock.locator('[data-range-count="5629"]').innerText(), '7 / 8');
  assert.equal(await mock.locator('[data-range-series="5629"][data-layer="context"] circle').count(), 1);
  assert.equal(await mock.locator('[data-range-series="5629"][data-layer="context"] polyline').count(), 1);
  await mock.locator('#range-start').fill('2024-03-08'); await mock.locator('#range-end').fill('2024-03-01'); await mock.locator('#apply-range').click(); await frame(mock);
  assert.match(await mock.locator('.controls .feedback').innerText(), /nach seinem Ende/);
  await apply(mock, '2024-02-28', '2024-03-01', true, 6); assert.equal(await mock.locator('#range-results').getAttribute('data-days'), '3');
  let release; held = new Promise(resolve => { release = resolve; });
  await mock.locator('#range-start').fill('2024-01-01'); await mock.locator('#range-end').fill('2024-01-02'); await mock.locator('#apply-range').click();
  await wait(async () => oldRequests >= 2);
  await apply(mock, '2024-03-04', '2024-03-05', true, 4);
  release(); await delay(300); await frame(mock);
  assert.equal(await mock.locator('#range-results').getAttribute('data-start'), '2024-03-04');
  assert.equal(await mock.locator('#range-progress').getAttribute('data-completed'), '4');
  await mock.locator('[data-year-station="0"] [data-date="2024-04-01"]').click(); await frame(mock);
  assert.equal(await mock.locator('#range-results').count(), 0);
  await mock.locator('#difference-mode').uncheck(); await frame(mock);
  await apply(mock, '2024-03-04', '2024-03-05', true, 8);
  await mock.locator('[data-station="2932"]').uncheck(); await frame(mock);
  await wait(async () => await mock.locator('#range-progress').getAttribute('data-completed') === '6');
  assert.equal(await mock.locator('[data-range-count="2932"]').count(), 0);
  assert.equal(await mock.locator('#range-results').getAttribute('data-start'), '2024-03-04');
  await mock.locator('[data-station="2932"]').check(); await frame(mock);
  await wait(async () => await mock.locator('#range-progress').getAttribute('data-completed') === '8');
  assert.equal(await mock.locator('[data-range-count="2932"]').innerText(), '288 / 288');
  const beforeCached = dayRequests;
  await apply(mock, '2024-03-04', '2024-03-05', true, 8);
  assert.equal(dayRequests, beforeCached, 'Vorhandene Zeitraumdaten werden wiederverwendet');
  await mock.locator('#reload-range').click();
  await frame(mock);
  await wait(async () => await mock.locator('#range-progress').getAttribute('data-completed') === '8');
  // Acht Zeitraumreihen und vier synchronisierte Detailreihen werden frisch geladen.
  await wait(async () => dayRequests === beforeCached + 12);
  assert.equal(dayRequests, beforeCached + 12, 'Expliziter Zeitraumabruf umgeht beide Rohwertcaches');
  await mock.setViewportSize({ width: 390, height: 844 }); assert.ok(await mock.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await mock.getByRole('button', { name: 'Abmelden', exact: true }).click(); await frame(mock); assert.equal(await mock.locator('#range-results').count(), 0);
  assert.deepEqual(errors, []);
  console.log('Kontrollierte Vergleichsprüfung bestanden: Fehlwerte/Abruffehler, offene Linienlücken, Schaltjahr, ungültiger Zeitraum, Jahresdaten-Voraussetzung, verspätete Antworten, Auswahlverknüpfung, mobile Breite und Abmeldung.');
} finally { if (browser) await browser.close(); server.kill(); }
