// Dieselben vollständigen Profile wie im Wind-Anwendungsfall; keine neuen Messdaten.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
function csv(path) {
  const rows = fs.readFileSync(root + path, 'utf8').trim().split(/\r?\n/).map(line => line.split(';').map(v => v.replace(/^"|"$/g, '')));
  return rows.slice(1).map(row => Object.fromEntries(rows[0].map((key, i) => [key, row[i]])));
}
const stats = new Map(csv('Datenpruefung/ZeitAggregation/tagesstatistik.csv').map(r => [`${r.Station}|${r.Date}|${r.Field}`, r]));
const profiles = csv('Datenpruefung/ZeitAggregation/profilverfuegbarkeit.csv').filter(r => r.Usable === 'True').map(r => {
  const value = field => {
    const stat = stats.get(`${r.Station}|${r.Date}|${field}`);
    assert.equal(stat.RecommendedUsable, 'True');
    return Number(stat.RecommendedAggregate.replace(',', '.'));
  };
  return { ...r, wind: value('windgeschw_ms'), rain: value('niederschlag_mm') };
});
assert.equal(profiles.length, 1442);
const selected = profiles.filter(r => r.wind >= 20);
assert.equal(selected.length, 16);
assert.ok(selected.every(r => r.Station === 'Brocken'));
assert.equal(selected.filter(r => r.rain === 0).length, 0);
assert.ok(Math.abs(Math.min(...selected.map(r => r.rain)) - 0.75) < 1e-9);
assert.ok(Math.abs(Math.max(...selected.map(r => r.rain)) - 24.41) < 1e-9);
const tex = ['% Geprüfte Projektion von 1442 vollständigen Profilen; 16 Windtreffer.', '\\begingroup\\setlength{\\unitlength}{1pt}', '\\begin{picture}(420,225)', '\\put(50,35){\\rule{310pt}{0.5pt}}', '\\put(50,35){\\rule{0.5pt}{160pt}}', '\\put(50,142){\\color[HTML]{00856a}\\rule{310pt}{0.5pt}}', '\\put(365,138){\\scriptsize 20 m/s}'];
for (const rain of [0, 15, 30, 45, 60]) {
  const x = 50 + rain / 60 * 310;
  tex.push(`\\put(${x},32){\\rule{0.4pt}{3pt}}`, `\\put(${x - 10},19){\\makebox(20,8){\\scriptsize ${rain}}}`);
}
for (const wind of [0, 10, 20, 30]) {
  const y = 35 + wind / 30 * 160;
  tex.push(`\\put(47,${y}){\\rule{3pt}{0.4pt}}`, `\\put(23,${y - 4}){\\makebox(20,8)[r]{\\scriptsize ${wind}}}`);
}
for (const r of [...profiles.filter(r => r.wind < 20), ...selected]) {
  assert.ok(Number.isFinite(r.rain) && r.rain >= 0 && r.rain <= 60 && r.wind >= 0 && r.wind <= 30);
  const size = r.wind >= 20 ? 2.4 : 1.2;
  const x = 50 + r.rain / 60 * 310 - size / 2, y = 35 + r.wind / 30 * 160 - size / 2;
  tex.push(`\\put(${x.toFixed(3)},${y.toFixed(3)}){\\color[HTML]{${r.wind >= 20 ? '00856a' : '89959e'}}\\rule{${size}pt}{${size}pt}}`);
}
tex.push('\\put(108,2){\\small Niederschlagssumme (mm/UTC-Tag)}', '\\put(0,62){\\rotatebox{90}{\\small Windmittel (m/s)}}', '\\put(50,210){\\scriptsize Grau: Kontext; grün: 16 Profile mit Windmittel $\\geq20$ m/s}', '\\end{picture}', '\\endgroup');
fs.writeFileSync(root + 'Bericht/Abbildungen/profilvergleich.tex', tex.join('\n') + '\n');
console.log('Profilvergleich geprüft: 1442 Punkte, 16 Brocken-Windtreffer, keine trockenen Windtreffer.');
