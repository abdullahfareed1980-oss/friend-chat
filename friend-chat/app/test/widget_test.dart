import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/theme/friend_chat_theme.dart';

void main() {
  test('Friend Chat theme builds correctly', () {
    final theme = buildFriendChatTheme();
    expect(theme.scaffoldBackgroundColor, FcColors.midnight);
    expect(theme.colorScheme.primary, FcColors.indigo);
    expect(theme.colorScheme.secondary, FcColors.mint);
  });
}
