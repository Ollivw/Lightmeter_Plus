import 'package:flutter/material.dart';

void showHelpDialog(BuildContext context, bool isEnglish, String appVersion) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.help_outline, color: Colors.blue),
          const SizedBox(width: 10),
          Text(isEnglish ? 'Help & Documentation' : 'Hilfe & Dokumentation'),
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
                title: Text(isEnglish ? 'App Guide' : 'Anleitung zur App'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                      isEnglish
                          ? '1. Load Floor Plan: Select a PDF or image floor plan using the folder icon.\n'
                                '2. Set Scale: Select the ruler icon, click two known points in the plan, and enter the real distance (m).\n'
                                '3. Reference Point: Select the crosshair icon and set the zero point (e.g., a wall corner).\n'
                                '4. Set Measurement Points: Simply tap in the plan to place markers. Each marker can be moved freely. Click again to add measured illuminance values.\n'
                                '5. Sensor Values: Use the lightbulb icon to adopt live sensor values (requires specialized Luxmeter via BLE).\n'
                                '6. Marker Size and Grid: Adjust marker size and activate the guide grid with/without snap function in the left menu.\n'
                                '7. Areas: Use the tab bar at the top to create rooms/areas. Long-click to rename.\n'
                                '8. Export: The PDF icon creates a detailed report including statistics (Emin, Em, Emax, U0).\n'
                                '9. Logo: You can upload a logo in the left menu to appear in the PDF header.\n'
                                '10. Help: This dialog provides a guide and important information on illuminance levels.\n'
                                '11. Lux Standards: Find essential minimum illuminance values for various areas.\n'
                                '12. About: Version and developer information.\n'
                                '\n\nTip: For the best experience, use a modern browser (Chrome, Edge) on a PC or tablet.'
                          : '1. Grundriss laden: Über das Ordner-Icon rechts oben oder in der Mitte des Bildschirm bei Start der Anwendung, einen PDF oder Bild als Grundriss auswählen.\n'
                                '2. Maßstab setzen: Lineal-Icon wählen, zwei bekannte Punkte im Plan anklicken und die reale Distanz (m) eingeben.\n'
                                '3. Referenzpunkt: Das Fadenkreuz-Icon wählen und den Nullpunkt (z.B. eine Wandecke) im Plan festlegen.\n'
                                '4. Messpunkt setzen: Einfach in den Plan tippen, um Marker zu setzen. Jeder Marker lässt sich frei verschieben. Nochmal anklicken um den die gemessenen Beleuchtungsstärken hinzuzufügen.\n'
                                '5. Sensorwerte: Über das Glühbirnen-Icon kann man Sensorwerte live übernehmen (die angezeigten Sensorwerte sind Simuliert und kommen nicht aus deinem Gerät oder Sensor diese Funktion ist zur Zeit nur mit Spezial Luxmeter welches über BLE verbunden wird aktiv).\n'
                                '6. Markergröße und Raster : Im Menu links kann die Markergröße angepasst und ein Hilfraster aktiviert und angepasst werden, mit oder ohne Snapfunktion.\n'
                                '7. Bereiche: Über die Tableiste oben können verschiedene Räume/Bereiche angelegt werden, umbenannt werden über langen Klick.\n'
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
                title: Text(isEnglish ? 'About the App' : 'Über die App'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                      'Version: $appVersion\nDeveloped by OvW\n\n${isEnglish ? "A professional tool for efficient on-site documentation of illuminance levels." : "Ein professionelles Tool zur effizienten Dokumentation von Beleuchtungsstärken direkt vor vor Ort."}',
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
          child: Text(isEnglish ? 'Close' : 'Schließen'),
        ),
      ],
    ),
  );
}
