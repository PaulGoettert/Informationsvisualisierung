import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

const server = spawn(process.execPath, ['scripts/server.mjs'], { env: { ...process.env, PORT: '8767' }, stdio: 'pipe', windowsHide: true });
let browser;
async function wait(check, seconds = 120) {
  for (let i = 0; i < seconds * 5; i++) { if (await check()) return; await delay(200); }
  throw new Error('Erwarteter Profilzustand nicht erreicht.');
}
async function frame(page) { await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); }
async function login(page, username, password) {
  await page.goto('http://127.0.0.1:8767');
  await page.locator('#username').fill(username); await page.locator('#password').fill(password); await page.locator('#login').click();
  await wait(async () => await page.locator('#load-data').isEnabled());
}
async function loadTemperature(page) {
  await page.locator('#load-year').click();
  await wait(async () => await page.locator('#year-progress').getAttribute('data-completed') === '48');
}
async function profileDone(page, count, errors = 0) {
  await frame(page);
  await wait(async () => await page.locator('#profile-progress').getAttribute('data-completed') === String(count) && await page.locator('#profile-progress').getAttribute('data-errors') === String(errors));
}
function csv(text) {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const fields = line => line.split(';').map(value => value.replace(/^"|"$/g, ''));
  const keys = fields(lines.shift());
  return lines.map(line => Object.fromEntries(fields(line).map((value, index) => [keys[index], value])));
}
async function slider(page, id, value) {
  await page.locator(id).evaluate((input, number) => { input.value = String(number); input.dispatchEvent(new Event('input', { bubbles: true })); }, value);
  await frame(page);
}
async function linkChecks(page) {
  const before = await page.locator('#profiles svg').getAttribute('viewBox');
  await slider(page, '#filter-2-min', 20);
  const count = Number(await page.locator('#profile-count').getAttribute('data-matching'));
  assert.ok(count > 0 && count < 1442);
  assert.equal(await page.locator('#annual button[data-profile-match="true"]').count(), count);
  const point = page.locator('#profiles polyline[data-match="true"]').first();
  const date = await point.getAttribute('data-profile-date');
  const station = await point.getAttribute('data-profile-station');
  await point.focus(); await page.keyboard.press('Enter'); await frame(page);
  assert.equal(await page.locator('#day').inputValue(), date);
  await wait(async () => await page.locator(`#day-results [data-series="${station}"]`).getAttribute('data-profile-match') === 'true');
  assert.equal(await page.locator('#profiles svg').getAttribute('viewBox'), before);
  await slider(page, '#filter-3-min', 60);
  assert.equal(await page.locator('#profile-count').getAttribute('data-matching'), '0');
  assert.equal(await page.locator('#annual button[data-profile-match="true"]').count(), 0);
  await page.locator('#reset-filters').click(); await frame(page);
  assert.equal(await page.locator('#annual button[data-profile-match="false"]').count(), 0);
  assert.equal(await page.locator('#day-results [data-series][data-profile-match="false"]').count(), 0);
}

try {
  await wait(async () => { try { return (await fetch('http://127.0.0.1:8767')).ok; } catch { return false; } }, 10);
  browser = await chromium.launch({ headless: true });
  const errors = [];
  if (process.env.INFOVIS_USER && process.env.INFOVIS_PASSWORD) {
    const live = await browser.newPage(); live.on('pageerror', error => errors.push(error.message));
    await login(live, process.env.INFOVIS_USER, process.env.INFOVIS_PASSWORD);
    assert.equal(await live.locator('#load-profiles').isDisabled(), true);
    await loadTemperature(live);
    await live.locator('#load-profiles').click(); await profileDone(live, 96);
    assert.equal(await live.locator('#profile-count').getAttribute('data-total'), '1442');
    assert.equal(await live.locator('#profile-count').getAttribute('data-excluded'), '22');
    const actual = await live.locator('#profiles polyline[data-values]').evaluateAll(lines => lines.map(line => ({ station: line.dataset.profileStation, date: line.dataset.profileDate, values: line.dataset.values.split(',').map(Number) })));
    const source = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/tagesstatistik.csv', import.meta.url), 'utf8'));
    const reference = new Map(source.map(row => [`${row.StationId}/${row.Date}/${row.Field}`, row]));
    const fields = ['lufttemperatur_c', 'rel_feuchte_prozent', 'windgeschw_ms', 'niederschlag_mm'];
    const domains = [[-15, 30], [0, 100], [0, 30], [0, 60]];
    let comparisons = 0;
    for (const point of actual) point.values.forEach((value, index) => {
      const expected = reference.get(`${point.station}/${point.date}/${fields[index]}`);
      assert.equal(expected.RecommendedUsable, 'True');
      assert.ok(Math.abs(value - Number(expected.RecommendedAggregate.replace(',', '.'))) < 1e-9);
      assert.ok(value >= domains[index][0] && value <= domains[index][1], 'Skala darf kein Profil abschneiden');
      comparisons++;
    });
    const names = { Brocken: '722', Wittenberg: '5629', 'Leipzig/Halle': '2932', 'Hamburg-Fuhlsbuettel': '1975' };
    const expectedProfiles = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/profilverfuegbarkeit.csv', import.meta.url), 'utf8'))
      .filter(row => row.Usable === 'True').map(row => `${names[row.Station]}/${row.Date}`).sort();
    assert.deepEqual(actual.map(point => `${point.station}/${point.date}`).sort(), expectedProfiles);
    for (const date of ['2024-12-31', source.find(row => row.Field === 'niederschlag_mm' && row.RecommendedUsable === 'False').Date]) {
      await live.locator(`[data-year-station="722"] [data-date="${date}"]`).click(); await frame(live);
      for (const cell of await live.locator('[data-stat-kind]').evaluateAll(cells => cells.map(cell => ({ ...cell.dataset })))) {
        const expected = reference.get(`${cell.statStation}/${date}/${cell.statKind === '0' ? 'windgeschw_ms' : 'niederschlag_mm'}`);
        assert.equal(Number(cell.statCount), Number(expected.Valid));
        assert.equal(Number(cell.statGap), Number(expected.MaxGapMinutes));
        if (expected.RecommendedUsable === 'True') assert.ok(Math.abs(Number(cell.statValue) - Number(expected.RecommendedAggregate.replace(',', '.'))) < 1e-9);
        else assert.equal(cell.statValue, '');
      }
    }
    await mkdir('../Bericht/Abbildungen', { recursive: true });
    await live.locator('#profiles .chart').screenshot({ path: '../Bericht/Abbildungen/parallele_koordinaten.png' });
    await linkChecks(live);
    await mkdir('test-results', { recursive: true });
    await writeFile('test-results/profilpruefung.json', JSON.stringify({ checkedAt: new Date().toISOString(), profiles: actual.length, excluded: 22, comparisons, intervalMonths: 96 }, null, 2));
    console.log(`Live-Profilprüfung bestanden: ${actual.length} Profile, ${comparisons} Kennzahlen, Ausschlüsse, Intervallgrenzen und Filterverknüpfungen.`);
  } else console.log('Live-Profilprüfung ausgelassen: Zugangsdaten fehlen.');

  const mock = await browser.newPage(); mock.on('pageerror', error => errors.push(error.message));
  let active = 0, peak = 0, requests = 0, fail = true, januaryPages = 0;
  let held = null;
  await mock.route('https://dbs.informatik.uni-halle.de/sciencedata/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith('/token')) { await route.fulfill({ json: { token: 'profile-test-token' } }); return; }
    const station = Number(url.searchParams.get('station_id').slice(3));
    const bounds = url.searchParams.getAll('timestamp');
    const interval = !url.pathname.endsWith('v_air_temperature');
    const rain = url.pathname.endsWith('v_precipitation');
    const start = bounds[0].slice(interval ? 3 : 4), end = bounds[1].slice(interval ? 4 : 3);
    const offset = Number(url.searchParams.get('offset') || 0);
    if (interval) { assert.ok(bounds[0].startsWith('gt.')); assert.ok(bounds[1].startsWith('lte.')); requests++; active++; peak = Math.max(peak, active); }
    try {
      if (interval && held) await held;
      if (interval) await delay(15);
      if (interval && fail && station === 722 && rain && start.startsWith('2024-02')) { await route.fulfill({ status: 503, json: {} }); return; }
      const rows = [];
      for (let time = Date.parse(start + 'Z') + (interval ? 600000 : 0); interval ? time <= Date.parse(end + 'Z') : time < Date.parse(end + 'Z'); time += 600000) {
        const timestamp = new Date(time).toISOString().slice(0, 19);
        const row = { station_id: station, timestamp, quality_class_id: 3 };
        if (interval) {
          const midnight = timestamp.endsWith('T00:00:00');
          row[rain ? 'niederschlag_mm' : 'windgeschw_ms'] = rain ? (midnight ? 10 : 0) : (midnight ? 144 : 1);
          if (rain && station === 5629 && timestamp === '2024-01-02T00:00:00') row.niederschlag_mm = null;
        } else { row.lufttemperatur_c = 15; row.rel_feuchte_prozent = 60; }
        rows.push(row);
      }
      const special = interval && station === 5629 && start.startsWith('2024-01');
      if (special) januaryPages++;
      await route.fulfill({ json: rows.slice(offset, offset + (special ? 1500 : Number(url.searchParams.get('limit')))) });
    } finally { if (interval) active--; }
  });
  await login(mock, 'test', 'test'); await loadTemperature(mock);
  await mock.locator('#load-profiles').click(); await profileDone(mock, 95, 1);
  await wait(async () => await mock.locator('#load-profiles').isEnabled());
  assert.ok(peak <= 2); assert.equal(januaryPages, 6);
  const before = requests; fail = false;
  await mock.locator('#load-profiles').click(); await profileDone(mock, 96);
  assert.equal(requests - before, 1);
  assert.equal(await mock.locator('#profile-count').getAttribute('data-total'), '1463');
  await slider(mock, '#filter-3-min', 11);
  await mock.locator('#profile-display').selectOption('matching'); await frame(mock);
  assert.equal(await mock.locator('#profile-drawn').getAttribute('data-drawn'), '0');
  assert.equal(await mock.locator('#profiles polyline').count(), 0);
  await mock.locator('#reset-filters').click(); await frame(mock);
  await mock.locator('#profile-display').selectOption('day'); await frame(mock);
  assert.equal(await mock.locator('#profile-drawn').getAttribute('data-drawn'), '4');
  assert.equal(await mock.locator('#profile-count').getAttribute('data-matching'), '1463');
  await mock.locator('#reset-filters').click(); await frame(mock);
  await mock.locator('#profile-search').fill('brocken 2024-01'); await frame(mock);
  assert.equal(await mock.locator('#profile-picker option:not([disabled])').count(), 31);
  await mock.locator('#profile-search').fill('BROCKEN 22.01.2024'); await frame(mock);
  assert.equal(await mock.locator('#profile-picker option:not([disabled])').count(), 1);
  assert.equal(await mock.locator('#profile-count').getAttribute('data-matching'), '1463');
  await mock.locator('#profile-picker').selectOption('722/2024-01-22'); await frame(mock);
  await mock.locator('#profile-search').fill('nicht vorhanden'); await frame(mock);
  assert.equal(await mock.locator('#profile-picker').isDisabled(), true);
  await mock.locator('#reset-filters').click(); await frame(mock);
  assert.equal(await mock.locator('#profile-search').inputValue(), '');
  assert.equal(await mock.locator('#profile-picker option:not([disabled])').count(), 1463);
  const last = mock.locator('#profiles [data-profile-station="722"][data-profile-date="2024-12-31"]');
  assert.ok(Math.abs(Number((await last.getAttribute('data-values')).split(',')[2]) - 287 / 144) < 1e-9);
  assert.equal(Number((await last.getAttribute('data-values')).split(',')[3]), 10);
  await mock.locator('[data-year-station="5629"] [data-date="2024-01-01"]').click(); await frame(mock);
  const missing = mock.locator('[data-stat-station="5629"][data-stat-kind="1"]');
  assert.equal(await missing.getAttribute('data-stat-count'), '143'); assert.equal(await missing.getAttribute('data-stat-value'), '');
  await slider(mock, '#filter-3-min', 11);
  assert.equal(await mock.locator('#profile-count').getAttribute('data-matching'), '0');
  assert.equal(await mock.locator('#annual button[data-profile-match="true"]').count(), 0);
  await mock.locator('#reset-filters').click(); await frame(mock);
  await mock.setViewportSize({ width: 390, height: 844 });
  assert.ok(await mock.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await mock.getByRole('button', { name: 'Abmelden', exact: true }).click(); await frame(mock);
  await login(mock, 'test', 'test'); await loadTemperature(mock);
  let release; held = new Promise(resolve => { release = resolve; });
  const prior = requests;
  await mock.locator('#load-profiles').click(); await wait(async () => active === 2);
  await mock.getByRole('button', { name: 'Abmelden', exact: true }).click(); await frame(mock); release();
  await wait(async () => active === 0); await delay(200); await frame(mock);
  assert.equal(requests - prior, 2);
  assert.equal(await mock.locator('#profile-progress').getAttribute('data-completed'), '0');
  assert.deepEqual(errors, []);
  console.log('Kontrollierte Profilprüfung bestanden: Mitternachts-/Jahresgrenzen, Summe/Mittel, echte Null, Fehlwerte, Pagination, Fehlerwiederholung, Filter, mobile Breite und verspätete Antworten.');
} finally { if (browser) await browser.close(); server.kill(); }
