import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

if (!process.env.INFOVIS_USER || !process.env.INFOVIS_PASSWORD) throw new Error('Echte Anwendungsfallprüfung benötigt temporäre INFOVIS_USER und INFOVIS_PASSWORD.');
const server = spawn(process.execPath, ['scripts/server.mjs'], { env: { ...process.env, PORT: '8769' }, stdio: 'pipe', windowsHide: true });
let browser;
async function wait(check, seconds = 180) {
  for (let i = 0; i < seconds * 5; i++) { if (await check()) return; await delay(200); }
  throw new Error('Anwendungsfallzustand nicht erreicht.');
}
async function frame(page) { await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); }
function csv(text) {
  const lines = text.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const fields = line => line.split(';').map(v => v.replace(/^"|"$/g, ''));
  const keys = fields(lines.shift());
  return lines.map(line => Object.fromEntries(fields(line).map((value, index) => [keys[index], value])));
}
const number = value => Number(value.replace(',', '.'));
const stats = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/tagesstatistik.csv', import.meta.url), 'utf8'));
const pairs = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/stationsdifferenzen.csv', import.meta.url), 'utf8'));
const available = csv(await readFile(new URL('../../Datenpruefung/ZeitAggregation/profilverfuegbarkeit.csv', import.meta.url), 'utf8'));
const names = { 722: 'Brocken', 1975: 'Hamburg-Fuhlsbuettel', 2932: 'Leipzig/Halle', 5629: 'Wittenberg' };
const fields = ['lufttemperatur_c', 'rel_feuchte_prozent', 'windgeschw_ms', 'niederschlag_mm'];
const stat = (station, date, field) => stats.find(row => row.StationId === String(station) && row.Date === date && row.Field === field);
async function slider(page, id, value) {
  await page.locator(id).evaluate((input, v) => { input.value = String(v); input.dispatchEvent(new Event('input', { bubbles: true })); }, value);
  await frame(page);
}
async function range(page, start, end, requests) {
  await page.locator('#range-start').fill(start); await page.locator('#range-end').fill(end); await page.locator('#apply-range').click(); await frame(page);
  await wait(async () => await page.locator('#range-results').getAttribute('data-start') === start);
  if (requests) await wait(async () => await page.locator('#range-progress').getAttribute('data-completed') === String(requests));
}

try {
  await wait(async () => { try { return (await fetch('http://127.0.0.1:8769')).ok; } catch { return false; } }, 10);
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto('http://127.0.0.1:8769');
  await page.locator('#username').fill(process.env.INFOVIS_USER); await page.locator('#password').fill(process.env.INFOVIS_PASSWORD); await page.locator('#login').click();
  await wait(async () => await page.locator('#load-data').isEnabled());
  await page.locator('#load-year').click(); await wait(async () => await page.locator('#year-progress').getAttribute('data-completed') === '48');
  assert.equal(await page.locator('#year-progress').getAttribute('data-errors'), '0');
  await page.locator('#difference-mode').check(); await frame(page);
  await mkdir('../Bericht/Abbildungen', { recursive: true });
  await range(page, '2024-07-01', '2024-07-31');
  assert.equal(await page.locator('#range-results').getAttribute('data-resolution'), 'daily');
  for (const id of [5629, 722]) assert.equal(await page.locator(`[data-range-count="${id}"]`).innerText(), '31 / 31');
  await page.locator('#range-results svg').screenshot({ path: '../Bericht/Abbildungen/anwendungsfall_monat.png' });
  await range(page, '2024-07-15', '2024-07-21', 14);
  for (const id of [5629, 722]) assert.equal(await page.locator(`[data-range-count="${id}"]`).innerText(), '1008 / 1008');
  const july = Array.from({ length: 7 }, (_, i) => {
    const date = `2024-07-${15 + i}`;
    const wit = number(stat(5629, date, fields[0]).RecommendedAggregate);
    const bro = number(stat(722, date, fields[0]).RecommendedAggregate);
    return { date, wit, bro, difference: wit - bro };
  });
  await page.locator('[data-year-station="0"] [data-date="2024-12-28"]').click(); await frame(page);
  assert.equal(await page.locator('#range-results').count(), 0);
  await wait(async () => (await page.locator('[data-summary="5629"]').innerText()).includes('144 / 144') && (await page.locator('[data-summary="722"]').innerText()).includes('144 / 144'));
  const december = Number(await page.locator('[data-year-station="0"] [data-date="2024-12-28"]').getAttribute('data-mean'));
  assert.ok(Math.abs(december + 10.7152777777778) < 1e-9);
  for (const id of [5629, 722]) {
    const expected = number(stat(id, '2024-12-28', fields[0]).RecommendedAggregate);
    await wait(async () => {
      const label = await page.locator(`[data-summary="${id}"] td`).nth(2).innerText();
      return Math.abs(Number.parseFloat(label.replace(',', '.')) - expected) < 0.006;
    });
  }
  await page.locator('#day-results svg').screenshot({ path: '../Bericht/Abbildungen/anwendungsfall_dezember.png' });
  const overviewWidth = (await page.locator('#annual .recursive-blocks').boundingBox()).width;
  await page.locator('[data-expand-station="0"]').click(); await frame(page);
  assert.ok((await page.locator('#annual .recursive-blocks').boundingBox()).width > overviewWidth + 100);
  await page.locator('#annual .recursive-blocks').screenshot({ path: '../Bericht/Abbildungen/jahresdetail.png' });
  await page.setViewportSize({ width: 390, height: 844 }); await frame(page);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.setViewportSize({ width: 1280, height: 1000 }); await frame(page);
  await page.locator('[data-expand-station="0"]').click(); await frame(page);
  const usablePairs = pairs.filter(r => r.StationA === 'Brocken' && r.StationB === 'Wittenberg' && r.Usable === 'True');
  const positive = usablePairs.filter(r => number(r.DifferenceAminusB) < 0).length;
  const negative = usablePairs.filter(r => number(r.DifferenceAminusB) > 0).length;
  const sorted = [...usablePairs].sort((a, b) => number(a.DifferenceAminusB) - number(b.DifferenceAminusB));

  await page.locator('#reset-selection').click(); await frame(page);
  await page.locator('#load-profiles').click(); await wait(async () => await page.locator('#profile-progress').getAttribute('data-completed') === '96');
  assert.equal(await page.locator('#profile-progress').getAttribute('data-errors'), '0');
  const windReference = stats.filter(r => r.Field === fields[2] && r.RecommendedUsable === 'True' && number(r.RecommendedAggregate) >= 20 && available.some(p => p.Station === r.Station && p.Date === r.Date && p.Usable === 'True'));
  await slider(page, '#filter-2-min', 20);
  const windLines = await page.locator('#profiles polyline[data-match="true"]').evaluateAll(lines => lines.map(line => ({ station: Number(line.dataset.profileStation), date: line.dataset.profileDate, values: line.dataset.values.split(',').map(Number) })));
  assert.equal(windLines.length, 16);
  assert.deepEqual(windLines.map(r => `${names[r.station]}/${r.date}`).sort(), windReference.map(r => `${r.Station}/${r.Date}`).sort());
  assert.equal(await page.locator('#annual button[data-profile-match="true"]').count(), 16);
  assert.equal(await page.locator('#profile-picker option:not([disabled])').count(), 16);
  await page.locator('#profile-picker').selectOption('722/2024-01-22'); await frame(page);
  await page.locator('#profile-picker').focus(); await page.keyboard.press('ArrowDown'); await frame(page);
  assert.equal(await page.locator('#day').inputValue(), '2024-01-23');
  await page.locator('#profile-picker').selectOption('722/2024-01-22'); await frame(page);
  assert.equal(await page.locator('#day').inputValue(), '2024-01-22');
  await wait(async () => (await page.locator('[data-summary="722"]').innerText()).includes('144 / 144'));
  const profiles = [];
  for (const id of [5629, 2932, 722, 1975]) {
    const line = windLines.find(r => r.station === id && r.date === '2024-01-22');
    const values = fields.map(f => number(stat(id, '2024-01-22', f).RecommendedAggregate));
    if (line) line.values.forEach((v, i) => assert.ok(Math.abs(v - values[i]) < 1e-9));
    for (const kind of [0, 1]) {
      const cell = page.locator(`[data-stat-station="${id}"][data-stat-kind="${kind}"][data-stat-date="2024-01-22"]`);
      assert.equal(await cell.getAttribute('data-stat-count'), '144');
      assert.ok(Math.abs(Number(await cell.getAttribute('data-stat-value')) - values[kind + 2]) < 1e-9);
    }
    profiles.push({ station: names[id], values });
  }
  await page.locator('#profiles .chart').screenshot({ path: '../Bericht/Abbildungen/anwendungsfall_wind.png' });
  // Eine fachliche Schnittmenge statt bloßer Maximumsuche: hoher Wind und 0 mm.
  const dryWindReference = windReference.filter(row => number(stat(Number(row.StationId), row.Date, fields[3]).RecommendedAggregate) === 0);
  assert.equal(dryWindReference.length, 0);
  await slider(page, '#filter-3-max', 0);
  assert.equal(await page.locator('#profile-count').getAttribute('data-matching'), '0');
  assert.equal(await page.locator('#profiles polyline[data-match="true"]').count(), 0);
  assert.equal(await page.locator('#annual button[data-profile-match="true"]').count(), 0);
  assert.equal(await page.locator('#profile-picker').isDisabled(), true);
  await page.locator('#profiles .chart').screenshot({ path: '../Bericht/Abbildungen/anwendungsfall_wind_ohne_regen.png' });
  await slider(page, '#filter-3-max', 60);
  assert.equal(await page.locator('#profile-count').getAttribute('data-matching'), '16');
  assert.equal(await page.locator('#profile-picker').isEnabled(), true);
  await page.locator('#reset-filters').click(); await frame(page);
  assert.equal(await page.locator('#profile-count').getAttribute('data-matching'), '1442');
  assert.deepEqual(errors, []);
  await mkdir('../Anwendungsfaelle', { recursive: true });
  await writeFile('../Anwendungsfaelle/nachweise.json', JSON.stringify({ checkedAt: new Date().toISOString(), method: 'Automatisierter echter Browserabruf und unabhängiger CSV-Abgleich; keine Nutzerstudie.', julyWeek: july, julyMonthCoverage: [31, 31], difference: { completeDays: usablePairs.length, witWarmerDays: positive, broWarmerDays: negative, equalDays: usablePairs.length - positive - negative, maximumWitMinusBro: { date: sorted[0].Date, value: -number(sorted[0].DifferenceAminusB) }, minimumWitMinusBro: { date: sorted.at(-1).Date, value: -number(sorted.at(-1).DifferenceAminusB) }, december28: december }, wind: { threshold: 20, matches: windLines.length, allStations: [...new Set(windLines.map(r => names[r.station]))], selectedDay: '2024-01-22', profiles, dryIntersection: { rainUpper: 0, matches: dryWindReference.length, rainMinimum: Math.min(...windReference.map(row => number(stat(Number(row.StationId), row.Date, fields[3]).RecommendedAggregate))), rainMaximum: Math.max(...windReference.map(row => number(stat(Number(row.StationId), row.Date, fields[3]).RecommendedAggregate))) } } }, null, 2));
  console.log('Drei Anwendungsabläufe mit echten HTTP-Daten bestanden: Juli-Monat/Woche, Dezember-Vorzeichenwechsel, 16 Windprofile und leere Schnittmenge mit 0 mm Niederschlag samt Filterrücknahme.');
} finally { if (browser) await browser.close(); server.kill(); }
