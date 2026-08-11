# GlamAR iOS dependency patch

This directory is based on TensorFlow's `tflite_flutter` 0.12.1 package and
retains its Apache-2.0 `LICENSE`.

GlamAR uses the TensorFlow Lite C API through Dart FFI. The upstream iOS
podspec also depends on TensorFlowLiteSwift plus its Metal and CoreML
subspecs, although this project does not call those APIs. The local podspec
therefore links only the prebuilt `TensorFlowLiteC` 2.12.0 framework. Dart and
Android sources are unchanged. The Android Gradle file also omits the unused
GPU delegate artifact; GlamAR deliberately runs this model on a two-thread CPU
worker so it cannot contend with camera rendering and Impeller.
