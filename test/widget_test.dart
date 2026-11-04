import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/app.dart';

void main() {
  testWidgets('shell shows brand and dashboard', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(SingletApp());
    await tester.pump(); // layout once; avoid pumpAndSettle (timers/HTTP)
    expect(find.text('Singlet'), findsOneWidget);
    expect(find.text('仪表盘'), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
  });
}
