import 'package:flutter/material.dart';

class ThemeProvider with ChangeNotifier {
  bool _isDarkMode = false;
  Color _backgroundColor = const Color(0xFFF5F5F5);

  bool get isDarkMode => _isDarkMode;
  Color get backgroundColor => _backgroundColor;

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void setBackgroundColor(Color color) {
    _backgroundColor = color;
    notifyListeners();
  }

  ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: _isDarkMode ? Brightness.dark : Brightness.light,
    primaryColor: const Color(0xFF263238),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF263238),
      brightness: _isDarkMode ? Brightness.dark : Brightness.light,
    ),
    scaffoldBackgroundColor: backgroundColor,
    appBarTheme: AppBarTheme(
      backgroundColor: _isDarkMode
          ? const Color(0xFF263238)
          : Colors.blueGrey[700],
      foregroundColor: Colors.white,
    ),
  );
}
