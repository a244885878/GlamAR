import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/main.dart';

void main() {
  testWidgets('home page renders brand title', (WidgetTester tester) async {
    await tester.pumpWidget(const GlamARApp());

    expect(find.text('GlamAR'), findsOneWidget);
    expect(find.text('开启 AR 试妆镜'), findsOneWidget);
  });
}
