package com.glamar.glamar

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.PowerManager
import android.os.Build
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.ShortBuffer
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

private data class GlamArRenderFrame(
    val submissionSequence: Long,
    val sourceSequence: Long,
    val mirrored: Boolean,
    val landmarks: FloatArray,
    val material: FloatArray,
    val face: FloatArray,
) {
    companion object {
        private const val MAGIC = 0x52414C47
        private const val VERSION = 1
        private const val HEADER_LENGTH = 48
        private const val MATERIAL_HEADER_LENGTH = 4
        private const val MATERIAL_LAYER_STRIDE = 12
        private const val BLUSH_LAYER_INDEX = 1
        private const val EYESHADOW_LAYER_INDEX = 2
        private const val BROW_LAYER_INDEX = 3
        private const val EYELINER_LAYER_INDEX = 4
        private const val LIP_LAYER_INDEX = 5

        val blushLayerOffset: Int
            get() = MATERIAL_HEADER_LENGTH + BLUSH_LAYER_INDEX * MATERIAL_LAYER_STRIDE

        val eyeshadowLayerOffset: Int
            get() = MATERIAL_HEADER_LENGTH + EYESHADOW_LAYER_INDEX * MATERIAL_LAYER_STRIDE

        val browLayerOffset: Int
            get() = MATERIAL_HEADER_LENGTH + BROW_LAYER_INDEX * MATERIAL_LAYER_STRIDE

        val eyelinerLayerOffset: Int
            get() = MATERIAL_HEADER_LENGTH + EYELINER_LAYER_INDEX * MATERIAL_LAYER_STRIDE

        val lipLayerOffset: Int
            get() = MATERIAL_HEADER_LENGTH + LIP_LAYER_INDEX * MATERIAL_LAYER_STRIDE

        fun decode(source: ByteBuffer): GlamArRenderFrame? {
            val data = source.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            if (data.remaining() < HEADER_LENGTH) return null
            val start = data.position()
            if (data.getInt(start) != MAGIC || data.getShort(start + 4).toInt() != VERSION) {
                return null
            }
            val flags = data.getShort(start + 6).toInt()
            val submissionSequence = data.getLong(start + 8)
            val sourceSequence = data.getLong(start + 16)
            val landmarkCount = data.getInt(start + 40)
            val materialCount = data.getShort(start + 44).toInt() and 0xffff
            val faceCount = data.getShort(start + 46).toInt() and 0xffff
            if (landmarkCount < 468 || materialCount < 76 || faceCount < 18) return null
            val vertexFloatCount = landmarkCount * 3
            val expected = HEADER_LENGTH + (vertexFloatCount + materialCount + faceCount) * 4
            if (data.remaining() != expected) return null
            data.position(start + HEADER_LENGTH)
            fun readFloats(count: Int): FloatArray = FloatArray(count) { data.float }
            return GlamArRenderFrame(
                submissionSequence = submissionSequence,
                sourceSequence = sourceSequence,
                mirrored = flags and 1 != 0,
                landmarks = readFloats(vertexFloatCount),
                material = readFloats(materialCount),
                face = readFloats(faceCount),
            )
        }
    }
}

private class GlamArOpenGlRenderer(
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    val pixelWidth: Int,
    val pixelHeight: Int,
    private val foundationIndices: ShortArray,
) {
    val textureId: Long
        get() = surfaceProducer.id()

    companion object {
        private val OUTER_LIP = intArrayOf(
            61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
            291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
        )
        private val INNER_LIP = intArrayOf(
            78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
            308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
        )
        private val SIDE_A_EYE_UPPER = intArrayOf(33, 246, 161, 160, 159, 158, 157, 173, 133)
        private val SIDE_B_EYE_UPPER = intArrayOf(362, 398, 384, 385, 386, 387, 388, 466, 263)
        private val SIDE_A_BROW = intArrayOf(70, 63, 105, 66, 107)
        private val SIDE_B_BROW = intArrayOf(336, 296, 334, 293, 300)
        private val RING_FRACTIONS = floatArrayOf(0f, 0.09f, 0.79f, 1f)
        private val RING_ALPHAS = floatArrayOf(0f, 1f, 1f, 0f)
        private val EYE_FRACTIONS = floatArrayOf(0f, 0.12f, 0.72f, 1f)
        private val EYE_ALPHAS = floatArrayOf(0f, 1f, 0.56f, 0f)
        private val CHEEK_FRACTIONS = floatArrayOf(0f, 0.46f, 0.76f, 1f)
        private val CHEEK_ALPHAS = floatArrayOf(1f, 0.78f, 0.34f, 0f)
        private val RIBBON_FRACTIONS = floatArrayOf(-1f, -0.42f, 0.42f, 1f)
        private val RIBBON_ALPHAS = floatArrayOf(0f, 1f, 1f, 0f)
        private const val CHEEK_SEGMENTS = 24
        private const val FLOATS_PER_VERTEX = 5
        private const val PI_F = 3.1415927f

        private const val VERTEX_SHADER = """
            attribute vec2 aPosition;
            attribute vec2 aUv;
            attribute float aEdgeAlpha;
            varying vec2 vUv;
            varying float vEdgeAlpha;
            void main() {
              gl_Position = vec4(aPosition, 0.0, 1.0);
              vUv = aUv;
              vEdgeAlpha = aEdgeAlpha;
            }
        """
        private const val LIP_FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vUv;
            varying float vEdgeAlpha;
            uniform vec4 uBaseColor;
            uniform vec4 uParameters;
            void main() {
              float alpha = clamp(vEdgeAlpha * uParameters.x * 0.72, 0.0, 1.0);
              float verticalTone = mix(0.88, 1.035, smoothstep(0.08, 0.94, vUv.y));
              vec3 color = uBaseColor.rgb * verticalTone;
              vec2 glossDelta = (vUv - vec2(0.5, 0.68)) / vec2(0.34, 0.115);
              float gloss = exp(-dot(glossDelta, glossDelta) * 2.2) *
                uParameters.y * uParameters.z * uParameters.w * 0.24;
              color = mix(color, vec3(1.0), gloss);
              gl_FragColor = vec4(color * alpha, alpha);
            }
        """
        private const val COLOR_FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vUv;
            varying float vEdgeAlpha;
            uniform vec4 uPrimaryColor;
            uniform vec4 uSecondaryColor;
            uniform vec4 uParameters;
            void main() {
              float alpha = clamp(vEdgeAlpha * uParameters.x, 0.0, 1.0);
              if (uParameters.z > 2.5) {
                if (uParameters.z > 3.5) {
                  float rootDensity = 1.0 - smoothstep(0.56, 1.0, vUv.y);
                  float directionTaper = 0.7 + 0.3 * sin(vUv.x * 3.1415927);
                  float body = mix(0.34, 1.0, rootDensity) * directionTaper;
                  vec3 liner = mix(
                    uPrimaryColor.rgb * 0.72,
                    uSecondaryColor.rgb,
                    clamp(uParameters.y, 0.0, 1.0) * 0.18
                  );
                  gl_FragColor = vec4(liner * alpha * body, alpha * body);
                  return;
                }
                float density = mix(9.0, 18.0, clamp(uParameters.y, 0.0, 1.0));
                float strandCoordinate = fract(vUv.x * density - vUv.y * 0.82);
                float strand = 1.0 - smoothstep(0.08, 0.31, abs(strandCoordinate - 0.5));
                float body = 0.42 + strand * 0.58;
                vec3 brow = mix(
                  uPrimaryColor.rgb * 0.78,
                  uSecondaryColor.rgb,
                  strand * 0.28
                );
                gl_FragColor = vec4(brow * alpha * body, alpha * body);
                return;
              }
              if (uParameters.z > 1.5) {
                float luminance = mix(0.93, 1.07, clamp(vUv.x, 0.0, 1.0));
                float contourFalloff = 1.0 - smoothstep(0.76, 1.08, vUv.y);
                vec3 foundation = uPrimaryColor.rgb * luminance;
                gl_FragColor = vec4(
                  foundation * alpha * contourFalloff,
                  alpha * contourFalloff
                );
                return;
              }
              float eyeGradient = smoothstep(0.06, 0.9, vUv.y);
              float cheekGradient = clamp(length(vUv - vec2(0.5)) * 1.45, 0.0, 1.0);
              float gradient = mix(cheekGradient, eyeGradient, uParameters.z);
              vec3 color = mix(uPrimaryColor.rgb, uSecondaryColor.rgb, gradient * 0.62);
              vec2 shimmerDelta = (vUv - vec2(0.52, 0.43)) / vec2(0.34, 0.28);
              float shimmer = exp(-dot(shimmerDelta, shimmerDelta) * 2.0) *
                uParameters.y * uParameters.z * 0.18;
              color = mix(color, vec3(1.0), shimmer);
              gl_FragColor = vec4(color * alpha, alpha);
            }
        """

        private fun makeLipIndices(): ShortArray {
            val pointCount = OUTER_LIP.size
            val result = ShortArray((RING_FRACTIONS.size - 1) * pointCount * 6)
            var cursor = 0
            for (ring in 0 until RING_FRACTIONS.size - 1) {
                for (point in 0 until pointCount) {
                    val next = (point + 1) % pointCount
                    val a = (ring * pointCount + point).toShort()
                    val b = (ring * pointCount + next).toShort()
                    val c = ((ring + 1) * pointCount + point).toShort()
                    val d = ((ring + 1) * pointCount + next).toShort()
                    result[cursor++] = a
                    result[cursor++] = b
                    result[cursor++] = c
                    result[cursor++] = b
                    result[cursor++] = d
                    result[cursor++] = c
                }
            }
            return result
        }

        private fun makeStripIndices(
            ringCount: Int,
            pointCount: Int,
            closed: Boolean,
        ): ShortArray {
            val segmentCount = if (closed) pointCount else pointCount - 1
            val result = ShortArray((ringCount - 1) * segmentCount * 6)
            var cursor = 0
            for (ring in 0 until ringCount - 1) {
                for (point in 0 until segmentCount) {
                    val next = if (closed) (point + 1) % pointCount else point + 1
                    val a = (ring * pointCount + point).toShort()
                    val b = (ring * pointCount + next).toShort()
                    val c = ((ring + 1) * pointCount + point).toShort()
                    val d = ((ring + 1) * pointCount + next).toShort()
                    result[cursor++] = a
                    result[cursor++] = b
                    result[cursor++] = c
                    result[cursor++] = b
                    result[cursor++] = d
                    result[cursor++] = c
                }
            }
            return result
        }
    }

    private val thread = HandlerThread("GlamAR-OpenGL", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)
    private var released = false
    private var lastSubmissionSequence = 0L
    private var lastSourceSequence = 0L
    private val stabilizedLandmarks = FloatArray(468 * 3)
    private var hasStabilizedLandmarks = false
    private var eglDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface = EGL14.EGL_NO_SURFACE
    private var outputSurface: Surface? = null
    private var lipProgram = 0
    private var colorProgram = 0
    private var vertexBufferId = 0
    private var lipIndexBufferId = 0
    private var eyeIndexBufferId = 0
    private var cheekIndexBufferId = 0
    private var browIndexBufferId = 0
    private var eyelinerIndexBufferId = 0
    private var foundationIndexBufferId = 0
    private var lipIndexCount = 0
    private var eyeIndexCount = 0
    private var cheekIndexCount = 0
    private var browIndexCount = 0
    private var eyelinerIndexCount = 0
    private var foundationIndexCount = 0
    private var positionLocation = -1
    private var uvLocation = -1
    private var edgeAlphaLocation = -1
    private var baseColorLocation = -1
    private var parametersLocation = -1
    private var colorPositionLocation = -1
    private var colorUvLocation = -1
    private var colorEdgeAlphaLocation = -1
    private var primaryColorLocation = -1
    private var secondaryColorLocation = -1
    private var colorParametersLocation = -1
    private val outerX = FloatArray(OUTER_LIP.size)
    private val outerY = FloatArray(OUTER_LIP.size)
    private val innerX = FloatArray(INNER_LIP.size)
    private val innerY = FloatArray(INNER_LIP.size)
    private val lipVertices = FloatArray(RING_FRACTIONS.size * OUTER_LIP.size * FLOATS_PER_VERTEX)
    private val lipVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(lipVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
    private val eyeVertices = FloatArray(EYE_FRACTIONS.size * SIDE_A_EYE_UPPER.size * FLOATS_PER_VERTEX)
    private val eyeVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(eyeVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
    private val cheekVertices = FloatArray(CHEEK_FRACTIONS.size * CHEEK_SEGMENTS * FLOATS_PER_VERTEX)
    private val cheekVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(cheekVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
    private val browVertices = FloatArray(RIBBON_FRACTIONS.size * SIDE_A_BROW.size * FLOATS_PER_VERTEX)
    private val browVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(browVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
    private val eyelinerPointX = FloatArray(SIDE_A_EYE_UPPER.size + 2)
    private val eyelinerPointY = FloatArray(SIDE_A_EYE_UPPER.size + 2)
    private val eyelinerVertices = FloatArray(
        RIBBON_FRACTIONS.size * eyelinerPointX.size * FLOATS_PER_VERTEX,
    )
    private val eyelinerVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(eyelinerVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
    private val foundationVertices = FloatArray(468 * FLOATS_PER_VERTEX)
    private val foundationVertexBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(foundationVertices.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()

    init {
        surfaceProducer.setSize(pixelWidth, pixelHeight)
        surfaceProducer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceDestroyed() {
                handler.post { releaseEgl() }
            }

            override fun onSurfaceCleanup() {
                handler.post { releaseEgl() }
            }
        })
    }

    fun render(data: ByteBuffer, completion: (Boolean) -> Unit) {
        val copied = ByteBuffer.allocateDirect(data.remaining()).order(ByteOrder.LITTLE_ENDIAN)
        copied.put(data.duplicate()).flip()
        handler.post {
            val frame = GlamArRenderFrame.decode(copied)
            if (released || frame == null || frame.submissionSequence <= lastSubmissionSequence) {
                completion(false)
                return@post
            }
            lastSubmissionSequence = frame.submissionSequence
            stabilizeResidualNoise(frame)
            completion(draw(frame))
        }
    }

    fun clear(completion: (Boolean) -> Unit) {
        handler.post {
            hasStabilizedLandmarks = false
            lastSourceSequence = 0L
            completion(draw(null))
        }
    }

    private fun stabilizeResidualNoise(frame: GlamArRenderFrame) {
        if (!hasStabilizedLandmarks) {
            frame.landmarks.copyInto(stabilizedLandmarks, endIndex = stabilizedLandmarks.size)
            hasStabilizedLandmarks = true
            lastSourceSequence = frame.sourceSequence
            return
        }
        val predictionTick = frame.sourceSequence == lastSourceSequence
        var index = 0
        while (index < stabilizedLandmarks.size) {
            val deltaX = frame.landmarks[index] - stabilizedLandmarks[index]
            val deltaY = frame.landmarks[index + 1] - stabilizedLandmarks[index + 1]
            val pixelMotion = sqrt(
                deltaX * deltaX * pixelWidth.toFloat() * pixelWidth.toFloat() +
                    deltaY * deltaY * pixelHeight.toFloat() * pixelHeight.toFloat(),
            )
            val alpha = when {
                pixelMotion < if (predictionTick) 0.1f else 0.14f -> 0f
                pixelMotion < 0.42f -> if (predictionTick) 0.78f else 0.68f
                else -> 1f
            }
            stabilizedLandmarks[index] += deltaX * alpha
            stabilizedLandmarks[index + 1] += deltaY * alpha
            val depthAlpha = if (pixelMotion < 0.42f) 0.68f else 1f
            stabilizedLandmarks[index + 2] +=
                (frame.landmarks[index + 2] - stabilizedLandmarks[index + 2]) * depthAlpha
            frame.landmarks[index] = stabilizedLandmarks[index]
            frame.landmarks[index + 1] = stabilizedLandmarks[index + 1]
            frame.landmarks[index + 2] = stabilizedLandmarks[index + 2]
            index += 3
        }
        lastSourceSequence = frame.sourceSequence
    }

    private fun ensureEgl(): Boolean {
        if (
            eglDisplay != EGL14.EGL_NO_DISPLAY &&
            eglSurface != EGL14.EGL_NO_SURFACE &&
            lipProgram != 0 &&
            colorProgram != 0
        ) return true
        releaseEgl()
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return false
        val versions = IntArray(2)
        if (!EGL14.eglInitialize(display, versions, 0, versions, 1)) return false
        eglDisplay = display
        val configAttributes = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val configCount = IntArray(1)
        if (!EGL14.eglChooseConfig(display, configAttributes, 0, configs, 0, 1, configCount, 0)) {
            releaseEgl()
            return false
        }
        val config = configs[0] ?: run {
            releaseEgl()
            return false
        }
        val context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        if (context == EGL14.EGL_NO_CONTEXT) {
            releaseEgl()
            return false
        }
        eglContext = context
        val surface = surfaceProducer.surface
        outputSurface = surface
        val windowSurface = EGL14.eglCreateWindowSurface(
            display,
            config,
            surface,
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        if (windowSurface == EGL14.EGL_NO_SURFACE) {
            releaseEgl()
            return false
        }
        eglSurface = windowSurface
        if (!EGL14.eglMakeCurrent(display, windowSurface, windowSurface, context)) {
            releaseEgl()
            return false
        }
        if (!setupGlObjects()) {
            releaseEgl()
            return false
        }
        return true
    }

    private fun setupGlObjects(): Boolean {
        lipProgram = linkProgram(VERTEX_SHADER, LIP_FRAGMENT_SHADER)
        colorProgram = linkProgram(VERTEX_SHADER, COLOR_FRAGMENT_SHADER)
        if (lipProgram == 0 || colorProgram == 0) return false
        val ids = IntArray(7)
        GLES20.glGenBuffers(7, ids, 0)
        vertexBufferId = ids[0]
        lipIndexBufferId = ids[1]
        eyeIndexBufferId = ids[2]
        cheekIndexBufferId = ids[3]
        browIndexBufferId = ids[4]
        eyelinerIndexBufferId = ids[5]
        foundationIndexBufferId = ids[6]
        val lipIndices = makeLipIndices()
        val eyeIndices = makeStripIndices(EYE_FRACTIONS.size, SIDE_A_EYE_UPPER.size, false)
        val cheekIndices = makeStripIndices(CHEEK_FRACTIONS.size, CHEEK_SEGMENTS, true)
        val browIndices = makeStripIndices(RIBBON_FRACTIONS.size, SIDE_A_BROW.size, false)
        val eyelinerIndices = makeStripIndices(
            RIBBON_FRACTIONS.size,
            SIDE_A_EYE_UPPER.size + 2,
            false,
        )
        lipIndexCount = lipIndices.size
        eyeIndexCount = eyeIndices.size
        cheekIndexCount = cheekIndices.size
        browIndexCount = browIndices.size
        eyelinerIndexCount = eyelinerIndices.size
        foundationIndexCount = foundationIndices.size
        uploadIndices(lipIndexBufferId, lipIndices)
        uploadIndices(eyeIndexBufferId, eyeIndices)
        uploadIndices(cheekIndexBufferId, cheekIndices)
        uploadIndices(browIndexBufferId, browIndices)
        uploadIndices(eyelinerIndexBufferId, eyelinerIndices)
        uploadIndices(foundationIndexBufferId, foundationIndices)
        positionLocation = GLES20.glGetAttribLocation(lipProgram, "aPosition")
        uvLocation = GLES20.glGetAttribLocation(lipProgram, "aUv")
        edgeAlphaLocation = GLES20.glGetAttribLocation(lipProgram, "aEdgeAlpha")
        baseColorLocation = GLES20.glGetUniformLocation(lipProgram, "uBaseColor")
        parametersLocation = GLES20.glGetUniformLocation(lipProgram, "uParameters")
        colorPositionLocation = GLES20.glGetAttribLocation(colorProgram, "aPosition")
        colorUvLocation = GLES20.glGetAttribLocation(colorProgram, "aUv")
        colorEdgeAlphaLocation = GLES20.glGetAttribLocation(colorProgram, "aEdgeAlpha")
        primaryColorLocation = GLES20.glGetUniformLocation(colorProgram, "uPrimaryColor")
        secondaryColorLocation = GLES20.glGetUniformLocation(colorProgram, "uSecondaryColor")
        colorParametersLocation = GLES20.glGetUniformLocation(colorProgram, "uParameters")
        if (
            positionLocation < 0 ||
            uvLocation < 0 ||
            edgeAlphaLocation < 0 ||
            baseColorLocation < 0 ||
            parametersLocation < 0 ||
            colorPositionLocation < 0 ||
            colorUvLocation < 0 ||
            colorEdgeAlphaLocation < 0 ||
            primaryColorLocation < 0 ||
            secondaryColorLocation < 0 ||
            colorParametersLocation < 0
        ) return false
        return GLES20.glGetError() == GLES20.GL_NO_ERROR
    }

    private fun uploadIndices(bufferId: Int, indices: ShortArray) {
        val buffer: ShortBuffer = ByteBuffer
            .allocateDirect(indices.size * 2)
            .order(ByteOrder.nativeOrder())
            .asShortBuffer()
            .put(indices)
        buffer.flip()
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, bufferId)
        GLES20.glBufferData(
            GLES20.GL_ELEMENT_ARRAY_BUFFER,
            indices.size * 2,
            buffer,
            GLES20.GL_STATIC_DRAW,
        )
    }

    private fun draw(frame: GlamArRenderFrame?): Boolean {
        if (!ensureEgl()) return false
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) return false
        GLES20.glViewport(0, 0, pixelWidth, pixelHeight)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDisable(GLES20.GL_CULL_FACE)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (frame != null) {
            drawFoundation(frame)
            drawBlush(frame)
            drawEyeshadow(frame)
            drawBrows(frame)
            drawEyeliner(frame)
            drawLip(frame)
        }
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, System.nanoTime())
        val swapped = EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        if (swapped) surfaceProducer.scheduleFrame()
        return swapped && GLES20.glGetError() == GLES20.GL_NO_ERROR
    }

    private fun drawEyeshadow(frame: GlamArRenderFrame) {
        val layer = GlamArRenderFrame.eyeshadowLayerOffset
        if (frame.material[layer] <= 0.5f) return
        drawEyeshadowSide(frame, layer, SIDE_A_EYE_UPPER, true)
        drawEyeshadowSide(frame, layer, SIDE_B_EYE_UPPER, false)
    }

    private fun drawFoundation(frame: GlamArRenderFrame) {
        val layer = 4
        if (frame.material[layer] <= 0.5f) return
        val deltaX = landmarkX(frame, 454) - landmarkX(frame, 234)
        val deltaY = landmarkY(frame, 454) - landmarkY(frame, 234)
        val faceWidth = max(sqrt(deltaX * deltaX + deltaY * deltaY), 0.0001f)
        val centerX = landmarkX(frame, 1)
        val centerY = landmarkY(frame, 1)
        val detail = frame.material[layer + 2]
        val runtimeQuality = frame.face[13]
        var cursor = 0
        for (index in 0 until 468) {
            val localX = landmarkX(frame, index)
            val localY = landmarkY(frame, index)
            val normalizedX = (localX - centerX) / faceWidth
            val normalizedY = (localY - centerY) / faceWidth
            val radial = sqrt(
                normalizedX * normalizedX * 1.18f + normalizedY * normalizedY * 0.68f,
            )
            val contour = smoothStep(0.18f, 0.68f, radial)
            val centerHighlight = 1f - smoothStep(0.08f, 0.46f, radial)
            val depth = frame.landmarks[index * 3 + 2]
            val depthShade = ((-depth - 0.015f) * 2.6f).coerceIn(-0.12f, 0.14f)
            val tone = (
                0.52f + centerHighlight * (0.12f + detail * 0.11f) -
                    contour * detail * 0.19f + depthShade * detail * runtimeQuality
                ).coerceIn(0.22f, 0.82f)
            var x = localX
            if (frame.mirrored) x = 1f - x
            foundationVertices[cursor++] = x * 2f - 1f
            foundationVertices[cursor++] = 1f - localY * 2f
            foundationVertices[cursor++] = tone
            foundationVertices[cursor++] = radial
            foundationVertices[cursor++] = 1f
        }
        drawColorMesh(
            frame = frame,
            layer = layer,
            vertices = foundationVertices,
            vertexBuffer = foundationVertexBuffer,
            indexBuffer = foundationIndexBufferId,
            indexCount = foundationIndexCount,
            opacity = frame.material[layer + 1] * frame.face[7] * frame.face[12] *
                (0.82f + smoothStep(0.16f, 0.52f, frame.face[1]) * 0.18f) *
                (0.86f + smoothStep(0.035f, 0.18f, frame.face[17]) * 0.14f) *
                if (frame.face[15] > 0.5f) 0.045f else 0.105f,
            shimmer = detail * runtimeQuality,
            verticalBias = 2f,
        )
    }

    private fun drawEyeshadowSide(
        frame: GlamArRenderFrame,
        layer: Int,
        indices: IntArray,
        sideA: Boolean,
    ) {
        val firstOffset = indices.first() * 3
        val lastOffset = indices.last() * 3
        val axisX = frame.landmarks[lastOffset] - frame.landmarks[firstOffset]
        val axisY = frame.landmarks[lastOffset + 1] - frame.landmarks[firstOffset + 1]
        val eyeWidth = sqrt(axisX * axisX + axisY * axisY)
        if (eyeWidth <= 0.0001f) return
        var normalX = -axisY / eyeWidth
        var normalY = axisX / eyeWidth
        if (normalY > 0f) {
            normalX = -normalX
            normalY = -normalY
        }
        val openness = if (sideA) frame.face[9] else frame.face[10]
        val blinkStability = 0.62f + openness * 0.38f
        val lift = eyeWidth * (0.2f + frame.material[layer + 2] * 0.14f) * blinkStability
        var cursor = 0
        for (ring in EYE_FRACTIONS.indices) {
            val fraction = EYE_FRACTIONS[ring]
            for (pointIndex in indices.indices) {
                val offset = indices[pointIndex] * 3
                val taper = sin(pointIndex.toFloat() / (indices.size - 1).toFloat() * PI_F)
                val scale = lift * fraction * (0.58f + taper * 0.42f)
                var x = frame.landmarks[offset] + normalX * scale
                val y = frame.landmarks[offset + 1] + normalY * scale
                if (frame.mirrored) x = 1f - x
                eyeVertices[cursor++] = x * 2f - 1f
                eyeVertices[cursor++] = 1f - y * 2f
                eyeVertices[cursor++] = pointIndex.toFloat() / (indices.size - 1).toFloat()
                eyeVertices[cursor++] = fraction
                eyeVertices[cursor++] = EYE_ALPHAS[ring]
            }
        }
        val visibility = if (sideA) frame.face[5] else frame.face[6]
        val sideExposure = if (sideA) frame.face[2] else frame.face[3]
        val sideOpacity = ((0.76f + sideExposure * 0.46f) * visibility).coerceIn(0.1f, 1.12f)
        val opacity = (
            frame.material[layer + 1] * sideOpacity * frame.face[12] *
                if (frame.face[15] > 0.5f) 0.15f else 0.34f
            ).coerceIn(0f, 0.42f)
        drawColorMesh(
            frame = frame,
            layer = layer,
            vertices = eyeVertices,
            vertexBuffer = eyeVertexBuffer,
            indexBuffer = eyeIndexBufferId,
            indexCount = eyeIndexCount,
            opacity = opacity,
            shimmer = frame.material[layer + 2] * frame.face[8] *
                (0.68f + openness * 0.32f),
            verticalBias = 1f,
        )
    }

    private fun drawBlush(frame: GlamArRenderFrame) {
        val layer = GlamArRenderFrame.blushLayerOffset
        if (frame.material[layer] <= 0.5f) return
        val sideAX = landmarkX(frame, 234)
        val sideAY = landmarkY(frame, 234)
        val sideBX = landmarkX(frame, 454)
        val sideBY = landmarkY(frame, 454)
        val deltaX = sideBX - sideAX
        val deltaY = sideBY - sideAY
        val faceWidth = sqrt(deltaX * deltaX + deltaY * deltaY)
        if (faceWidth <= 0.0001f) return
        val axisX = deltaX / faceWidth
        val axisY = deltaY / faceWidth
        drawBlushSide(frame, layer, faceWidth, axisX, axisY, 117, 234, 50, true)
        drawBlushSide(frame, layer, faceWidth, axisX, axisY, 346, 454, 280, false)
    }

    private fun drawBlushSide(
        frame: GlamArRenderFrame,
        layer: Int,
        faceWidth: Float,
        axisX: Float,
        axisY: Float,
        anchorIndex: Int,
        edgeIndex: Int,
        highIndex: Int,
        sideA: Boolean,
    ) {
        val anchorX = landmarkX(frame, anchorIndex)
        val anchorY = landmarkY(frame, anchorIndex)
        val highMix = 0.12f + frame.material[layer + 2] * 0.2f
        var centerX = anchorX + (landmarkX(frame, highIndex) - anchorX) * highMix
        var centerY = anchorY + (landmarkY(frame, highIndex) - anchorY) * highMix
        centerX += (landmarkX(frame, 1) - centerX) * 0.05f
        centerY += (landmarkY(frame, 1) - centerY) * 0.05f
        val edgeDeltaX = anchorX - landmarkX(frame, edgeIndex)
        val edgeDeltaY = anchorY - landmarkY(frame, edgeIndex)
        val localSpan = sqrt(edgeDeltaX * edgeDeltaX + edgeDeltaY * edgeDeltaY)
        if (localSpan <= 0.0001f) return
        val perspective = (localSpan / (faceWidth * 0.2f)).coerceIn(0.72f, 1.06f)
        val halfWidth = localSpan * (1.35f + frame.material[layer + 2] * 0.34f) * 0.5f
        val halfHeight = localSpan * (0.84f + (1f - frame.material[layer + 2]) * 0.26f) * 0.5f
        val normalX = -axisY
        val normalY = axisX
        var cursor = 0
        for (ring in CHEEK_FRACTIONS.indices) {
            val radius = CHEEK_FRACTIONS[ring]
            for (segment in 0 until CHEEK_SEGMENTS) {
                val angle = segment.toFloat() / CHEEK_SEGMENTS.toFloat() * 2f * PI_F
                val cosine = cos(angle)
                val sine = sin(angle)
                var x = centerX + axisX * cosine * halfWidth * radius +
                    normalX * sine * halfHeight * radius
                val y = centerY + axisY * cosine * halfWidth * radius +
                    normalY * sine * halfHeight * radius
                if (frame.mirrored) x = 1f - x
                cheekVertices[cursor++] = x * 2f - 1f
                cheekVertices[cursor++] = 1f - y * 2f
                cheekVertices[cursor++] = 0.5f + cosine * radius * 0.5f
                cheekVertices[cursor++] = 0.5f + sine * radius * 0.5f
                cheekVertices[cursor++] = CHEEK_ALPHAS[ring]
            }
        }
        val visibility = if (sideA) frame.face[5] else frame.face[6]
        val sideExposure = if (sideA) frame.face[2] else frame.face[3]
        val sideOpacity = ((0.76f + sideExposure * 0.46f) * visibility).coerceIn(0.1f, 1.12f)
        drawColorMesh(
            frame = frame,
            layer = layer,
            vertices = cheekVertices,
            vertexBuffer = cheekVertexBuffer,
            indexBuffer = cheekIndexBufferId,
            indexCount = cheekIndexCount,
            opacity = frame.material[layer + 1] * perspective * sideOpacity * frame.face[12] *
                if (frame.face[15] > 0.5f) 0.13f else 0.31f,
            shimmer = 0f,
            verticalBias = 0f,
        )
    }

    private fun drawColorMesh(
        frame: GlamArRenderFrame,
        layer: Int,
        vertices: FloatArray,
        vertexBuffer: FloatBuffer,
        indexBuffer: Int,
        indexCount: Int,
        opacity: Float,
        shimmer: Float,
        verticalBias: Float,
    ) {
        vertexBuffer.clear()
        vertexBuffer.put(vertices).flip()
        GLES20.glUseProgram(colorProgram)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vertexBufferId)
        GLES20.glBufferData(
            GLES20.GL_ARRAY_BUFFER,
            vertices.size * 4,
            vertexBuffer,
            GLES20.GL_STREAM_DRAW,
        )
        val stride = FLOATS_PER_VERTEX * 4
        bindAttribute(colorPositionLocation, 2, stride, 0)
        bindAttribute(colorUvLocation, 2, stride, 2 * 4)
        bindAttribute(colorEdgeAlphaLocation, 1, stride, 4 * 4)
        val warmth = frame.face[4]
        val targetRed = if (warmth >= 0f) 1f else 0.624f
        val targetGreen = if (warmth >= 0f) 0.698f else 0.737f
        val targetBlue = if (warmth >= 0f) 0.561f else 0.91f
        val warmthMix = abs(warmth) * 0.075f
        var primaryRed = frame.material[layer + 3]
        var primaryGreen = frame.material[layer + 4]
        var primaryBlue = frame.material[layer + 5]
        primaryRed += (targetRed - primaryRed) * warmthMix
        primaryGreen += (targetGreen - primaryGreen) * warmthMix
        primaryBlue += (targetBlue - primaryBlue) * warmthMix
        var secondaryRed = frame.material[layer + 8]
        var secondaryGreen = frame.material[layer + 9]
        var secondaryBlue = frame.material[layer + 10]
        secondaryRed += (targetRed - secondaryRed) * warmthMix
        secondaryGreen += (targetGreen - secondaryGreen) * warmthMix
        secondaryBlue += (targetBlue - secondaryBlue) * warmthMix
        val chromaGuard = smoothStep(0.035f, 0.2f, frame.face[16])
        val contrastGuard = smoothStep(0.045f, 0.18f, frame.face[17])
        val saturationScale = 0.86f + chromaGuard * 0.11f + contrastGuard * 0.03f
        val primaryLuma = primaryRed * 0.2126f + primaryGreen * 0.7152f + primaryBlue * 0.0722f
        primaryRed = (primaryLuma + (primaryRed - primaryLuma) * saturationScale).coerceIn(0f, 1f)
        primaryGreen = (primaryLuma + (primaryGreen - primaryLuma) * saturationScale).coerceIn(0f, 1f)
        primaryBlue = (primaryLuma + (primaryBlue - primaryLuma) * saturationScale).coerceIn(0f, 1f)
        val secondaryLuma = secondaryRed * 0.2126f + secondaryGreen * 0.7152f + secondaryBlue * 0.0722f
        secondaryRed = (secondaryLuma + (secondaryRed - secondaryLuma) * saturationScale).coerceIn(0f, 1f)
        secondaryGreen = (secondaryLuma + (secondaryGreen - secondaryLuma) * saturationScale).coerceIn(0f, 1f)
        secondaryBlue = (secondaryLuma + (secondaryBlue - secondaryLuma) * saturationScale).coerceIn(0f, 1f)
        val exposureDelta = (frame.face[1] - 0.52f).coerceIn(-0.42f, 0.42f)
        val lightnessShift = exposureDelta * 0.035f - max(exposureDelta, 0f) * 0.04f
        primaryRed = (primaryRed + lightnessShift).coerceIn(0f, 1f)
        primaryGreen = (primaryGreen + lightnessShift).coerceIn(0f, 1f)
        primaryBlue = (primaryBlue + lightnessShift).coerceIn(0f, 1f)
        secondaryRed = (secondaryRed + lightnessShift).coerceIn(0f, 1f)
        secondaryGreen = (secondaryGreen + lightnessShift).coerceIn(0f, 1f)
        secondaryBlue = (secondaryBlue + lightnessShift).coerceIn(0f, 1f)
        GLES20.glUniform4f(primaryColorLocation, primaryRed, primaryGreen, primaryBlue, 1f)
        GLES20.glUniform4f(secondaryColorLocation, secondaryRed, secondaryGreen, secondaryBlue, 1f)
        GLES20.glUniform4f(
            colorParametersLocation,
            opacity.coerceIn(0f, 0.46f),
            shimmer,
            verticalBias,
            0f,
        )
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, indexBuffer)
        GLES20.glDrawElements(GLES20.GL_TRIANGLES, indexCount, GLES20.GL_UNSIGNED_SHORT, 0)
    }

    private fun landmarkX(frame: GlamArRenderFrame, index: Int): Float = frame.landmarks[index * 3]

    private fun landmarkY(frame: GlamArRenderFrame, index: Int): Float = frame.landmarks[index * 3 + 1]

    private fun drawBrows(frame: GlamArRenderFrame) {
        val layer = GlamArRenderFrame.browLayerOffset
        if (frame.material[layer] <= 0.5f) return
        drawBrowSide(frame, layer, SIDE_A_BROW, true)
        drawBrowSide(frame, layer, SIDE_B_BROW, false)
    }

    private fun drawBrowSide(
        frame: GlamArRenderFrame,
        layer: Int,
        indices: IntArray,
        sideA: Boolean,
    ) {
        val deltaX = landmarkX(frame, indices.last()) - landmarkX(frame, indices.first())
        val deltaY = landmarkY(frame, indices.last()) - landmarkY(frame, indices.first())
        val span = sqrt(deltaX * deltaX + deltaY * deltaY)
        if (span <= 0.0001f) return
        fillRibbonFromLandmarks(
            frame = frame,
            indices = indices,
            halfWidth = span * (0.05f + frame.material[layer + 2] * 0.035f) * 0.5f,
            vertices = browVertices,
        )
        val visibility = if (sideA) frame.face[5] else frame.face[6]
        val sideExposure = if (sideA) frame.face[2] else frame.face[3]
        val sideOpacity = ((0.76f + sideExposure * 0.46f) * visibility).coerceIn(0.1f, 1.12f)
        drawColorMesh(
            frame = frame,
            layer = layer,
            vertices = browVertices,
            vertexBuffer = browVertexBuffer,
            indexBuffer = browIndexBufferId,
            indexCount = browIndexCount,
            opacity = frame.material[layer + 1] * sideOpacity * frame.face[12] * 0.62f,
            shimmer = frame.material[layer + 2] * frame.face[8],
            verticalBias = 3f,
        )
    }

    private fun drawEyeliner(frame: GlamArRenderFrame) {
        val layer = GlamArRenderFrame.eyelinerLayerOffset
        if (frame.material[layer] <= 0.5f) return
        drawEyelinerSide(frame, layer, SIDE_A_EYE_UPPER, true, true)
        drawEyelinerSide(frame, layer, SIDE_B_EYE_UPPER, false, false)
    }

    private fun drawEyelinerSide(
        frame: GlamArRenderFrame,
        layer: Int,
        indices: IntArray,
        sideA: Boolean,
        tailAtStart: Boolean,
    ) {
        val firstX = landmarkX(frame, indices.first())
        val firstY = landmarkY(frame, indices.first())
        val lastX = landmarkX(frame, indices.last())
        val lastY = landmarkY(frame, indices.last())
        val deltaX = lastX - firstX
        val deltaY = lastY - firstY
        val eyeWidth = sqrt(deltaX * deltaX + deltaY * deltaY)
        if (eyeWidth <= 0.0001f) return
        val outerX = if (tailAtStart) firstX else lastX
        val outerY = if (tailAtStart) firstY else lastY
        val direction = if (outerX < landmarkX(frame, 1)) -1f else 1f
        val tailLength = eyeWidth * (0.1f + frame.material[layer + 2] * 0.24f)
        val controlX = outerX + direction * tailLength * 0.55f
        val controlY = outerY - tailLength * 0.08f
        val tailX = outerX + direction * tailLength
        val tailY = outerY - tailLength * (0.16f + frame.material[layer + 2] * 0.22f)
        if (tailAtStart) {
            eyelinerPointX[0] = tailX
            eyelinerPointY[0] = tailY
            eyelinerPointX[1] = controlX
            eyelinerPointY[1] = controlY
            for (index in indices.indices) {
                eyelinerPointX[index + 2] = landmarkX(frame, indices[index])
                eyelinerPointY[index + 2] = landmarkY(frame, indices[index])
            }
        } else {
            for (index in indices.indices) {
                eyelinerPointX[index] = landmarkX(frame, indices[index])
                eyelinerPointY[index] = landmarkY(frame, indices[index])
            }
            eyelinerPointX[indices.size] = controlX
            eyelinerPointY[indices.size] = controlY
            eyelinerPointX[indices.size + 1] = tailX
            eyelinerPointY[indices.size + 1] = tailY
        }
        val openness = if (sideA) frame.face[9] else frame.face[10]
        val halfWidth = eyeWidth * (0.02f + frame.material[layer + 2] * 0.02f) *
            (0.78f + openness * 0.22f) * 0.5f
        fillRibbon(
            frame = frame,
            pointsX = eyelinerPointX,
            pointsY = eyelinerPointY,
            pointCount = eyelinerPointX.size,
            halfWidth = halfWidth,
            vertices = eyelinerVertices,
        )
        val visibility = if (sideA) frame.face[5] else frame.face[6]
        val sideExposure = if (sideA) frame.face[2] else frame.face[3]
        val detailOpacity = (
            (0.76f + sideExposure * 0.46f) * visibility * frame.face[8]
            ).coerceIn(0.06f, 1.12f)
        drawColorMesh(
            frame = frame,
            layer = layer,
            vertices = eyelinerVertices,
            vertexBuffer = eyelinerVertexBuffer,
            indexBuffer = eyelinerIndexBufferId,
            indexCount = eyelinerIndexCount,
            opacity = frame.material[layer + 1] * detailOpacity * frame.face[12] * 0.9f,
            shimmer = frame.material[layer + 2] * frame.face[8],
            verticalBias = 4f,
        )
    }

    private fun fillRibbonFromLandmarks(
        frame: GlamArRenderFrame,
        indices: IntArray,
        halfWidth: Float,
        vertices: FloatArray,
    ) {
        for (index in indices.indices) {
            eyelinerPointX[index] = landmarkX(frame, indices[index])
            eyelinerPointY[index] = landmarkY(frame, indices[index])
        }
        fillRibbon(
            frame = frame,
            pointsX = eyelinerPointX,
            pointsY = eyelinerPointY,
            pointCount = indices.size,
            halfWidth = halfWidth,
            vertices = vertices,
        )
    }

    private fun fillRibbon(
        frame: GlamArRenderFrame,
        pointsX: FloatArray,
        pointsY: FloatArray,
        pointCount: Int,
        halfWidth: Float,
        vertices: FloatArray,
    ) {
        var cursor = 0
        for (ribbon in RIBBON_FRACTIONS.indices) {
            for (pointIndex in 0 until pointCount) {
                val previous = max(0, pointIndex - 1)
                val next = min(pointCount - 1, pointIndex + 1)
                val tangentX = pointsX[next] - pointsX[previous]
                val tangentY = pointsY[next] - pointsY[previous]
                val length = max(sqrt(tangentX * tangentX + tangentY * tangentY), 0.0001f)
                val progress = pointIndex.toFloat() / max(pointCount - 1, 1).toFloat()
                val endpointScale = 0.48f + sin(progress * PI_F) * 0.52f
                var x = pointsX[pointIndex] + (-tangentY / length) * halfWidth *
                    RIBBON_FRACTIONS[ribbon] * endpointScale
                val y = pointsY[pointIndex] + (tangentX / length) * halfWidth *
                    RIBBON_FRACTIONS[ribbon] * endpointScale
                if (frame.mirrored) x = 1f - x
                val longitudinalFade = min(
                    min(progress / 0.16f, (1f - progress) / 0.16f),
                    1f,
                ).coerceAtLeast(0f)
                vertices[cursor++] = x * 2f - 1f
                vertices[cursor++] = 1f - y * 2f
                vertices[cursor++] = progress
                vertices[cursor++] = (RIBBON_FRACTIONS[ribbon] + 1f) * 0.5f
                vertices[cursor++] = RIBBON_ALPHAS[ribbon] * longitudinalFade
            }
        }
    }

    private fun drawLip(frame: GlamArRenderFrame) {
        val lip = GlamArRenderFrame.lipLayerOffset
        if (frame.material[lip] <= 0.5f) return
        var minX = Float.POSITIVE_INFINITY
        var maxX = Float.NEGATIVE_INFINITY
        var minY = Float.POSITIVE_INFINITY
        var maxY = Float.NEGATIVE_INFINITY
        for (index in OUTER_LIP.indices) {
            val landmarkOffset = OUTER_LIP[index] * 3
            val x = frame.landmarks[landmarkOffset]
            val y = frame.landmarks[landmarkOffset + 1]
            outerX[index] = x
            outerY[index] = y
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        val seamY = (
            frame.landmarks[13 * 3 + 1] +
                frame.landmarks[14 * 3 + 1]
            ) * 0.5f
        val mouthCutout = smoothStep(0.03f, 0.34f, frame.face[11])
        for (index in INNER_LIP.indices) {
            val landmarkOffset = INNER_LIP[index] * 3
            val x = frame.landmarks[landmarkOffset]
            val y = seamY + (frame.landmarks[landmarkOffset + 1] - seamY) * mouthCutout
            innerX[index] = x
            innerY[index] = y
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        val width = max(maxX - minX, 0.0001f)
        val height = max(maxY - minY, 0.0001f)
        var cursor = 0
        for (ring in RING_FRACTIONS.indices) {
            for (pointIndex in OUTER_LIP.indices) {
                val fraction = RING_FRACTIONS[ring]
                val localX = outerX[pointIndex] +
                    (innerX[pointIndex] - outerX[pointIndex]) * fraction
                val y = outerY[pointIndex] +
                    (innerY[pointIndex] - outerY[pointIndex]) * fraction
                var x = localX
                if (frame.mirrored) x = 1f - x
                lipVertices[cursor++] = x * 2f - 1f
                lipVertices[cursor++] = 1f - y * 2f
                lipVertices[cursor++] = (localX - minX) / width
                lipVertices[cursor++] = (y - minY) / height
                lipVertices[cursor++] = RING_ALPHAS[ring]
            }
        }
        lipVertexBuffer.clear()
        lipVertexBuffer.put(lipVertices).flip()

        GLES20.glUseProgram(lipProgram)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vertexBufferId)
        GLES20.glBufferData(
            GLES20.GL_ARRAY_BUFFER,
            lipVertices.size * 4,
            lipVertexBuffer,
            GLES20.GL_STREAM_DRAW,
        )
        val stride = FLOATS_PER_VERTEX * 4
        bindAttribute(positionLocation, 2, stride, 0)
        bindAttribute(uvLocation, 2, stride, 2 * 4)
        bindAttribute(edgeAlphaLocation, 1, stride, 4 * 4)

        var red = frame.material[lip + 3]
        var green = frame.material[lip + 4]
        var blue = frame.material[lip + 5]
        val warmth = frame.face[4]
        val targetRed = if (warmth >= 0f) 1f else 0.624f
        val targetGreen = if (warmth >= 0f) 0.698f else 0.737f
        val targetBlue = if (warmth >= 0f) 0.561f else 0.91f
        val warmthMix = abs(warmth) * 0.075f
        red += (targetRed - red) * warmthMix
        green += (targetGreen - green) * warmthMix
        blue += (targetBlue - blue) * warmthMix
        val chromaGuard = smoothStep(0.035f, 0.2f, frame.face[16])
        val contrastGuard = smoothStep(0.045f, 0.18f, frame.face[17])
        val saturationScale = 0.86f + chromaGuard * 0.11f + contrastGuard * 0.03f
        val luminance = red * 0.299f + green * 0.587f + blue * 0.114f
        red = luminance + (red - luminance) * saturationScale
        green = luminance + (green - luminance) * saturationScale
        blue = luminance + (blue - luminance) * saturationScale
        val exposureDelta = (frame.face[1] - 0.52f).coerceIn(-0.42f, 0.42f)
        val lightnessShift = exposureDelta * 0.035f - max(exposureDelta, 0f) * 0.04f
        red = (red + lightnessShift).coerceIn(0f, 1f)
        green = (green + lightnessShift).coerceIn(0f, 1f)
        blue = (blue + lightnessShift).coerceIn(0f, 1f)
        val centralOpacity = ((0.78f + frame.face[1] * 0.42f) * frame.face[7]).coerceIn(0.64f, 1.1f)
        val materialMix = if (frame.face[15] > 0.5f) 0.34f else 1f
        val alpha = (
            frame.material[lip + 1] * centralOpacity * frame.face[12] * materialMix
            ).coerceIn(0f, 1f)
        GLES20.glUniform4f(baseColorLocation, red, green, blue, 1f)
        GLES20.glUniform4f(
            parametersLocation,
            alpha,
            frame.material[2],
            1f - frame.face[11] * 0.34f,
            frame.face[8],
        )
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, lipIndexBufferId)
        GLES20.glDrawElements(GLES20.GL_TRIANGLES, lipIndexCount, GLES20.GL_UNSIGNED_SHORT, 0)
    }

    private fun bindAttribute(location: Int, size: Int, stride: Int, offset: Int) {
        GLES20.glEnableVertexAttribArray(location)
        GLES20.glVertexAttribPointer(location, size, GLES20.GL_FLOAT, false, stride, offset)
    }

    private fun linkProgram(vertexSource: String, fragmentSource: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            if (status[0] == 0) {
                GLES20.glDeleteShader(shader)
                return 0
            }
            return shader
        }
        val vertex = compile(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = compile(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        if (vertex == 0 || fragment == 0) return 0
        val linked = GLES20.glCreateProgram()
        GLES20.glAttachShader(linked, vertex)
        GLES20.glAttachShader(linked, fragment)
        GLES20.glLinkProgram(linked)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        val status = IntArray(1)
        GLES20.glGetProgramiv(linked, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            GLES20.glDeleteProgram(linked)
            return 0
        }
        return linked
    }

    private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
        val t = ((value - edge0) / max(edge1 - edge0, 0.0001f)).coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }

    fun release(onGlReleased: () -> Unit) {
        handler.post {
            released = true
            releaseEgl()
            onGlReleased()
            thread.quitSafely()
        }
    }

    fun releaseTextureEntry() {
        surfaceProducer.release()
    }

    private fun releaseEgl() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                eglDisplay,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        outputSurface?.release()
        outputSurface = null
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        lipProgram = 0
        colorProgram = 0
        vertexBufferId = 0
        lipIndexBufferId = 0
        eyeIndexBufferId = 0
        cheekIndexBufferId = 0
        browIndexBufferId = 0
        eyelinerIndexBufferId = 0
        foundationIndexBufferId = 0
        positionLocation = -1
        uvLocation = -1
        edgeAlphaLocation = -1
        baseColorLocation = -1
        parametersLocation = -1
        colorPositionLocation = -1
        colorUvLocation = -1
        colorEdgeAlphaLocation = -1
        primaryColorLocation = -1
        secondaryColorLocation = -1
        colorParametersLocation = -1
    }
}

class OpenGlMakeupBridge(
    private val flutterEngine: FlutterEngine,
    context: Context,
) {
    companion object {
        private const val CONTROL_CHANNEL = "glamar/ar_opengl/control"
        private const val FRAME_CHANNEL = "glamar/ar_opengl/frames"
    }

    private val messenger = flutterEngine.dartExecutor.binaryMessenger
    private val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)
    private val frameChannel = BasicMessageChannel(messenger, FRAME_CHANNEL, BinaryCodec.INSTANCE_DIRECT)
    private var renderer: GlamArOpenGlRenderer? = null

    init {
        controlChannel.setMethodCallHandler(::handleMethod)
        frameChannel.setMessageHandler { message, reply ->
            val current = renderer
            if (current == null || message == null) {
                reply.reply(null)
                return@setMessageHandler
            }
            val startedAt = System.nanoTime()
            current.render(message) { rendered ->
                mainHandler.post {
                    val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000f
                    val thermalLevel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        powerManager.currentThermalStatus.coerceIn(0, 4)
                    } else {
                        0
                    }
                    val response = ByteBuffer.allocateDirect(6).order(ByteOrder.LITTLE_ENDIAN)
                    response.put(if (rendered) 1 else 0)
                        .putFloat(elapsedMs)
                        .put(thermalLevel.toByte())
                        .flip()
                    reply.reply(response)
                }
            }
        }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                val current = renderer
                if (current != null) {
                    result.success(surfaceResult(current))
                    return
                }
                val width = (call.argument<Int>("pixelWidth") ?: 720).coerceIn(360, 1080)
                val height = (call.argument<Int>("pixelHeight") ?: 1280).coerceIn(640, 1920)
                val topologyBytes = call.argument<ByteArray>("faceMeshIndices")
                if (
                    topologyBytes == null ||
                    topologyBytes.size < 6 ||
                    topologyBytes.size % 2 != 0
                ) {
                    result.error(
                        "invalid_face_topology",
                        "Dense face mesh topology is missing or invalid.",
                        null,
                    )
                    return
                }
                val topology = ByteBuffer.wrap(topologyBytes)
                    .order(ByteOrder.LITTLE_ENDIAN)
                    .asShortBuffer()
                val foundationIndices = ShortArray(topology.remaining())
                topology.get(foundationIndices)
                val producer = flutterEngine.renderer.createSurfaceProducer()
                val created = GlamArOpenGlRenderer(
                    producer,
                    width,
                    height,
                    foundationIndices,
                )
                renderer = created
                result.success(surfaceResult(created))
            }
            "clear" -> {
                renderer?.clear { mainHandler.post { result.success(null) } }
                    ?: result.success(null)
            }
            "dispose" -> {
                disposeRenderer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun surfaceResult(renderer: GlamArOpenGlRenderer): Map<String, Any> = mapOf(
        "textureId" to renderer.textureId,
        "pixelWidth" to renderer.pixelWidth,
        "pixelHeight" to renderer.pixelHeight,
    )

    private fun disposeRenderer() {
        val current = renderer
        renderer = null
        current?.release {
            mainHandler.post { current.releaseTextureEntry() }
        }
    }

    fun dispose() {
        controlChannel.setMethodCallHandler(null)
        frameChannel.setMessageHandler(null)
        disposeRenderer()
    }
}
