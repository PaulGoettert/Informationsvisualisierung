// Wissenschaftliche Vergleichsabbildung; verwendet unabhängig geprüfte Tagesdaten.
// Aufruf aus dem Projektstamm: node Bericht/scripts/generate-comparison.mjs
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const rows = fs.readFileSync(root + 'Datenpruefung/ZeitAggregation/stationsdifferenzen.csv', 'utf8').trim().split(/\r?\n/).slice(1)
  .map(line => line.split(';').map(v => v.replace(/^"|"$/g, '')))
  .filter(r => r[0] === 'Brocken' && r[1] === 'Wittenberg');
assert.equal(rows.length, 366);
const days = new Map(rows.map(r => [r[2], r[7] === 'True' ? -Number(r[8].replace(',', '.')) : null]));
assert.equal(days.size, 366);
assert.equal([...days.values()].filter(v => v !== null).length, 354);
assert.equal([...days.values()].filter(v => v !== null && v > 0).length, 331);
assert.equal([...days.values()].filter(v => v !== null && v < 0).length, 23);
assert.ok(Math.abs(days.get('2024-12-28') + 10.7152777777778) < 1e-9);
const color = v => v === null ? 'bbbbbb' : Math.abs(v) < 1e-9 ? 'f7f7f7' : v <= -10 ? '2166ac' : v <= -5 ? '4393c3' : v <= -2 ? '92c5de' : v < 0 ? 'd1e5f0' : v < 2 ? 'fddbc7' : v < 5 ? 'f4a582' : v < 10 ? 'd6604d' : 'b2182b';
const cell = 7;
const tex = ['% Generiert aus stationsdifferenzen.csv; A=Wittenberg, B=Brocken.', '\\begingroup\\setlength{\\unitlength}{1pt}', '\\begin{picture}(420,266)', '\\put(0,252){\\small (a) Recursive Pattern}', '\\put(225,252){\\small (b) Kalender: Mo bis So}'];
const seen = [new Set(), new Set()];
function paint(x, y, date, layout) {
  assert.ok(days.has(date)); assert.ok(!seen[layout].has(date)); seen[layout].add(date);
  const v = days.get(date);
  tex.push(`\\put(${x},${y}){\\color[HTML]{${color(v)}}\\rule{${cell}pt}{${cell}pt}}`);
  if (v === null) tex.push(`\\put(${x},${y}){\\color{black}\\rotatebox{45}{\\rule{${(cell * Math.SQRT2).toFixed(3)}pt}{0.25pt}}}`);
  if (date === '2024-12-28') tex.push(`\\put(${x},${y}){\\color{black}\\framebox(${cell},${cell}){}}`);
}
const first = Date.UTC(2024, 0, 1);
for (let i = 0; i < 366; i++) {
  const block = Math.floor(i / 42), within = i % 42;
  const x = (block % 3) * 61 + (within % 7) * cell;
  const y = 227 - Math.floor(block / 3) * 65 - Math.floor(within / 7) * cell;
  paint(x, y, new Date(first + i * 86400000).toISOString().slice(0, 10), 0);
}
for (let block = 0; block < 9; block++) tex.push(`\\put(${block % 3 * 61},${240 - Math.floor(block / 3) * 65}){\\scriptsize Block ${block + 1}}`);
const months = ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sep.', 'Okt.', 'Nov.', 'Dez.'];
for (let m = 0; m < 12; m++) {
  const x0 = 225 + (m % 3) * 61, top = 227 - Math.floor(m / 3) * 56;
  tex.push(`\\put(${x0},${top + 13}){\\scriptsize ${months[m]}}`);
  const offset = (new Date(Date.UTC(2024, m, 1)).getUTCDay() + 6) % 7;
  const count = new Date(Date.UTC(2024, m + 1, 0)).getUTCDate();
  for (let d = 1; d <= count; d++) {
    const slot = offset + d - 1;
    paint(x0 + slot % 7 * cell, top - Math.floor(slot / 7) * cell, `2024-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`, 1);
  }
}
assert.deepEqual([...seen[0]].sort(), [...seen[1]].sort());
tex.push('\\put(0,12){\\footnotesize Rahmen: 28. Dezember. Grau mit Diagonale: unvollständig.}', '\\put(0,0){\\footnotesize Weißraum: kein Datum. Gleiche Zellgröße und Farbgrenzen in beiden Ansichten.}', '\\end{picture}\\endgroup');
fs.writeFileSync(root + 'Bericht/Abbildungen/kalendervergleich.tex', tex.join('\n') + '\n');
console.log('Vergleich erzeugt: 366 identische Datenpositionen je Ansicht, 354 gültige / 12 unvollständige Tage.');
