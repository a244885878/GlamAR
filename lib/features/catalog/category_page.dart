import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/catalog/look_catalog_page.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';

class CategoryPage extends StatelessWidget {
  const CategoryPage({super.key});

  void _openCategory(BuildContext context, MakeupCategoryInfo info) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, animation, _) => LookCatalogPage(category: info),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 420),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF171218), GlamARColors.ink],
            ),
          ),
          child: SafeArea(
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'CHOOSE YOUR MOOD',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: GlamARColors.rose,
                                      letterSpacing: 2.2,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '今天，想成为谁？',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: GlamARColors.pearl,
                                      fontWeight: FontWeight.w500,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: const Text(
                            '20 LOOKS',
                            style: TextStyle(fontSize: 10, letterSpacing: 1.2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  sliver: SliverGrid.builder(
                    itemCount: MakeupLibrary.categories.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 0.72,
                        ),
                    itemBuilder: (context, index) {
                      final info = MakeupLibrary.categories[index];
                      return _CategoryCard(
                        info: info,
                        onTap: () => _openCategory(context, info),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.offline_bolt_outlined,
                          size: 16,
                          color: GlamARColors.rose,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '全部妆容与预览均已内置，无网络也能完整试妆',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: GlamARColors.champagne.withValues(
                                    alpha: 0.55,
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.info, required this.onTap});

  final MakeupCategoryInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${info.title}妆容分类',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              image: DecorationImage(
                image: AssetImage(info.imageAsset),
                fit: BoxFit.cover,
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: [
                BoxShadow(
                  color: info.accent.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.9),
                  ],
                  stops: const [0.25, 0.55, 1],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    info.englishTitle,
                    style: TextStyle(
                      color: info.accent,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.7,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Text(
                        info.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: GlamARColors.pearl,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(
                              color: Colors.black87,
                              blurRadius: 8,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      const Icon(
                        Icons.north_east_rounded,
                        size: 17,
                        color: GlamARColors.champagne,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    info.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GlamARColors.champagne.withValues(alpha: 0.68),
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
