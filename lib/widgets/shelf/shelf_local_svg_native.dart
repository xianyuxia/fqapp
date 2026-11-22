import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

Widget shelfLocalSvg(
  File file, {
  required BoxFit fit,
  required WidgetBuilder placeholderBuilder,
}) => SvgPicture.file(file, fit: fit, placeholderBuilder: placeholderBuilder);
