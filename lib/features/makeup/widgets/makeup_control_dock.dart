import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';

class MakeupControlDock extends StatelessWidget {
  const MakeupControlDock({
    super.key,
    required this.look,
    required this.selectedPart,
    required this.expanded,
    required this.makeupVisible,
    required this.isCapturing,
    required this.onToggleExpanded,
    required this.onSelectPart,
    required this.onLayerChanged,
    required this.onLipFinishChanged,
    required this.onResetPart,
    required this.onToggleMakeup,
    required this.onCapture,
  });

  final MakeupLook look;
  final MakeupPart selectedPart;
  final bool expanded;
  final bool makeupVisible;
  final bool isCapturing;
  final VoidCallback onToggleExpanded;
  final ValueChanged<MakeupPart> onSelectPart;
  final ValueChanged<MakeupLayerConfig> onLayerChanged;
  final ValueChanged<LipFinish> onLipFinishChanged;
  final VoidCallback onResetPart;
  final VoidCallback onToggleMakeup;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      height: expanded ? 330 + bottomInset : 92 + bottomInset,
      decoration: BoxDecoration(
        color: const Color(0xEA0D0C0F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.11)),
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 30,
            offset: Offset(0, -10),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: expanded ? _expanded(context) : _collapsed(context),
      ),
    );
  }

  Widget _collapsed(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Row(
        children: [
          _RoundAction(
            icon: Icons.tune_rounded,
            label: '细调',
            onTap: onToggleExpanded,
          ),
          const Spacer(),
          _ShutterButton(isCapturing: isCapturing, onTap: onCapture),
          const Spacer(),
          _RoundAction(
            icon: makeupVisible
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded,
            label: makeupVisible ? '效果' : '原生',
            selected: makeupVisible,
            onTap: onToggleMakeup,
          ),
        ],
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final layer = look.layer(selectedPart);
    final shades = MakeupLibrary.shades[selectedPart] ?? const <ShadeOption>[];
    return Column(
      children: [
        GestureDetector(
          onTap: onToggleExpanded,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 30,
            width: double.infinity,
            child: Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 56,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: MakeupPart.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final part = MakeupPart.values[index];
              final selected = part == selectedPart;
              return _PartTab(
                part: part,
                selected: selected,
                enabled: look.layer(part).enabled,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onSelectPart(part);
                },
              );
            },
          ),
        ),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        layer.product,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: GlamARColors.champagne,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => onLayerChanged(
                        layer.copyWith(enabled: !layer.enabled),
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: layer.enabled
                              ? GlamARColors.rose.withValues(alpha: 0.16)
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          layer.enabled ? '已开启' : '已关闭',
                          style: TextStyle(
                            fontSize: 10,
                            color: layer.enabled
                                ? GlamARColors.rose
                                : Colors.white38,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: onResetPart,
                      child: const Icon(
                        Icons.restart_alt_rounded,
                        size: 20,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shades.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final shade = shades[index];
                      final selected = shade.color == layer.color;
                      return Tooltip(
                        message: shade.name,
                        child: GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            onLayerChanged(
                              layer.copyWith(
                                color: shade.color,
                                product: shade.name,
                              ),
                            );
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: shade.color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected ? Colors.white : Colors.white24,
                                width: selected ? 2.5 : 1,
                              ),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: shade.color.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: 10,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: selected
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
                _ControlSlider(
                  label: '浓度',
                  value: layer.intensity,
                  onChanged: (value) =>
                      onLayerChanged(layer.copyWith(intensity: value)),
                ),
                _ControlSlider(
                  label: _detailLabel(selectedPart),
                  value: layer.detail,
                  onChanged: (value) =>
                      onLayerChanged(layer.copyWith(detail: value)),
                ),
                if (selectedPart == MakeupPart.lips)
                  _FinishPicker(
                    value: look.lipFinish,
                    onChanged: onLipFinishChanged,
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: onToggleExpanded,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                label: const Text('收起'),
                style: TextButton.styleFrom(foregroundColor: Colors.white54),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onToggleMakeup,
                child: Text(
                  makeupVisible ? '按住看妆前' : '恢复妆效',
                  style: const TextStyle(
                    color: GlamARColors.rose,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              _MiniShutter(isCapturing: isCapturing, onTap: onCapture),
            ],
          ),
        ),
      ],
    );
  }

  String _detailLabel(MakeupPart part) => switch (part) {
    MakeupPart.complexion => '立体',
    MakeupPart.blush => '位置',
    MakeupPart.eyeshadow => '闪度',
    MakeupPart.brows => '眉型',
    MakeupPart.eyeliner => '长度',
    MakeupPart.lips => '饱和',
  };
}

class _PartTab extends StatelessWidget {
  const _PartTab({
    required this.part,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final MakeupPart part;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: selected
              ? GlamARColors.rose.withValues(alpha: 0.17)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? GlamARColors.rose.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              part.icon,
              size: 16,
              color: !enabled
                  ? Colors.white24
                  : (selected ? GlamARColors.rose : Colors.white54),
            ),
            const SizedBox(width: 6),
            Text(
              part.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: !enabled
                    ? Colors.white24
                    : (selected ? GlamARColors.champagne : Colors.white60),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlSlider extends StatelessWidget {
  const _ControlSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: GlamARColors.rose,
                inactiveTrackColor: Colors.white12,
                thumbColor: GlamARColors.champagne,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${(value * 100).round()}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

class _FinishPicker extends StatelessWidget {
  const _FinishPicker({required this.value, required this.onChanged});

  final LipFinish value;
  final ValueChanged<LipFinish> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: LipFinish.values.map((finish) {
        final label = switch (finish) {
          LipFinish.velvet => '丝绒',
          LipFinish.satin => '缎光',
          LipFinish.glass => '水光',
        };
        final selected = value == finish;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(finish),
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                color: selected ? Colors.white12 : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: selected ? GlamARColors.champagne : Colors.white38,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.isCapturing, required this.onTap});
  final bool isCapturing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isCapturing ? null : onTap,
      child: Container(
        width: 62,
        height: 62,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: GlamARColors.champagne, width: 2),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCapturing ? GlamARColors.rose : GlamARColors.pearl,
          ),
          child: isCapturing
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GlamARColors.ink,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _MiniShutter extends StatelessWidget {
  const _MiniShutter({required this.isCapturing, required this.onTap});
  final bool isCapturing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isCapturing ? null : onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: GlamARColors.pearl,
          border: Border.all(color: GlamARColors.rose, width: 3),
        ),
        child: isCapturing
            ? const Padding(
                padding: EdgeInsets.all(9),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: GlamARColors.ink,
                ),
              )
            : const Icon(
                Icons.camera_alt_rounded,
                color: GlamARColors.ink,
                size: 17,
              ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? GlamARColors.rose : GlamARColors.champagne,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}
