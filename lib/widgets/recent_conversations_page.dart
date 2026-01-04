import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

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
  final ScrollController _scrollController = ScrollController();

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
    _scrollController.dispose();
    super.dispose();
  }

  void _modelChanged() {
    setState(() {
      // The actual state lives in [model].
    });

    // After the frame renders, check if we need more content to fill the viewport
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchMoreIfNeeded();
    });
  }

  void _fetchMoreIfNeeded() {
    if (!mounted) return;
    final model = this.model;
    if (model == null || model.isBackfilling || model.hasReachedOldest) return;

    // Check if content fills the viewport
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    // If maxScrollExtent is 0, content doesn't fill the viewport - fetch more
    if (position.maxScrollExtent == 0) {
      final store = PerAccountStoreWidget.of(context);
      model.fetchOlder(store.connection, store);
    }
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
          controller: _scrollController,
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

        title = _ChannelTopicTitle(
          channelName: streamName,
          channelColor: streamColor,
          topicName: topic.displayName ?? store.realmEmptyTopicDisplayName,
          topicStyle: TextStyle(
            color: designVariables.labelMenuButton,
            fontStyle: topic.displayName == null ? FontStyle.italic : null,
            fontSize: 16,
            height: 20 / 16,
          ),
          separatorColor: designVariables.icon,
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

    // Build preview text with sender name logic
    final previewText = conversation.previewText ?? '...';

    // Determine if we should show sender name:
    // - Don't show for 1:1 DMs (including self-to-self)
    // - Show "You" for self in groups/topics
    // - Show first name only for others
    final bool showSenderName;
    switch (conversation) {
      case RecentDmConversation(:final dmNarrow):
        // Don't show sender for 1:1 DMs or self-to-self
        showSenderName = dmNarrow.otherRecipientIds.length > 1;
      case RecentTopicConversation():
        showSenderName = true;
    }

    String? senderDisplayName;
    if (showSenderName && conversation.latestSenderId != 0) {
      if (conversation.latestSenderId == store.selfUserId) {
        senderDisplayName = 'You';
      } else {
        final fullName = store.userDisplayName(conversation.latestSenderId);
        // Use first name only (first word before space)
        final spaceIndex = fullName.indexOf(' ');
        senderDisplayName = spaceIndex > 0 ? fullName.substring(0, spaceIndex) : fullName;
      }
    }

    final previewStyle = TextStyle(
      fontSize: 14,
      height: 18 / 14,
      color: designVariables.labelEdited,
    );

    final Widget previewWidget;
    if (senderDisplayName != null) {
      previewWidget = Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '$senderDisplayName: ',
            style: previewStyle.copyWith(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: previewText, style: previewStyle),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      previewWidget = Text(
        previewText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: previewStyle,
      );
    }

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
                    previewWidget,
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

class _ChannelTopicTitle extends StatelessWidget {
  const _ChannelTopicTitle({
    required this.channelName,
    required this.channelColor,
    required this.topicName,
    required this.topicStyle,
    required this.separatorColor,
  });

  final String channelName;
  final Color channelColor;
  final String topicName;
  final TextStyle topicStyle;
  final Color separatorColor;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);

    final channelStyle = TextStyle(
      color: channelColor,
      fontWeight: FontWeight.w600,
      fontSize: 16,
      height: 20 / 16,
    );
    final separatorStyle = TextStyle(
      color: separatorColor,
      fontSize: 16,
      height: 20 / 16,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;

        // Measure natural widths
        final channelPainter = TextPainter(
          text: TextSpan(text: '#$channelName', style: channelStyle),
          maxLines: 1,
          textScaler: textScaler,
          textDirection: TextDirection.ltr,
        )..layout();

        final separatorPainter = TextPainter(
          text: TextSpan(text: ' > ', style: separatorStyle),
          maxLines: 1,
          textScaler: textScaler,
          textDirection: TextDirection.ltr,
        )..layout();

        final topicPainter = TextPainter(
          text: TextSpan(text: topicName, style: topicStyle),
          maxLines: 1,
          textScaler: textScaler,
          textDirection: TextDirection.ltr,
        )..layout();

        final channelNatural = channelPainter.width;
        final separatorWidth = separatorPainter.width;
        final topicNatural = topicPainter.width;

        final textSpace = available - separatorWidth;
        final totalNeeded = channelNatural + topicNatural;

        double channelMax, topicMax;

        if (totalNeeded <= textSpace) {
          // Everything fits naturally
          channelMax = channelNatural;
          topicMax = topicNatural;
        } else {
          // Need to constrain - topic gets priority (3:1 = 75%)
          final channelFloor = textSpace * 0.25;
          final topicFloor = textSpace * 0.75;

          if (channelNatural <= channelFloor) {
            // Channel is short - give rest to topic
            channelMax = channelNatural;
            topicMax = textSpace - channelNatural;
          } else if (topicNatural <= topicFloor) {
            // Topic is short - give rest to channel
            topicMax = topicNatural;
            channelMax = textSpace - topicNatural;
          } else {
            // Both need constraining - use 1:3 split
            channelMax = channelFloor;
            topicMax = topicFloor;
          }
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: channelMax),
              child: Text(
                '#$channelName',
                style: channelStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            Text(' > ', style: separatorStyle),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: topicMax),
              child: Text(
                topicName,
                style: topicStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        );
      },
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
    if (diff.inDays < 7) return intl.DateFormat.E().format(time);

    // Older: show month and day
    return intl.DateFormat.MMMd().format(time);
  }
}
