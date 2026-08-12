import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/face_mesh/face_mesh_camera_page.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';

class LookCatalogPage extends StatefulWidget {
  const LookCatalogPage({super.key, required this.category});

  final MakeupCategoryInfo category;

  @override
  State<LookCatalogPage> createState() => _LookCatalogPageState();
}

class _LookCatalogPageState extends State<LookCatalogPage> {
  MakeupLook? _selected;

  void _select(MakeupLook look) {
    HapticFeedback.selectionClick();
    setState(() => _selected = look);
  }

  void _startTryOn() {
    final selected = _selected;
    if (selected == null) return;
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FaceMeshCameraPage(initialLook: selected),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final looks = MakeupLibrary.forCategory(widget.category.category);
    return Scaffold(
      backgroundColor: GlamARColors.ink,
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar.large(
                expandedHeight: 192,
                pinned: true,
                backgroundColor: GlamARColors.ink.withValues(alpha: 0.95),
                surfaceTintColor: Colors.transparent,
                leading: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  // The pinned title shares the toolbar with the leading
                  // button. Keep it outside the 56dp navigation affordance so
                  // the collapsed state never paints over the back arrow.
                  titlePadding: const EdgeInsets.fromLTRB(64, 0, 24, 18),
                  title: Text(
                    '${widget.category.title}精选',
                    style: const TextStyle(
                      color: GlamARColors.pearl,
                      fontWeight: FontWeight.w700,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 10,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        widget.category.imageAsset,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.25),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black26, GlamARColors.ink],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 24,
                        bottom: 58,
                        child: Text(
                          widget.category.englishTitle,
                          style: TextStyle(
                            color: widget.category.accent,
                            fontSize: 10,
                            letterSpacing: 2.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  child: Text(
                    '选择一套妆容，再进入 AR 镜细调',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 150),
                sliver: SliverGrid.builder(
                  itemCount: looks.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.69,
                  ),
                  itemBuilder: (context, index) {
                    final look = looks[index];
                    return _LookCard(
                      look: look,
                      selected: _selected?.id == look.id,
                      accent: widget.category.accent,
                      onTap: () => _select(look),
                    );
                  },
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _TryOnBar(
              selected: _selected,
              accent: widget.category.accent,
              onPressed: _startTryOn,
            ),
          ),
        ],
      ),
    );
  }
}

class _LookCard extends StatelessWidget {
  const _LookCard({
    required this.look,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final MakeupLook look;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('look-${look.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: const Color(0xFF151216),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? accent : Colors.white10,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.18),
                      blurRadius: 20,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(look.imageAsset, fit: BoxFit.cover),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                          stops: [0.55, 1],
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: GlamARColors.ink,
                          ),
                        ),
                      ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 10,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            look.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            look.subtitle.toUpperCase(),
                            style: TextStyle(
                              color: accent,
                              fontSize: 8,
                              letterSpacing: 1.4,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: look.lips.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        look.lips.product,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GlamARColors.champagne.withValues(alpha: 0.58),
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TryOnBar extends StatelessWidget {
  const _TryOnBar({
    required this.selected,
    required this.accent,
    required this.onPressed,
  });

  final MakeupLook? selected;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        18,
        14,
        18,
        MediaQuery.paddingOf(context).bottom + 14,
      ),
      decoration: BoxDecoration(
        color: GlamARColors.ink.withValues(alpha: 0.94),
        border: const Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton(
            key: const ValueKey('start-try-on'),
            onPressed: selected == null ? null : onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              disabledBackgroundColor: Colors.white10,
              foregroundColor: GlamARColors.ink,
              disabledForegroundColor: Colors.white38,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
            ),
            child: Text(
              selected == null ? '请先选择一套妆容' : '试妆 · ${selected!.name}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
