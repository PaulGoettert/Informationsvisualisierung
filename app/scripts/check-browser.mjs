import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

const server = spawn(process.execPath, ['scripts/server.mjs'], {
  env: { ...process.env, PORT: '8765' }, stdio: 'pipe', windowsHide: true
});
const url = 'http://127.0.0.1:8765';
let browser;
async function waitFor(check) {
  for (let i = 0; i < 150; i++) { if (await check()) return; await delay(200); }
  throw new Error('Erwarteter Browserzustand nach 30 Sekunden nicht erreicht.');
}
async function connect(page, username, password) {
  await page.goto(url);
  await page.locator('#username').fill(username);
  await page.locator('#password').fill(password);
  await page.locator('#login').click();
}
async function complete(page, count) {
  // Elm rendert nach dem Klick im nächsten Frame; alte Tabellen sind noch kurz sichtbar.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await waitFor(async () => await page.locator('[data-summary]').count() === count &&
    !(await page.locator('[data-summary]').allTextContents()).some(t => t.includes('Lädt')));
}
try {
  await waitFor(async () => { try { return (await fetch(url)).ok; } catch { return false; } });
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  if (process.env.INFOVIS_USER && process.env.INFOVIS_PASSWORD) {
    await connect(page, process.env.INFOVIS_USER, process.env.INFOVIS_PASSWORD);
    await complete(page, 4);
    for (const row of await page.locator('[data-summary]').allTextContents()) {
      assert.ok(row.includes('144 / 144') && row.includes('Vollständig'), row);
    }
    assert.equal(await page.locator('#day-results svg polyline').count(), 4);
    await mkdir('test-results', { recursive: true });
    await page.screenshot({ path: 'test-results/temperaturvergleich.png', fullPage: true });
    await page.locator('[data-station="2932"]').uncheck();
    await page.locator('#load-data').click();
    await complete(page, 3);
    assert.equal(await page.locator('[data-summary="2932"]').count(), 0);
    for (const station of [722, 1975]) await page.locator(`[data-station="${station}"]`).uncheck();
    await page.locator('#day').fill('2024-04-07');
    await page.locator('#load-data').click();
    await complete(page, 1);
    assert.match(await page.locator('[data-summary="5629"]').innerText(), /0 \/ 144/);
    assert.equal(await page.locator('#day-results svg').count(), 0);
    await page.locator('#day').fill('2024-04-06');
    await page.locator('#load-data').click();
    await complete(page, 1);
    assert.match(await page.locator('[data-summary="5629"]').innerText(), /Nicht verfügbar/);
    assert.ok(await page.locator('#day-results svg polyline').count() > 0);
    await page.locator('[data-station="5629"]').uncheck();
    await page.locator('#load-data').click();
    await waitFor(async () => (await page.locator('body').innerText()).includes('mindestens eine Station'));
    assert.deepEqual(await page.evaluate(() => [localStorage.length, sessionStorage.length]), [0, 0]);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    console.log('Live-Browserprüfung: direkter Uni-HTTP-Zugriff, vier Stationen, Auswahl, Fehlwerte, leere Auswahl, mobile Breite bestanden.');
  } else {
    console.log('Live-Prüfung ausgelassen: INFOVIS_USER und INFOVIS_PASSWORD fehlen.');
  }

  // Kontrollierte Antworten prüfen Fehler und Kalendergrenzen ohne Serverlast.
  const mock = await browser.newPage();
  let mode = 'valid';
  let held = [];
  let dayRequests = 0;
  let seenBounds;
  await mock.route('https://dbs.informatik.uni-halle.de/sciencedata/**', async route => {
    const request = route.request();
    const address = new URL(request.url());
    if (address.pathname.endsWith('/token')) {
      await route.fulfill({ json: { token: 'browser-test-token' } }); return;
    }
    seenBounds = address.search;
    dayRequests++;
    const station = Number(address.searchParams.get('station_id').slice(3));
    const day = address.searchParams.getAll('timestamp')[0].slice(4, 14);
    const row = { station_id: station, timestamp: `${day}T00:00:00`, lufttemperatur_c: 20, rel_feuchte_prozent: 50, quality_class_id: 3 };
    if (mode === 'held') await new Promise(resolve => held.push(resolve));
    if (mode === 'network') { await route.abort('failed'); return; }
    if (mode === 'malformed') { await route.fulfill({ json: { unexpected: true } }); return; }
    if (mode === 'duplicate') { await route.fulfill({ json: [row, row] }); return; }
    if (mode === 'unauthorized') { await route.fulfill({ status: 401, json: {} }); return; }
    if (mode === 'gap') {
      await route.fulfill({ json: [row, { ...row, timestamp: `${day}T00:10:00`, lufttemperatur_c: -99.9 }, { ...row, timestamp: `${day}T00:20:00` }] }); return;
    }
    await route.fulfill({ json: [row] });
  });
  await connect(mock, 'test', 'test');
  await complete(mock, 4);
  for (const [nextMode, expected] of [
    ['network', 'nicht erreichbar'], ['malformed', 'Datenformat'],
    ['duplicate', 'doppelte Zeitstempel'], ['unauthorized', 'abgelehnt']
  ]) {
    mode = nextMode;
    await mock.locator('#load-data').click();
    await complete(mock, 4);
    assert.ok((await mock.locator('[data-summary]').first().innerText()).includes(expected));
  }
  mode = 'gap';
  await mock.locator('#day').fill('2024-02-29');
  await mock.locator('#load-data').click();
  await complete(mock, 4);
  assert.ok(seenBounds.includes('lt.2024-03-01T00:00:00'));
  assert.equal(await mock.locator('#day-results svg polyline').count(), 0, 'Fehlstelle darf nicht überbrückt werden');
  assert.equal(await mock.locator('#day-results svg circle').count(), 8);
  mode = 'valid';
  await mock.locator('#day').fill('2024-12-31');
  await mock.locator('#load-data').click();
  await complete(mock, 4);
  assert.ok(seenBounds.includes('lt.2025-01-01T00:00:00'));
  // Stationswechsel übernimmt den geladenen Tag, nicht eine noch offene Datumseingabe.
  mode = 'held';
  await mock.locator('#day').fill('2024-12-30');
  await mock.locator('#load-data').click();
  await waitFor(() => held.length === 4);
  await mock.locator('#day').fill('2024-01-01');
  await mock.locator('[data-station="2932"]').uncheck();
  await waitFor(() => held.length === 7);
  await mock.locator('[data-station="722"]').uncheck();
  await waitFor(() => held.length === 9);
  mode = 'valid'; held.splice(0).forEach(resolve => resolve());
  await complete(mock, 2);
  assert.equal(await mock.locator('#day').inputValue(), '2024-01-01');
  assert.ok(seenBounds.includes('gte.2024-12-30'));
  assert.equal(await mock.locator('[data-summary="2932"], [data-summary="722"]').count(), 0);
  mode = 'held';
  await mock.locator('#day').fill('2024-12-30');
  await mock.locator('#load-data').click();
  await waitFor(() => held.length === 2);
  await mock.locator('#day').fill('2024-01-01');
  await mock.locator('[data-station="5629"]').uncheck();
  await waitFor(() => held.length === 3);
  await mock.locator('[data-station="1975"]').uncheck();
  mode = 'valid'; held.splice(0).forEach(resolve => resolve());
  await delay(150);
  await complete(mock, 0);
  await mock.locator('[data-station="2932"]').check();
  await complete(mock, 1);
  assert.equal(await mock.locator('[data-summary="2932"]').count(), 1);
  assert.equal(await mock.locator('#day').inputValue(), '2024-01-01');
  await mock.locator('[data-station="1975"]').check();
  await delay(350); await complete(mock, 2);
  const cachedRequests = dayRequests;
  await mock.locator('[data-station="1975"]').uncheck();
  await mock.locator('[data-station="1975"]').check();
  await mock.locator('[data-station="1975"]').uncheck();
  await delay(400); await complete(mock, 1);
  assert.equal(dayRequests, cachedRequests, 'Schnelle Änderungen und vorhandener Tagescache dürfen keinen Abruf auslösen');
  await mock.locator('#day').fill('2024-12-30');
  await mock.locator('#load-data').click(); await complete(mock, 1);
  assert.equal(dayRequests, cachedRequests + 1, 'Explizites Laden muss den Cache umgehen');
  assert.deepEqual(errors, []);
  console.log('Browserprüfung: Netzwerk-/JSON-/401-Fehler, Duplikate, Schaltjahr, Jahresgrenze und getrennte Linien bei Fehlwerten bestanden.');
} finally {
  if (browser) await browser.close();
  server.kill();
}
