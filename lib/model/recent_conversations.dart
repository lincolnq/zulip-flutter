import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../api/model/events.dart';
import '../api/model/model.dart';
import 'channel.dart';
import 'content_preview.dart';
import 'narrow.dart';
import 'recent_dm_conversations.dart';
import 'store.dart';
import 'unreads.dart';

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
class RecentConversationsView extends PerAccountStoreBase with ChangeNotifier {
  factory RecentConversationsView({
    required CorePerAccountStore core,
    required RecentDmConversationsView dmView,
    required Unreads unreads,
  }) {
    final topicLatest = <int, TopicKeyedMap<int>>{};
    final dmLatest = <DmNarrow, int>{};
    final previewCache = <int, String>{};
    final timestampCache = <int, int>{};
    final senderCache = <int, int>{};

    // Copy DM data from RecentDmConversationsView
    for (final entry in dmView.map.entries) {
      dmLatest[entry.key] = entry.value;
    }

    // Build topic data from unreads
    // We only know about topics that have unreads initially
    for (final streamEntry in unreads.streams.entries) {
      final streamId = streamEntry.key;
      final topicsMap = topicLatest.putIfAbsent(streamId, makeTopicKeyedMap);
      for (final topicEntry in streamEntry.value.entries) {
        final topic = topicEntry.key;
        final messageIds = topicEntry.value;
        if (messageIds.isNotEmpty) {
          // Latest message is the last one in the sorted list
          final latestId = messageIds.reduce((a, b) => a > b ? a : b);
          topicsMap[topic] = latestId;
        }
      }
    }

    // Merge and sort
    final allEntries = <({RecentConversation conv, int messageId})>[];

    for (final streamEntry in topicLatest.entries) {
      final streamId = streamEntry.key;
      for (final topicEntry in streamEntry.value.entries) {
        final topic = topicEntry.key;
        final messageId = topicEntry.value;
        allEntries.add((
          conv: RecentTopicConversation(
            streamId: streamId,
            topic: topic,
            latestMessageId: messageId,
            latestTimestamp: timestampCache[messageId] ?? 0,
            previewText: previewCache[messageId],
            latestSenderId: senderCache[messageId] ?? 0,
          ),
          messageId: messageId,
        ));
      }
    }

    for (final entry in dmLatest.entries) {
      final dmNarrow = entry.key;
      final messageId = entry.value;
      allEntries.add((
        conv: RecentDmConversation(
          dmNarrow: dmNarrow,
          latestMessageId: messageId,
          latestTimestamp: timestampCache[messageId] ?? 0,
          previewText: previewCache[messageId],
          latestSenderId: senderCache[messageId] ?? 0,
        ),
        messageId: messageId,
      ));
    }

    // Sort by message ID descending
    allEntries.sort((a, b) => b.messageId.compareTo(a.messageId));

    return RecentConversationsView._(
      core: core,
      sorted: QueueList.from(allEntries.map((e) => e.conv)),
      topicLatest: topicLatest,
      dmLatest: dmLatest,
      previewCache: previewCache,
      timestampCache: timestampCache,
      senderCache: senderCache,
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
}
