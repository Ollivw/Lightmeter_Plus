import 'package:flutter/material.dart';

void showHelpDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.help_outline, color: Colors.blue),
          SizedBox(width: 10),
          Text('Hilfe & Dokumentation'),
        ],
      ),
      content: SizedBox(
        width: 500, // Feste Breite für bessere Lesbarkeit auf Desktop/Web
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExpansionTile(
                initiallyExpanded: true,
                leading: const Icon(Icons.menu_book),
                title: const Text('Anleitung zur App'),
                children: const [
                  Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Text(
                      '1. Grundriss laden: Über das Ordner-Icon rechts oben oder in der Mitte des Bildschirm bei Start der Anwendung, einen PDF Grundriss auswählen.\n'
                      '2. Maßstab setzen: Lineal-Icon wählen, zwei bekannte Punkte im Plan anklicken und die reale Distanz (m) eingeben.\n'
                      '3. Referenzpunkt: Das Fadenkreuz-Icon wählen und den Nullpunkt (z.B. eine Wandecke) im Plan festlegen.\n'
                      '4. Messpunkt setzen: Einfach in den Plan tippen, um Marker zu setzen. Jeder Marker lässt sich frei verschieben. Nochmal anklicken um den die gemessenen Beleuchtungsstärken hinzuzufügen.\n'
                      '5. Sensorwerte: Über das Glühbirnen-Icon kann man Sensorwerte live übernehmen (die angezeigten Sensorwerte sind Simuliert und kommen nicht aus deinem Gerät oder Sensor diese Funktion ist zur Zeit nur mit Spezial Luxmeter welches über BLE verbunden wird aktiv).\n'
                      '6. Markergröße und Raster : Im Menu links kann die Markergröße angepasst und ein Hilfraster aktiviert und angepasst werden mit oder ohne Snapfunktion.\n'
                      '7. Bereiche: Über die Tableiste oben können verschiedene Räume/Bereiche angelegt werden, umbenennen über langen Klick.\n'
                      '8. Export: Das PDF-Icon erstellt einen detaillierten Bericht inklusive Statistiken (Emin, Em, Emax, U0).\n'
                      '9. Im Menu Links hat man die möglichkeit ein Logo hochzuladen, welches im Kopf der PDf Ausgabe erscheint.\n'
                      '10. Hilfe: Dieses Dialogfenster bietet eine kurze Anleitung und wichtige Informationen zu Beleuchtungsstärken.\n'
                      '11. Lux-Vorgaben: In der App finden Sie die wichtigsten Mindestwerte der Beleuchtungsstärken für verschiedene Bereiche.\n'
                      '12. Über die App: Version und Entwicklerinformationen.\n'
                      '\n\nTipp: Für die beste Erfahrung verwenden Sie die App mit einem PC oder Tablet mit einem modernen Browser (Chrome, Edge)ist aber auch auf Mobiltelefonen verwendbar.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              ExpansionTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: const Text('Lux-Vorgaben (DIN EN 12464)'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Auszug Mindestwerte (Wartungswerte):',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text('• Büro (Schreiben, Lesen, CAD): 500 lx, U0: 0,6'),
                        Text('• Büro (Besprechung): 300 lx, U0: 0,4'),
                        Text('• Empfangsbereiche: 200 lx, U0: 0,4'),
                        Text('• Flure und Verkehrswege: 100 lx, U0: 0,4'),
                        Text('• Treppen, Rolltreppen: 150 lx, U0: 0,4'),
                        Text('• Sanitärräume, Pausenräume: 200 lx, U0:0,4'),
                        Text(
                          '• Lagerbereiche (grob/fein): 100 - 300 lx, U0: 0,4',
                        ),
                        Text('• Parkgaragen (Fahrspuren): 75 lx, U0: 0,4'),
                        Text('• Außenbereiche (Eingänge): 100 lx, U0: 0,4'),
                        Text(
                          '• Werkstätten (grob/fein): 300 - 750 lx, U0: 0,6-0,7',
                        ),
                        Text('• Konferenzräume: 500 lx, U0:0,6'),
                        Text('• Klassenzimmer: 300 lx, U0:0,6'),
                        Text('• OP-Räume: 1000 lx, U0:0,7'),
                        Text(
                          '• Elektronikwerkstätten, Prüfen,Justieren : 1500 lx,U0:0,7',
                        ),

                        SizedBox(height: 12),
                        Text(
                          'Gleichmäßigkeit (U0):',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Das Verhältnis von Emin zu Em sollte bei den meisten Arbeitsplätzen zwischen 0,4 und 0,6 liegen.Die aktuellen und detaillierten Werte für alle Bereiche finden Sie in den jeweiligen Normen z.B. DIN-EN12464-1 und DIN EN-12464-2 oder der ASR3.1. Die obigen Werte sind Richtwerte,ich übernehme keine Gewähr, dafür bitte die gültigen Normen verwenden".',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              ExpansionTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Über die App'),
                children: const [
                  Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Text(
                      'Version: 0.83\nEntwickelt von OvW\n\nEin professionelles Tool zur effizienten Dokumentation von Beleuchtungsstärken direkt vor vor Ort.',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
}
