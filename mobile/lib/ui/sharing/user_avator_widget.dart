import 'package:flutter/material.dart';
import "package:photos/extensions/user_extension.dart";
import "package:photos/models/api/collection/user.dart";
import 'package:photos/theme/colors.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:tuple/tuple.dart';

enum AvatarType { small, mini, tiny, extra }

class UserAvatarWidget extends StatelessWidget {
  final User user;
  final AvatarType type;
  final int currentUserID;
  final bool thumbnailView;

  const UserAvatarWidget(
    this.user, {
    super.key,
    this.currentUserID = -1,
    this.type = AvatarType.mini,
    this.thumbnailView = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final displayChar = (user.displayName == null || user.displayName!.isEmpty)
        ? ((user.email.isEmpty) ? " " : user.email.substring(0, 1))
        : user.displayName!.substring(0, 1);
    Color decorationColor;
    if (user.id == null || user.id! <= 0 || user.id == currentUserID) {
      decorationColor = Colors.black;
    } else {
      decorationColor = colorScheme
          .avatarColors[(user.id!).remainder(colorScheme.avatarColors.length)];
    }

    final avatarStyle = getAvatarStyle(context, type);
    final double size = avatarStyle.item1;
    final TextStyle textStyle = avatarStyle.item2;
    return Container(
      height: size,
      width: size,
      padding: thumbnailView
          ? const EdgeInsets.only(bottom: 1)
          : const EdgeInsets.all(2),
      decoration: thumbnailView
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              color: decorationColor,
              border: Border.all(
                color: strokeBaseDark,
                width: 1.0,
              ),
            ),
      child: CircleAvatar(
        backgroundColor: decorationColor,
        child: Text(
          displayChar.toUpperCase(),
          // fixed color
          style: textStyle.copyWith(color: Colors.white),
        ),
      ),
    );
  }

  Tuple2<double, TextStyle> getAvatarStyle(
    BuildContext context,
    AvatarType type,
  ) {
    final enteTextTheme = getEnteTextTheme(context);
    switch (type) {
      case AvatarType.small:
        return Tuple2(36.0, enteTextTheme.small);
      case AvatarType.mini:
        return Tuple2(24.0, enteTextTheme.mini);
      case AvatarType.tiny:
        return Tuple2(18.0, enteTextTheme.tiny);
      case AvatarType.extra:
        return Tuple2(18.0, enteTextTheme.tiny);
    }
  }
}
