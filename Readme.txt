Regionale Wetterunterschiede - Installation und Start

PowerShell im Projektordner oeffnen und ausfuehren:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\scripts\setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\scripts\run.ps1 -Task dev

Anschliessend http://127.0.0.1:8000 im Browser oeffnen.
Die Installation benoetigt Internetzugriff. Zur Anmeldung dient der
Veranstaltungszugang zum Uni-Datenserver; Zugangsdaten sind nicht enthalten.
Nach der Anmeldung Jahresdaten sowie Wind und Niederschlag laden.

Alternativ mit vorhandenem Node ab Version 24 im Ordner app:
npm ci
npm run build
npm run dev

Bericht: Bericht/Informationsvisualisierung.pdf
Neubau mit installiertem MiKTeX, pdflatex und biber:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Bericht\build.ps1

Automatisierte Pruefungen ueber run.ps1 -Task ausfuehren:
format:check, test:browser, test:year, test:profiles, test:comparison.
Browserpruefungen benoetigen Chromium (setup.ps1 installiert diesen).
Kontrollierte Testantworten benoetigen keine Zugangsdaten. Fuer echte
Uni-Abgleiche INFOVIS_USER und INFOVIS_PASSWORD temporaer als
Umgebungsvariablen setzen; test:usecases benoetigt diese zwingend.
