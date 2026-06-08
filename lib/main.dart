import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/home/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: GlamARColors.ink,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const GlamARApp());
}

class GlamARApp extends StatelessWidget {
  const GlamARApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GlamAR',
      debugShowCheckedModeBanner: false,
      theme: GlamARTheme.dark(),
      home: const HomePage(),
    );
  }
}
