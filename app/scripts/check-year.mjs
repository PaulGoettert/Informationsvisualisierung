import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

const server = spawn(process.execPath, ['scripts/server.mjs'], {
  env: { ...process.env, PORT: '8766' }, stdio: 'pipe', windowsHide: true
});
const url = 'http://127.0.0.1:8766';
let browser;
async function waitFor(check, seconds = 40) {
  for (let i = 0; i < seconds * 5; i++) { if (await check()) return; await delay(200); }
  throw new Error(`Erwarteter Browserzustand nach ${seconds} Sekunden nicht erreicht.`);
}
async function frame(page) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}
async function login(page, username, password) {
  await page.goto(url);
  await page.locator('#username').fill(username);
  await page.locator('#password').fill(password);
  await page.locator('#login').click();
  await waitFor(async () => await page.locator('#load-data').isEnabled());
}
async function progress(page, completed, errors = 0, seconds = 40) {
  await frame(page);
  await waitFor(async () =>
    await page.locator('#year-progress').getAttribute('data-completed') === String(completed) &&
    await page.locator('#year-progress').getAttribute('data-errors') === String(errors), seconds);
}
function csv(text) {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const fields = line => line.split(';').map(value => value.replace(/^"|"$/g, ''));
  const keys = fields(lines.shift());
  return lines.map(line => Object.fromEntries(fields(line).map((value, index) => [keys[index], value])));
}
function rowsFor(station, start, end, special = false) {
  const rows = [];
  for (let time = Date.parse(start + 'Z'); time < Date.parse(end + 'Z'); time += 600000) {
    const timestamp = new Date(time).toISOString().slice(0, 19);
    const day = timestamp.slice(8, 10);
    if (special && day === '03') continue; // Ganzer Tag ohne Datensätze.
    const row = { station_id: station, timestamp, lufttemperatur_c: 15, rel_feuchte_prozent: 60, quality_class_id: 3 };
    if (special && day === '01') row.lufttemperatur_c = 0; // Echte Null ist vorhanden.
    if (special && day === '02' && timestamp.endsWith('00:00:00')) row.lufttemperatur_c = null;
    if (special && day === '04') row.quality_class_id = 1;
    if (special && day === '05' && timestamp.endsWith('23:50:00')) row.rel_feuchte_prozent = null;
    if (special && day === '06' && timestamp.endsWith('00:00:00')) row.lufttemperatur_c = -999;
    rows.push(row);
  }
  return rows;
}

try {
  await waitFor(async () => { try { return (await fetch(url)).ok; } catch { return false; } });
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  if (process.env.INFOVIS_USER && process.env.INFOVIS_PASSWORD) {
    const started = Date.now();
    await login(page, process.env.INFOVIS_USER, process.env.INFOVIS_PASSWORD);
    await page.locator('#load-year').click();
    await progress(page, 48, 0, 180);
    const actual = await page.locator('[data-year-station]').evaluateAll(panels => panels.flatMap(panel =>
      [...panel.querySelectorAll('button[data-date]')].map(cell => ({
        station: panel.dataset.yearStation, date: cell.dataset.date, state: cell.dataset.state,
        temperature: cell.dataset.mean, temperatureCount: cell.dataset.count,
        humidity: cell.dataset.humidityMean, humidityCount: cell.dataset.humidityCount, gap: cell.dataset.gap
      }))));
    assert.equal(actual.length, 1464);
    const snapshot = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/tagesstatistik.csv', import.meta.url), 'utf8'));
    const reference = new Map(snapshot.map(row => [`${row.StationId}/${row.Date}/${row.Field}`, row]));
    let comparisons = 0;
    for (const day of actual) {
      for (const [field, mean, count] of [
        ['lufttemperatur_c', day.temperature, day.temperatureCount],
        ['rel_feuchte_prozent', day.humidity, day.humidityCount]
      ]) {
        const expected = reference.get(`${day.station}/${day.date}/${field}`);
        assert.ok(expected, `Referenz fehlt für ${day.station}/${day.date}/${field}`);
        assert.equal(Number(count), Number(expected.Valid));
        if (expected.RecommendedUsable === 'True') {
          assert.notEqual(mean, '');
          assert.ok(Math.abs(Number(mean) - Number(expected.RecommendedAggregate.replace(',', '.'))) < 1e-9,
            `Abweichender Mittelwert ${day.station}/${day.date}/${field}`);
        } else assert.equal(mean, '');
        comparisons++;
      }
      const temperature = reference.get(`${day.station}/${day.date}/lufttemperatur_c`);
      assert.equal(Number(day.gap), Number(temperature.MaxGapMinutes));
    }
    for (const [station, count] of [[5629, 354], [2932, 365], [722, 366], [1975, 365]]) {
      assert.equal(await page.locator(`[data-year-station="${station}"] [data-year-valid]`).getAttribute('data-year-valid'), String(count));
    }
    const mapping = csv(await readFile(new URL('../../Entwurf/recursive_pattern_zuordnung.csv', import.meta.url), 'utf8'));
    const positions = await page.locator('[data-year-station="5629"] [data-index]').evaluateAll(cells => cells.map(cell => ({ ...cell.dataset })));
    assert.equal(positions.length, 378);
    positions.forEach((cell, index) => {
      assert.equal(cell.x, mapping[index].X);
      assert.equal(cell.y, mapping[index].Y);
      assert.equal(cell.date || '', mapping[index].Date);
    });
    assert.equal(await page.locator('.year-panel .padding').count(), 48);
    await mkdir('test-results', { recursive: true });
    await page.screenshot({ path: 'test-results/jahresuebersicht.png', fullPage: true });
    await mkdir('../Bericht/Abbildungen', { recursive: true });
    await page.locator('.year-panels').screenshot({ path: '../Bericht/Abbildungen/jahresuebersicht.png' });
    await page.locator('[data-year-station="5629"] [data-date="2024-04-07"]').click();
    await frame(page);
    await waitFor(async () => (await page.locator('[data-summary="5629"]').innerText()).includes('0 / 144'));
    assert.equal(await page.locator('#day').inputValue(), '2024-04-07');
    assert.equal(await page.locator('.year-panel .chosen').count(), 4);
    const report = { checkedAt: new Date().toISOString(), stations: 4, days: actual.length,
      aggregateComparisons: comparisons, mappingPositions: positions.length,
      millisecondsUntilFirstCheck: Date.now() - started,
      validTemperatureDays: { 5629: 354, 2932: 365, 722: 366, 1975: 365 } };
    await writeFile('test-results/jahrespruefung.json', JSON.stringify(report, null, 2));
    console.log(`Live-Jahresprüfung bestanden: ${comparisons} Feld-/Tagesvergleiche mit unabhängigem Nachweis, alle Fehlstellenlängen, 378 Rasterpositionen und Tagesverknüpfung.`);
  } else console.log('Live-Jahresprüfung ausgelassen: INFOVIS_USER und INFOVIS_PASSWORD fehlen.');

  const mock = await browser.newPage();
  mock.on('pageerror', error => errors.push(error.message));
  let fail = true;
  let active = 0;
  let peak = 0;
  let yearRequests = 0;
  let dayRequests = 0;
  let januaryPages = 0;
  let heldYearResponse = null;
  await mock.route('https://dbs.informatik.uni-halle.de/sciencedata/**', async route => {
    const address = new URL(route.request().url());
    if (address.pathname.endsWith('/token')) { await route.fulfill({ json: { token: 'year-test-token' } }); return; }
    const station = Number(address.searchParams.get('station_id').slice(3));
    const bounds = address.searchParams.getAll('timestamp');
    const start = bounds[0].slice(4);
    const end = bounds[1].slice(3);
    if (address.searchParams.get('limit') === '145') {
      dayRequests++;
      await route.fulfill({ json: rowsFor(station, start, end) }); return;
    }
    yearRequests++;
    active++;
    peak = Math.max(peak, active);
    try {
      if (heldYearResponse) await heldYearResponse;
      await delay(30);
      if (fail && station === 722 && start.startsWith('2024-02')) {
        await route.fulfill({ status: 503, json: {} }); return;
      }
      const special = station === 5629 && start.startsWith('2024-01');
      const rows = rowsFor(station, start, end, special);
      if (fail && station === 2932 && start.startsWith('2024-03')) rows[1] = { ...rows[0] };
      const offset = Number(address.searchParams.get('offset'));
      if (special) januaryPages++;
      await route.fulfill({ json: rows.slice(offset, offset + (special ? 1500 : 5000)) });
    } finally { active--; }
  });
  await login(mock, 'test', 'test');
  assert.equal(await mock.locator('[data-year-station="5629"] [data-date="2024-01-01"]').getAttribute('data-state'), 'unloaded');
  await mock.locator('#load-year').click();
  await progress(mock, 46, 2, 90);
  await waitFor(async () => await mock.locator('#load-year').isEnabled());
  assert.ok(peak <= 2, `Zu viele gleichzeitige Jahresanfragen: ${peak}`);
  assert.equal(januaryPages, 4, 'Drei gekürzte Seiten und leere Abschlussseite erwartet');
  const cell = date => mock.locator(`[data-year-station="5629"] [data-date="${date}"]`);
  assert.equal(await cell('2024-01-01').getAttribute('data-mean'), '0');
  assert.equal(await cell('2024-01-01').getAttribute('data-state'), 'complete');
  assert.equal(await cell('2024-01-02').getAttribute('data-count'), '143');
  assert.equal(await cell('2024-01-02').getAttribute('data-gap'), '10');
  assert.equal(await cell('2024-01-02').getAttribute('data-mean'), '');
  assert.equal(await cell('2024-01-03').getAttribute('data-count'), '0');
  assert.equal(await cell('2024-01-03').getAttribute('data-gap'), '1440');
  assert.equal(await cell('2024-01-04').getAttribute('data-state'), 'missing');
  assert.match(await cell('2024-01-04').getAttribute('title'), /Qualitätsklasse/);
  assert.equal(await cell('2024-01-05').getAttribute('data-mean'), '15');
  assert.equal(await cell('2024-01-05').getAttribute('data-humidity-count'), '143');
  assert.equal(await cell('2024-01-05').getAttribute('data-humidity-mean'), '');
  assert.equal(await cell('2024-01-06').getAttribute('data-count'), '143');
  assert.equal(await mock.locator('[data-year-station="722"] [data-date="2024-02-29"]').getAttribute('data-state'), 'load-error');
  assert.match(await mock.locator('[data-year-station="2932"] [data-date="2024-03-01"]').getAttribute('title'), /doppelte Zeitstempel/);
  const beforeRetry = yearRequests;
  fail = false;
  await mock.locator('#load-year').click();
  await progress(mock, 48);
  assert.equal(yearRequests - beforeRetry, 2, 'Nur fehlgeschlagene Monate erneut laden');
  const beforeKey = dayRequests;
  await cell('2024-02-28').focus();
  await mock.keyboard.press('ArrowRight');
  await frame(mock);
  assert.equal(await mock.evaluate(() => document.activeElement.dataset.date), '2024-02-29');
  assert.equal(dayRequests, beforeKey, 'Fokusbewegung darf keinen Datenabruf auslösen');
  await mock.keyboard.press('Enter');
  await frame(mock);
  assert.equal(await mock.locator('#day').inputValue(), '2024-02-29');
  await waitFor(async () => dayRequests === beforeKey + 4);
  await mock.locator('[data-station="2932"]').uncheck();
  await frame(mock);
  assert.equal(await mock.locator('[data-year-station="2932"]').count(), 0);
  assert.equal(await cell('2024-01-01').getAttribute('data-mean'), '0', 'Filter darf Daten nicht verändern');
  await mock.setViewportSize({ width: 390, height: 844 });
  assert.ok(await mock.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await mock.getByRole('button', { name: 'Abmelden', exact: true }).click();
  await frame(mock);
  assert.equal(await cell('2024-01-01').getAttribute('data-state'), 'unloaded');
  await login(mock, 'test', 'test');
  let releaseResponses;
  heldYearResponse = new Promise(resolve => { releaseResponses = resolve; });
  const beforeLogout = yearRequests;
  await mock.locator('#load-year').click();
  await waitFor(async () => active === 2);
  await mock.getByRole('button', { name: 'Abmelden', exact: true }).click();
  await frame(mock);
  releaseResponses();
  await waitFor(async () => active === 0);
  await delay(200);
  await frame(mock);
  assert.equal(yearRequests - beforeLogout, 2, 'Nach Abmeldung dürfen keine weiteren Monate starten');
  assert.equal(await mock.locator('#year-progress').getAttribute('data-completed'), '0');
  assert.equal(await cell('2024-01-01').getAttribute('data-state'), 'unloaded', 'Späte Antworten dürfen die abgemeldete Sitzung nicht verändern');
  assert.deepEqual(errors, []);
  console.log('Kontrollierte Jahresprüfung bestanden: Pagination, maximal zwei Anfragen, Fehler/Wiederholung, Null/Fehlwerte, unabhängige Feldabdeckung, Tastatur, Filter, mobile Breite und Abmeldung mit verspäteten Antworten.');
} finally {
  if (browser) await browser.close();
  server.kill();
}
