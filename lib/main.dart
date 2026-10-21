import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/chat_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  await store.load();
  runApp(const GenTechChatApp());
}

class GenTechChatApp extends StatelessWidget {
  const GenTechChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'GenTech Chat',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(settings.palette),
          home: const ChatScreen(),
        );
      },
    );
  }
}
