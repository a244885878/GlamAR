import 'package:flutter/material.dart';

enum MakeupCategory { korean, japanese, chinese, western }

enum MakeupPart { complexion, blush, eyeshadow, brows, eyeliner, lips }

enum LipFinish { velvet, satin, glass }

extension MakeupPartMeta on MakeupPart {
  String get label => switch (this) {
    MakeupPart.complexion => '底妆',
    MakeupPart.blush => '腮红',
    MakeupPart.eyeshadow => '眼影',
    MakeupPart.brows => '眉形',
    MakeupPart.eyeliner => '眼线',
    MakeupPart.lips => '唇妆',
  };

  IconData get icon => switch (this) {
    MakeupPart.complexion => Icons.blur_on_rounded,
    MakeupPart.blush => Icons.favorite_outline_rounded,
    MakeupPart.eyeshadow => Icons.gradient_rounded,
    MakeupPart.brows => Icons.gesture_rounded,
    MakeupPart.eyeliner => Icons.remove_red_eye_outlined,
    MakeupPart.lips => Icons.water_drop_outlined,
  };
}

@immutable
class MakeupLayerConfig {
  const MakeupLayerConfig({
    required this.color,
    required this.intensity,
    required this.product,
    this.secondaryColor,
    this.detail = 0.5,
    this.enabled = true,
  });

  final Color color;
  final Color? secondaryColor;
  final double intensity;
  final double detail;
  final String product;
  final bool enabled;

  MakeupLayerConfig copyWith({
    Color? color,
    Color? secondaryColor,
    double? intensity,
    double? detail,
    String? product,
    bool? enabled,
  }) {
    return MakeupLayerConfig(
      color: color ?? this.color,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      intensity: intensity ?? this.intensity,
      detail: detail ?? this.detail,
      product: product ?? this.product,
      enabled: enabled ?? this.enabled,
    );
  }
}

@immutable
class MakeupLook {
  const MakeupLook({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.category,
    required this.imageAsset,
    required this.tags,
    required this.complexion,
    required this.blush,
    required this.eyeshadow,
    required this.brows,
    required this.eyeliner,
    required this.lips,
    this.lipFinish = LipFinish.satin,
  });

  final String id;
  final String name;
  final String subtitle;
  final MakeupCategory category;
  final String imageAsset;
  final List<String> tags;
  final MakeupLayerConfig complexion;
  final MakeupLayerConfig blush;
  final MakeupLayerConfig eyeshadow;
  final MakeupLayerConfig brows;
  final MakeupLayerConfig eyeliner;
  final MakeupLayerConfig lips;
  final LipFinish lipFinish;

  MakeupLayerConfig layer(MakeupPart part) => switch (part) {
    MakeupPart.complexion => complexion,
    MakeupPart.blush => blush,
    MakeupPart.eyeshadow => eyeshadow,
    MakeupPart.brows => brows,
    MakeupPart.eyeliner => eyeliner,
    MakeupPart.lips => lips,
  };

  MakeupLook withLayer(MakeupPart part, MakeupLayerConfig value) {
    return MakeupLook(
      id: id,
      name: name,
      subtitle: subtitle,
      category: category,
      imageAsset: imageAsset,
      tags: tags,
      complexion: part == MakeupPart.complexion ? value : complexion,
      blush: part == MakeupPart.blush ? value : blush,
      eyeshadow: part == MakeupPart.eyeshadow ? value : eyeshadow,
      brows: part == MakeupPart.brows ? value : brows,
      eyeliner: part == MakeupPart.eyeliner ? value : eyeliner,
      lips: part == MakeupPart.lips ? value : lips,
      lipFinish: lipFinish,
    );
  }

  MakeupLook withLipFinish(LipFinish value) {
    return MakeupLook(
      id: id,
      name: name,
      subtitle: subtitle,
      category: category,
      imageAsset: imageAsset,
      tags: tags,
      complexion: complexion,
      blush: blush,
      eyeshadow: eyeshadow,
      brows: brows,
      eyeliner: eyeliner,
      lips: lips,
      lipFinish: value,
    );
  }
}

@immutable
class MakeupCategoryInfo {
  const MakeupCategoryInfo({
    required this.category,
    required this.title,
    required this.englishTitle,
    required this.description,
    required this.imageAsset,
    required this.accent,
  });

  final MakeupCategory category;
  final String title;
  final String englishTitle;
  final String description;
  final String imageAsset;
  final Color accent;
}

@immutable
class ShadeOption {
  const ShadeOption(this.name, this.color);

  final String name;
  final Color color;
}
