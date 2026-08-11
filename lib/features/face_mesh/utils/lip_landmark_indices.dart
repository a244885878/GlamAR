/// MediaPipe Face Mesh 嘴唇区域关键点索引（外唇 + 内唇）。
abstract final class LipLandmarkIndices {
  static const List<int> outerLip = [
    61,
    185,
    40,
    39,
    37,
    0,
    267,
    269,
    270,
    409,
    291,
    375,
    321,
    405,
    314,
    17,
    84,
    181,
    91,
    146,
  ];

  static const List<int> innerLip = [
    78,
    191,
    80,
    81,
    82,
    13,
    312,
    311,
    310,
    415,
    308,
    324,
    318,
    402,
    317,
    14,
    87,
    178,
    88,
    95,
  ];

  static final Set<int> all = {...outerLip, ...innerLip};
}
