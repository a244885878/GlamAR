import 'dart:ui' as ui;

abstract final class MakeupShaderPrograms {
  static Future<ui.FragmentProgram>? _skinProgram;
  static Future<ui.FragmentProgram>? _lipProgram;
  static Future<ui.FragmentProgram>? _colorMaterialProgram;
  static Future<ui.FragmentProgram>? _faceColorMaterialProgram;

  static Future<ui.FragmentProgram> skin() => _skinProgram ??=
      ui.FragmentProgram.fromAsset('shaders/skin_makeup_filter.frag');

  static Future<ui.FragmentProgram> lips() => _lipProgram ??=
      ui.FragmentProgram.fromAsset('shaders/lip_material_filter.frag');

  static Future<ui.FragmentProgram> colorMaterial() => _colorMaterialProgram ??=
      ui.FragmentProgram.fromAsset('shaders/color_makeup_filter.frag');

  static Future<ui.FragmentProgram> faceColorMaterial() =>
      _faceColorMaterialProgram ??= ui.FragmentProgram.fromAsset(
        'shaders/face_color_material_filter.frag',
      );

  static Future<void> warmUp() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await Future.wait([skin(), lips(), colorMaterial(), faceColorMaterial()]);
  }
}
