import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/main.dart';

void main() {
  testWidgets('home page renders brand title', (WidgetTester tester) async {
    await tester.pumpWidget(const GlamARApp());

    expect(find.text('GlamAR'), findsOneWidget);
    expect(find.text('探索 20 套精选妆容'), findsOneWidget);
  });

  testWidgets('category first flow exposes local look catalog', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const GlamARApp());
    await tester.tap(find.text('探索 20 套精选妆容'));
    await tester.pumpAndSettle();

    expect(find.text('今天，想成为谁？'), findsOneWidget);
    expect(find.text('韩系'), findsOneWidget);
    expect(find.text('日系'), findsOneWidget);
    final koreanLabel = tester.widget<Text>(find.text('韩系'));
    expect(koreanLabel.style?.color, GlamARColors.pearl);

    await tester.tap(find.text('韩系'));
    await tester.pumpAndSettle();
    final catalogTitle = tester.widget<Text>(find.text('韩系精选'));
    expect(catalogTitle.style?.color, GlamARColors.pearl);
    final flexibleSpace = tester.widget<FlexibleSpaceBar>(
      find.byType(FlexibleSpaceBar),
    );
    expect(
      flexibleSpace.titlePadding,
      const EdgeInsets.fromLTRB(64, 0, 24, 18),
    );
    expect(find.text('水光蔷薇'), findsOneWidget);

    final firstLook = find.byKey(const ValueKey('look-kr-glass'));
    await tester.ensureVisible(firstLook);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(firstLook);
    await tester.pumpAndSettle();
    expect(find.text('试妆 · 水光蔷薇'), findsOneWidget);
  });

  test('offline library contains five looks in every category', () {
    expect(MakeupLibrary.looks, hasLength(20));
    for (final category in MakeupLibrary.categories) {
      expect(MakeupLibrary.forCategory(category.category), hasLength(5));
    }
    expect(
      MakeupLibrary.looks.every(
        (look) => look.lips.product.isNotEmpty && look.imageAsset.isNotEmpty,
      ),
      isTrue,
    );
  });
}
