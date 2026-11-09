import 'package:flutter/material.dart';

import '../ui/glass.dart';
import '../ui/nav_bar.dart';
import '../ui/scope.dart';
import 'ai.dart';
import 'chats_tab.dart';
import 'incoming_call_overlay.dart';
import 'menu_tab.dart';
import 'stories.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final inset = MediaQuery.of(context).padding.bottom;
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: AppBackground(
        child: Stack(
          children: [
            // Tabs stay alive so scroll positions survive switching.
            Positioned.fill(
              child: IndexedStack(index: _tab, children: const [ChatsTab(), StoriesTab(), MenuTab()]),
            ),
            Positioned(
              right: 16,
              bottom: inset + 84,
              child: FloatingOrbButton(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiListScreen())),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: inset + 10,
              child: ListenableBuilder(
                listenable: state,
                builder: (context, _) => LiquidNavBar(
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                  items: [
                    NavItem(Icons.chat_bubble_rounded, 'Chats', badge: state.unreadChats),
                    const NavItem(Icons.auto_stories_rounded, 'Stories'),
                    const NavItem(Icons.menu_rounded, 'Menu'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final callController = state.callController;
        if (callController != null) {
          return IncomingCallOverlay(
            controller: callController,
            child: scaffold,
          );
        }
        return scaffold;
      },
    );
  }
}
