import 'package:flutter/foundation.dart';

import 'browser_player.dart';
import 'desktop_platform.dart';

bool get supportsVideoPlayback =>
    browserMediaAvailable ||
    (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || isWindowsDesktop));
