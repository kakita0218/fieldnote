import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool isSimplifiedMobile(BuildContext context) {
  if (kIsWeb) return false;
  if (defaultTargetPlatform == TargetPlatform.android) return true;
  return defaultTargetPlatform == TargetPlatform.iOS &&
      MediaQuery.sizeOf(context).shortestSide < 600;
}
