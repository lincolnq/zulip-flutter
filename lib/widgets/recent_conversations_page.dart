import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../model/recent_conversations.dart';
import 'icons.dart';
import 'message_list.dart';
import 'page.dart';
import 'store.dart';
import 'theme.dart';
import 'unread_count_badge.dart';
import 'user.dart';

class RecentConversationsPageBody extends StatefulWidget {
  const RecentConversationsPageBody({super.key});

  @override
  State<RecentConversationsPageBody> createState() => _RecentConversationsPageBodyState();
}

/// Buffer in pixels before triggering a fetch for more conversations.
const double _kFetchBufferPixels = 500;

class _RecentConversationsPageBodyState extends State<RecentConversationsPageBody>
    with PerAccountStoreAwareStateMixin<RecentConversationsPageBody> {
  RecentConversationsView? model;

  @override
  void onNewStore() {
    model?.removeListener(_modelChanged);
    final store = PerAccountStoreWidget.of(context);
    model = store.recentConversationsView
      ..addListener(_modelChanged);

    // Trigger initial fetch to populate previews
    // PerAccountStore implements ChannelStore
    model!.fetchInitial(store.connection, store);
  }

  @override
  void dispose() {
    model?.removeListener(_modelChanged);
    super.dispose();
  }

  void _modelChanged() {
    setState(() {
      // The actual state lives in [model].
    });
  }

  void _navigateToConversation(RecentConversation conversation) {
    Navigator.push(context,
      MessageListPage.buildRoute(context: context,
        narrow: conversation.narrow));
  }

  void _handleScrollMetrics(ScrollMetrics metrics) {
    final store = PerAccountStoreWidget.of(context);
    // Trigger fetch when near bottom of list
    if (metrics.extentAfter < _kFetchBufferPixels) {
      model?.fetchOlder(store.connection, store);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      _handleScrollMetrics(notification.metrics);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final sorted = model!.sorted;

    if (sorted.isEmpty && !model!.isBackfilling) {
      return const PageBodyEmptyContentPlaceholder(
        header: 'No recent conversations',
        message: 'Your recent conversations will appear here');
    }

    return SafeArea(
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: ListView.builder(
          itemCount: sorted.length + (model!.isBackfilling ? 1 : 0),
          itemBuilder: (context, index) {
            // Show loading indicator at the end while backfilling
            if (index == sorted.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final conversation = sorted[index];
            return RecentConversationItem(
              conversation: conversation,
              onTap: () => _navigateToConversation(conversation),
            );
          },
        ),
      ),
    );
  }
}

class RecentConversationItem extends StatelessWidget {
  const RecentConversationItem({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final RecentConversation conversation;
  final VoidCallback onTap;

  static const double _avatarSize = 40;

  @override
  Widget build(BuildContext context) {
    final store = PerAccountStoreWidget.of(context);
    final designVariables = DesignVariables.of(context);

    final Widget leading;
    final Widget title;

    switch (conversation) {
      case RecentTopicConversation(:final streamId, :final topic):
        final subscription = store.subscriptions[streamId];
        final streamName = subscription?.name ?? '(unknown channel)';
        final streamColor = subscription != null
            ? Color(0xff000000 | subscription.color)
            : designVariables.icon;

        leading = Container(
          width: _avatarSize,
          height: _avatarSize,
          decoration: BoxDecoration(
            color: streamColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            subscription?.isWebPublic == true
                ? ZulipIcons.globe
                : ZulipIcons.hash_italic,
            size: 20,
            color: streamColor,
          ),
        );

        title = Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '#$streamName',
              style: TextStyle(
                color: streamColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: ' > ',
              style: TextStyle(color: designVariables.icon),
            ),
            TextSpan(
              text: topic.displayName,
              style: TextStyle(color: designVariables.labelMenuButton),
            ),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, height: 20 / 16),
        );

      case RecentDmConversation(:final dmNarrow):
        int? userIdForPresence;
        final Widget avatar;
        final InlineSpan titleSpan;

        switch (dmNarrow.otherRecipientIds) {
          case []:
            titleSpan = TextSpan(text: store.selfUser.fullName, children: [
              UserStatusEmoji.asWidgetSpan(userId: store.selfUserId,
                fontSize: 16, textScaler: MediaQuery.textScalerOf(context)),
            ]);
            avatar = AvatarImage(userId: store.selfUserId, size: _avatarSize);
          case [var otherUserId]:
            titleSpan = TextSpan(text: store.userDisplayName(otherUserId), children: [
              UserStatusEmoji.asWidgetSpan(userId: otherUserId,
                fontSize: 16, textScaler: MediaQuery.textScalerOf(context)),
            ]);
            avatar = AvatarImage(userId: otherUserId, size: _avatarSize);
            userIdForPresence = otherUserId;
          default:
            titleSpan = TextSpan(
              text: dmNarrow.otherRecipientIds.map(store.userDisplayName).join(', '));
            avatar = ColoredBox(color: designVariables.avatarPlaceholderBg,
              child: Center(
                child: Icon(color: designVariables.avatarPlaceholderIcon,
                  ZulipIcons.group_dm)));
        }

        leading = AvatarShape(
          size: _avatarSize,
          borderRadius: 4,
          backgroundColor: userIdForPresence != null ? designVariables.background : null,
          userIdForPresence: userIdForPresence,
          child: avatar,
        );

        title = Text.rich(
          titleSpan,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            height: 20 / 16,
            color: designVariables.labelMenuButton,
            fontWeight: FontWeight.w600,
          ),
        );
    }

    // Get unread count
    final unreadCount = switch (conversation) {
      RecentTopicConversation(:final streamId, :final topic) =>
        store.unreads.countInTopicNarrow(streamId, topic),
      RecentDmConversation(:final dmNarrow) =>
        store.unreads.countInDmNarrow(dmNarrow),
    };

    // Build preview text
    final previewText = conversation.previewText;
    final senderName = store.userDisplayName(conversation.latestSenderId);

    return Material(
      color: designVariables.background,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 8),
                        _RecencyIndicator(timestamp: conversation.latestTimestamp),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      previewText != null
                          ? '$senderName: $previewText'
                          : '$senderName: ...',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 18 / 14,
                        color: designVariables.labelEdited,
                      ),
                    ),
                  ],
                ),
              ),
              if (unreadCount > 0) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: UnreadCountBadge(
                    channelIdForBackground: switch (conversation) {
                      RecentTopicConversation(:final streamId) => streamId,
                      RecentDmConversation() => null,
                    },
                    count: unreadCount,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecencyIndicator extends StatelessWidget {
  const _RecencyIndicator({required this.timestamp});

  final int timestamp;

  @override
  Widget build(BuildContext context) {
    final designVariables = DesignVariables.of(context);
    final formatted = _formatRelativeTime(timestamp);

    return Text(
      formatted,
      style: TextStyle(
        fontSize: 12,
        height: 16 / 12,
        color: designVariables.labelTime,
      ),
    );
  }

  static String _formatRelativeTime(int unixTimestamp) {
    if (unixTimestamp == 0) return '';

    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(unixTimestamp * 1000);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';

    // Check if it was yesterday
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (time.isAfter(yesterday)) return 'Yesterday';

    // Within the last week, show day name
    if (diff.inDays < 7) return DateFormat.E().format(time);

    // Older: show month and day
    return DateFormat.MMMd().format(time);
  }
}
