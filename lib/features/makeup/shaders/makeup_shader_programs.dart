import 'dart:ui' as ui;

abstract final class MakeupShaderPrograms {
  static Future<ui.FragmentProgram>? _skinProgram;
  static Future<ui.FragmentProgram>? _lipProgram;

  static Future<ui.FragmentProgram> skin() => _skinProgram ??=
      ui.FragmentProgram.fromAsset('shaders/skin_makeup_filter.frag');

  static Future<ui.FragmentProgram> lips() => _lipProgram ??=
      ui.FragmentProgram.fromAsset('shaders/lip_material_filter.frag');

  static Future<void> warmUp() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await Future.wait([skin(), lips()]);
  }
}
