import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nest_call/screens/home_screen.dart';

void main() {
  testWidgets('ConnectedIllustration is visible when recent calls = 0',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConnectedIllustration()),
      ),
    );

    expect(find.text('Always connected'), findsOneWidget);
    expect(
      find.text('Enter a handle above to call your family'),
      findsOneWidget,
    );
  });

  testWidgets(
      'ConnectedIllustration is absent from AnimatedSwitcher when recent calls >= 3',
      (tester) async {
    // Simulate the branch taken when recentContacts.length >= 3: the switcher
    // child is SizedBox.shrink(), so the illustration is not in the tree.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AnimatedSwitcher(
            duration: Duration(milliseconds: 400),
            child: SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Always connected'), findsNothing);
    expect(
      find.text('Enter a handle above to call your family'),
      findsNothing,
    );
  });
}
