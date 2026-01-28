import 'package:flutter/foundation.dart';

/// Prints debug messages with the [cached_video_player_plus] prefix.
/// 
/// This allows for easy filtering in terminal logs (e.g. using grep).
void cvppLog(String message, {int? wrapWidth}) {
  if (kDebugMode) {
    debugPrint('cached_video_player_plus: $message', wrapWidth: wrapWidth);
  }
}
