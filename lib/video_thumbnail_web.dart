import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:get_video_thumbnail/src/image_format.dart';
import 'package:get_video_thumbnail/src/video_thumbnail_platform.dart';
import 'package:web/web.dart' as web;

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = <int, String>{
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = <int, String>{
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage =
    'No further diagnostic information can be determined or provided.';

/// A web implementation of the VideoThumbnailPlatform of the VideoThumbnail plugin.
/// Rewritten to use package:web + dart:js_interop for WASM compatibility.
class VideoThumbnailWeb extends VideoThumbnailPlatform {
  /// Constructs a VideoThumbnailWeb
  VideoThumbnailWeb();

  static void registerWith(Registrar registrar) {
    VideoThumbnailPlatform.instance = VideoThumbnailWeb();
  }

  @override
  Future<List<XFile>> thumbnailFiles({
    required List<String> videos,
    required Map<String, String>? headers,
    required String? thumbnailPath,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    int? timeMs,
    required int quality,
  }) async {
    final results = <XFile>[];

    for (final video in videos) {
      results.add(
        await thumbnailFile(
          video: video,
          headers: headers,
          thumbnailPath: thumbnailPath,
          imageFormat: imageFormat,
          maxHeight: maxHeight,
          maxWidth: maxWidth,
          timeMs: timeMs,
          quality: quality,
        ),
      );
    }

    return results;
  }

  @override
  Future<XFile> thumbnailFile({
    required String video,
    required Map<String, String>? headers,
    required String? thumbnailPath,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    int? timeMs,
    required int quality,
  }) async {
    final blob = await _createThumbnail(
      videoSrc: video,
      headers: headers,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs ?? 0,
      quality: quality,
    );

    final url = web.URL.createObjectURL(blob);
    return XFile(url, mimeType: blob.type);
  }

  @override
  Future<Uint8List> thumbnailData({
    required String video,
    required Map<String, String>? headers,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    int? timeMs,
    required int quality,
  }) async {
    final blob = await _createThumbnail(
      videoSrc: video,
      headers: headers,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs ?? 0,
      quality: quality,
    );
    final arrayBuffer = await blob.arrayBuffer().toDart;
    return arrayBuffer.toDart.asUint8List();
  }

  Future<web.Blob> _createThumbnail({
    required String videoSrc,
    required Map<String, String>? headers,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    required int quality,
    int timeMs = 0,
  }) async {
    final video = web.HTMLVideoElement();
    final timeSec = math.max(timeMs / 1000, 0);
    final fetchVideo = headers != null && headers.isNotEmpty;
    String? objectUrl;

    try {
      video.preload = 'metadata';

      // Load the video source
      if (fetchVideo) {
        final blob = await _fetchVideoByHeaders(
          videoSrc: videoSrc,
          headers: headers,
        );
        objectUrl = web.URL.createObjectURL(blob);
        video.src = objectUrl;
      } else {
        video.crossOrigin = 'Anonymous';
        video.src = videoSrc;
      }

      // Wait for metadata, handling errors via a race
      await Future.any([
        video.onLoadedMetadata.first,
        video.onError.first.then((_) => throw _createVideoError(video)),
      ]);

      // Seek to the requested time to ensure a decodable frame is available
      video.currentTime = timeSec;
      await Future.any([
        video.onSeeked.first,
        video.onError.first.then((_) => throw _createVideoError(video)),
      ]);

      // Draw the frame to a canvas
      final canvas = web.HTMLCanvasElement();
      final ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;

      if (maxWidth == 0 && maxHeight == 0) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        ctx.drawImage(video, 0, 0);
      } else {
        final aspectRatio = video.videoWidth / video.videoHeight;
        var targetWidth = maxWidth;
        var targetHeight = maxHeight;
        if (targetWidth == 0) {
          targetWidth = (targetHeight * aspectRatio).round();
        } else if (targetHeight == 0) {
          targetHeight = (targetWidth / aspectRatio).round();
        }

        final inputAspectRatio = targetWidth / targetHeight;
        if (aspectRatio > inputAspectRatio) {
          targetHeight = (targetWidth / aspectRatio).round();
        } else {
          targetWidth = (targetHeight * aspectRatio).round();
        }

        canvas.width = targetWidth;
        canvas.height = targetHeight;
        ctx.drawImage(video, 0, 0, targetWidth, targetHeight);
      }

      // Export the canvas as a blob
      final completer = Completer<web.Blob>();
      canvas.toBlob(
        (web.Blob? blob) {
          if (blob != null) {
            completer.complete(blob);
          } else {
            completer.completeError(
              PlatformException(
                code: 'CANVAS_EXPORT_ERROR',
                message: 'toBlob returned null',
              ),
            );
          }
        }.toJS,
        _imageFormatToCanvasFormat(imageFormat),
        (quality / 100).toJS,
      );
      return await completer.future;
    } finally {
      // Clean up to prevent memory leaks.
      if (objectUrl != null) web.URL.revokeObjectURL(objectUrl);
      video.src = '';
      video.load();
    }
  }

  // The Event itself does not contain info about the actual error.
  // We need to look at the HTMLMediaElement.error.
  // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/error
  PlatformException _createVideoError(web.HTMLVideoElement video) {
    final error = video.error;
    if (error != null) {
      return PlatformException(
        code: _kErrorValueToErrorName[error.code] ?? 'UNKNOWN_ERROR',
        message: error.message.isNotEmpty ? error.message : _kDefaultErrorMessage,
        details: _kErrorValueToErrorDescription[error.code],
      );
    }
    return PlatformException(
      code: 'UNKNOWN_ERROR',
      message: _kDefaultErrorMessage,
    );
  }

  /// Fetches video as a blob using custom [headers].
  Future<web.Blob> _fetchVideoByHeaders({
    required String videoSrc,
    required Map<String, String> headers,
  }) async {
    final headersInit = web.Headers();
    // ignore: unnecessary_lambdas - tearoffs of external interop members are disallowed in WASM
    headers.forEach((key, value) => headersInit.append(key, value));

    final response = await web.window
        .fetch(
          videoSrc.toJS,
          web.RequestInit(
            method: 'GET',
            headers: headersInit,
          ),
        )
        .toDart;

    if (!response.ok) {
      throw PlatformException(
        code: 'VIDEO_FETCH_ERROR',
        message: 'Status: ${response.statusText}',
      );
    }

    final blob = await response.blob().toDart;
    return blob;
  }

  String _imageFormatToCanvasFormat(ImageFormat format) => switch (format) {
        ImageFormat.JPEG => 'image/jpeg',
        ImageFormat.PNG => 'image/png',
        ImageFormat.WEBP => 'image/webp',
      };
}
