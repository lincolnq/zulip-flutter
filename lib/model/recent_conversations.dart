import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../api/core.dart';
import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/route/messages.dart';
import 'channel.dart';
import 'content_preview.dart';
import 'narrow.dart';
import 'store.dart';

/// A recent conversation (either stream topic or DM) with preview metadata.
sealed class RecentConversation {
  const RecentConversation();

  /// The narrow to navigate to when tapping this conversation.
  SendableNarrow get narrow;

  /// Latest message ID in this conversation.
  int get latestMessageId;

  /// Unix timestamp of the latest message.
  int get latestTimestamp;

  /// Plain text preview of the latest message (max ~150 chars).
  String? get previewText;

  /// Sender ID of the latest message.
  int get latestSenderId;
}

class RecentTopicConversation extends RecentConversation {
  const RecentTopicConversation({
    required this.streamId,
    required this.topic,
    required this.latestMessageId,
    required this.latestTimestamp,
    required this.previewText,
    required this.latestSenderId,
  });

  final int streamId;
  final TopicName topic;
  @override final int latestMessageId;
  @override final int latestTimestamp;
  @override final String? previewText;
  @override final int latestSenderId;

  @override
  SendableNarrow get narrow => TopicNarrow(streamId, topic);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentTopicConversation &&
          streamId == other.streamId &&
          topic.isSameAs(other.topic);

  @override
  int get hashCode => Object.hash(streamId, topic.canonicalize());
}

class RecentDmConversation extends RecentConversation {
  const RecentDmConversation({
    required this.dmNarrow,
    required this.latestMessageId,
    required this.latestTimestamp,
    required this.previewText,
    required this.latestSenderId,
  });

  final DmNarrow dmNarrow;
  @override final int latestMessageId;
  @override final int latestTimestamp;
  @override final String? previewText;
  @override final int latestSenderId;

  @override
  SendableNarrow get narrow => dmNarrow;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentDmConversation && dmNarrow == other.dmNarrow;

  @override
  int get hashCode => dmNarrow.hashCode;
}

/// A view-model for the Signal-style recent conversations UI.
///
/// This maintains a unified list of recent conversations (both DMs and topics),
/// sorted by latest message ID, plus preview text and metadata.
///
/// The list starts empty and is populated by [fetchInitial] which fetches
/// recent messages from the CombinedFeed API.
class RecentConversationsView extends PerAccountStoreBase with ChangeNotifier {
  factory RecentConversationsView({
    required CorePerAccountStore core,
  }) {
    return RecentConversationsView._(
      core: core,
      sorted: QueueList(),
      topicLatest: {},
      dmLatest: {},
      previewCache: {},
      timestampCache: {},
      senderCache: {},
    );
  }

  RecentConversationsView._({
    required super.core,
    required this.sorted,
    required Map<int, TopicKeyedMap<int>> topicLatest,
    required Map<DmNarrow, int> dmLatest,
    required Map<int, String> previewCache,
    required Map<int, int> timestampCache,
    required Map<int, int> senderCache,
  })  : _topicLatest = topicLatest,
        _dmLatest = dmLatest,
        _previewCache = previewCache,
        _timestampCache = timestampCache,
        _senderCache = senderCache;

  // Backfill state
  int? _oldestMessageIdSeen;
  bool _reachedOldest = false;
  bool _initialFetchDone = false;

  /// Whether a backfill fetch is currently in progress.
  bool isBackfilling = false;

  /// Whether all historical messages have been fetched.
  bool get hasReachedOldest => _reachedOldest;

  /// All recent conversations, sorted by latestMessageId descending.
  final QueueList<RecentConversation> sorted;

  /// Topic tracking: streamId -> topic -> latestMessageId.
  final Map<int, TopicKeyedMap<int>> _topicLatest;

  /// DM tracking: dmNarrow -> latestMessageId.
  final Map<DmNarrow, int> _dmLatest;

  /// Preview cache: messageId -> preview text.
  final Map<int, String> _previewCache;

  /// Timestamp cache: messageId -> timestamp.
  final Map<int, int> _timestampCache;

  /// Sender cache: messageId -> senderId.
  final Map<int, int> _senderCache;

  /// Insert the conversation at the proper place in [sorted].
  ///
  /// Optimized, taking O(1) time, for the case where that place is the start.
  void _insertSorted(RecentConversation conv) {
    final msgId = conv.latestMessageId;
    final i = sorted.indexWhere((c) => c.latestMessageId < msgId);
    switch (i) {
      case == 0:
        sorted.addFirst(conv);
      case < 0:
        sorted.addLast(conv);
      default:
        sorted.insert(i, conv);
    }
  }

  /// Remove a conversation from the sorted list.
  void _removeSorted(RecentConversation conv) {
    sorted.remove(conv);
  }

  /// Handle [MessageEvent], updating the conversation list and caches.
  void handleMessageEvent(MessageEvent event) {
    final message = event.message;
    final messageId = message.id;

    // Cache metadata
    _timestampCache[messageId] = message.timestamp;
    _senderCache[messageId] = message.senderId;
    _previewCache[messageId] = extractPreviewText(message.content);

    switch (message) {
      case StreamMessage():
        _handleStreamMessage(message);
      case DmMessage():
        _handleDmMessage(message);
    }

    // Evict old cache entries if needed
    _evictCacheIfNeeded();
    notifyListeners();
  }

  void _handleStreamMessage(StreamMessage message) {
    final streamId = message.streamId;
    final topic = message.topic;
    final messageId = message.id;

    final topicsMap = _topicLatest.putIfAbsent(streamId, makeTopicKeyedMap);
    final prev = topicsMap[topic];

    if (prev == null) {
      // New conversation
      topicsMap[topic] = messageId;
      final conv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(conv);
    } else if (prev >= messageId) {
      // Already have a newer message
      return;
    } else {
      // Update existing conversation
      topicsMap[topic] = messageId;

      // Remove old entry and insert updated one
      final oldConv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: prev,
        latestTimestamp: 0,
        previewText: null,
        latestSenderId: 0,
      );
      _removeSorted(oldConv);

      final newConv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(newConv);
    }
  }

  void _handleDmMessage(DmMessage message) {
    final dmNarrow = DmNarrow.ofMessage(message, selfUserId: selfUserId);
    final messageId = message.id;

    final prev = _dmLatest[dmNarrow];

    if (prev == null) {
      // New conversation
      _dmLatest[dmNarrow] = messageId;
      final conv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(conv);
    } else if (prev >= messageId) {
      // Already have a newer message
      return;
    } else {
      // Update existing conversation
      _dmLatest[dmNarrow] = messageId;

      // Remove old entry and insert updated one
      final oldConv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: prev,
        latestTimestamp: 0,
        previewText: null,
        latestSenderId: 0,
      );
      _removeSorted(oldConv);

      final newConv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(newConv);
    }
  }

  /// Handle [UpdateMessageEvent] for topic moves and content edits.
  void handleUpdateMessageEvent(UpdateMessageEvent event) {
    // Handle content edits (update preview)
    if (event.renderingOnly) return;

    final messageIds = event.messageIds;
    if (messageIds.isEmpty) return;

    // If content was edited, update preview for affected messages
    final renderedContent = event.renderedContent;
    if (renderedContent != null) {
      for (final msgId in messageIds) {
        if (_previewCache.containsKey(msgId)) {
          _previewCache[msgId] = extractPreviewText(renderedContent);
        }
      }
    }

    // Topic moves are more complex - for now, just notify listeners
    notifyListeners();
  }

  /// Handle [DeleteMessageEvent].
  void handleDeleteMessageEvent(DeleteMessageEvent event) {
    // Remove deleted message IDs from caches
    for (final msgId in event.messageIds) {
      _previewCache.remove(msgId);
      _timestampCache.remove(msgId);
      _senderCache.remove(msgId);
    }

    // For now, don't remove conversations even if their latest message is deleted.
    // The conversation will still be shown, just potentially with stale/missing preview.
    // A more complete implementation would recalculate the latest message for
    // affected conversations.

    notifyListeners();
  }

  static const _maxCacheSize = 200;

  void _evictCacheIfNeeded() {
    // Simple eviction: if cache exceeds limit, remove oldest entries
    // (oldest = those with smallest message IDs)
    if (_previewCache.length <= _maxCacheSize) return;

    final sortedIds = _previewCache.keys.toList()..sort();
    final toRemove = sortedIds.take(_previewCache.length - _maxCacheSize);
    for (final id in toRemove) {
      _previewCache.remove(id);
      _timestampCache.remove(id);
      _senderCache.remove(id);
    }
  }

  /// Fetch initial messages from the server to populate previews.
  ///
  /// Uses CombinedFeed to get recent messages, then filters locally
  /// for notification-relevant conversations (DMs, mentions, alerts, followed).
  Future<void> fetchInitial(ApiConnection connection, ChannelStore channels) async {
    if (isBackfilling || _initialFetchDone) return;
    isBackfilling = true;
    notifyListeners();

    try {
      final result = await getMessages(connection,
        narrow: const CombinedFeedNarrow().apiEncode(),
        anchor: AnchorCode.newest,
        numBefore: 100,
        numAfter: 0,
        allowEmptyTopicName: true);

      // Filter for notification-relevant messages
      final relevant = result.messages
          .where((m) => _isNotificationRelevant(m, channels))
          .toList();

      _processBackfillMessages(relevant);

      if (result.messages.isNotEmpty) {
        _oldestMessageIdSeen = result.messages.last.id;
      }
      _reachedOldest = result.foundOldest;
      _initialFetchDone = true;
    } finally {
      isBackfilling = false;
      notifyListeners();
    }
  }

  /// Fetch older messages for pagination.
  Future<void> fetchOlder(ApiConnection connection, ChannelStore channels) async {
    if (isBackfilling || _reachedOldest || _oldestMessageIdSeen == null) return;
    isBackfilling = true;
    notifyListeners();

    try {
      final result = await getMessages(connection,
        narrow: const CombinedFeedNarrow().apiEncode(),
        anchor: NumericAnchor(_oldestMessageIdSeen!),
        includeAnchor: false,
        numBefore: 100,
        numAfter: 0,
        allowEmptyTopicName: true);

      // Filter for notification-relevant messages
      final relevant = result.messages
          .where((m) => _isNotificationRelevant(m, channels))
          .toList();

      _processBackfillMessages(relevant);

      if (result.messages.isNotEmpty) {
        _oldestMessageIdSeen = result.messages.last.id;
      }
      _reachedOldest = result.foundOldest;
    } finally {
      isBackfilling = false;
      notifyListeners();
    }
  }

  /// Check if a message is notification-relevant.
  ///
  /// Returns true for:
  /// - All DM messages
  /// - Stream messages where user was @-mentioned
  /// - Stream messages with user's alert words
  /// - Stream messages in followed topics
  bool _isNotificationRelevant(Message message, ChannelStore channels) {
    // All DMs are notification-relevant
    if (message is DmMessage) return true;

    // Stream messages: check flags and followed status
    if (message is StreamMessage) {
      // @-mentioned (includes wildcard mentions)
      if (message.flags.contains(MessageFlag.mentioned) ||
          message.flags.contains(MessageFlag.wildcardMentioned)) {
        return true;
      }

      // Alert word
      if (message.flags.contains(MessageFlag.hasAlertWord)) return true;

      // Followed topic
      final policy = channels.topicVisibilityPolicy(message.streamId, message.topic);
      if (policy == UserTopicVisibilityPolicy.followed) return true;
    }

    return false;
  }

  /// Process messages from backfill, updating caches and conversation list.
  void _processBackfillMessages(List<Message> messages) {
    for (final message in messages) {
      final messageId = message.id;

      // Cache metadata
      _previewCache[messageId] = extractPreviewText(message.content);
      _timestampCache[messageId] = message.timestamp;
      _senderCache[messageId] = message.senderId;

      // Update conversation in sorted list
      switch (message) {
        case StreamMessage():
          _updateTopicFromBackfill(message);
        case DmMessage():
          _updateDmFromBackfill(message);
      }
    }

    _evictCacheIfNeeded();
  }

  void _updateTopicFromBackfill(StreamMessage message) {
    final streamId = message.streamId;
    final topic = message.topic;
    final messageId = message.id;

    final topicsMap = _topicLatest.putIfAbsent(streamId, makeTopicKeyedMap);
    final prev = topicsMap[topic];

    if (prev == null) {
      // New conversation from backfill
      topicsMap[topic] = messageId;
      final conv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(conv);
    } else if (messageId > prev) {
      // Found a newer message than what we had
      topicsMap[topic] = messageId;

      // Remove old entry and insert updated one
      final oldConv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: prev,
        latestTimestamp: 0,
        previewText: null,
        latestSenderId: 0,
      );
      _removeSorted(oldConv);

      final newConv = RecentTopicConversation(
        streamId: streamId,
        topic: topic,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(newConv);
    } else if (messageId == prev) {
      // Same message we already knew about - update with cached preview data
      // This happens when initial data had just the message ID but no content
      final index = sorted.indexWhere((c) =>
          c is RecentTopicConversation &&
          c.streamId == streamId &&
          c.topic.isSameAs(topic));
      if (index >= 0) {
        sorted[index] = RecentTopicConversation(
          streamId: streamId,
          topic: topic,
          latestMessageId: messageId,
          latestTimestamp: message.timestamp,
          previewText: _previewCache[messageId],
          latestSenderId: message.senderId,
        );
      }
    }
    // messageId < prev: older message, ignore
  }

  void _updateDmFromBackfill(DmMessage message) {
    final dmNarrow = DmNarrow.ofMessage(message, selfUserId: selfUserId);
    final messageId = message.id;

    final prev = _dmLatest[dmNarrow];

    if (prev == null) {
      // New conversation from backfill
      _dmLatest[dmNarrow] = messageId;
      final conv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(conv);
    } else if (messageId > prev) {
      // Found a newer message than what we had
      _dmLatest[dmNarrow] = messageId;

      // Remove old entry and insert updated one
      final oldConv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: prev,
        latestTimestamp: 0,
        previewText: null,
        latestSenderId: 0,
      );
      _removeSorted(oldConv);

      final newConv = RecentDmConversation(
        dmNarrow: dmNarrow,
        latestMessageId: messageId,
        latestTimestamp: message.timestamp,
        previewText: _previewCache[messageId],
        latestSenderId: message.senderId,
      );
      _insertSorted(newConv);
    } else if (messageId == prev) {
      // Same message we already knew about - update with cached preview data
      // This happens when initial data had just the message ID but no content
      final index = sorted.indexWhere((c) =>
          c is RecentDmConversation && c.dmNarrow == dmNarrow);
      if (index >= 0) {
        sorted[index] = RecentDmConversation(
          dmNarrow: dmNarrow,
          latestMessageId: messageId,
          latestTimestamp: message.timestamp,
          previewText: _previewCache[messageId],
          latestSenderId: message.senderId,
        );
      }
    }
    // messageId < prev: older message, ignore
  }
}
