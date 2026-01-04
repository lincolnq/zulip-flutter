# Backfill Feature for Recent Conversations

## Goal
Populate the Recent Conversations view with message content (previews) for **notification-relevant conversations only**:
- DMs (all direct messages)
- Topics where user was @-mentioned
- Topics with user's alert words
- Topics user is following

This excludes general channel messages that don't notify the user.

## Current State
- `RecentConversationsView` has preview caches but they're only populated when new `MessageEvent`s arrive
- Initial data comes from `RecentDmConversationsView` (just message IDs) and `Unreads` (just message IDs)
- No message content available at startup → empty/placeholder previews

## Approach: 4 Parallel API Calls + Merge

The Zulip API uses AND for narrow elements (not OR), so we need separate calls for each conversation type.

### Phase 1: Initial Fetch on Widget Mount
Make 4 parallel API calls when user first views the tab:
1. `getMessages(is:dm, anchor: newest, numBefore: 25, numAfter: 0)`
2. `getMessages(is:mentioned, anchor: newest, numBefore: 25, numAfter: 0)`
3. `getMessages(is:alerted, anchor: newest, numBefore: 25, numAfter: 0)`
4. `getMessages(is:followed, anchor: newest, numBefore: 25, numAfter: 0)`

Then merge results:
- Deduplicate by conversation (stream+topic or DM narrow)
- Keep the latest message per conversation
- Populate preview caches (text, timestamp, sender)
- Track `oldestMessageIdSeen` per narrow type for pagination

### Phase 2: Scroll-Triggered Backfill
When user scrolls near the bottom of the list:
1. Make 4 parallel calls with older anchors
2. Merge new conversations into list
3. Update oldest-seen trackers
4. Stop when all 4 have `foundOldest: true`

## Files to Modify

### 1. `lib/model/recent_conversations.dart`
Add:
- `_oldestDmId`, `_oldestMentionId`, `_oldestAlertId`, `_oldestFollowedId` - per-narrow pagination anchors
- `_dmReachedOldest`, `_mentionReachedOldest`, `_alertReachedOldest`, `_followedReachedOldest` - per-narrow flags
- `isBackfilling: bool` field to prevent concurrent fetches
- `bool get hasReachedOldest` - true when all 4 narrows are exhausted
- `fetchInitial(ApiConnection connection)` async method - makes 4 parallel calls
- `fetchOlder(ApiConnection connection)` async method - backfills with 4 parallel calls
- `_processMessages(List<Message> messages)` helper to update caches and list

### 2. `lib/widgets/recent_conversations_page.dart`
Add:
- Trigger `fetchInitial()` in `onNewStore()`
- Add scroll detection (similar to `MessageListView._handleScrollMetrics`)
- Call `fetchOlder()` when scrolled near bottom
- Show loading indicator while backfilling

## Implementation Details

### Fetch Initial (4 Parallel Calls)
```dart
Future<void> fetchInitial(ApiConnection connection) async {
  if (isBackfilling) return;
  isBackfilling = true;
  notifyListeners();

  try {
    final results = await Future.wait([
      getMessages(connection,
        narrow: [ApiNarrowIs(IsOperand.dm)],
        anchor: AnchorCode.newest, numBefore: 25, numAfter: 0,
        allowEmptyTopicName: true),
      getMessages(connection,
        narrow: [ApiNarrowIs(IsOperand.mentioned)],
        anchor: AnchorCode.newest, numBefore: 25, numAfter: 0,
        allowEmptyTopicName: true),
      getMessages(connection,
        narrow: [ApiNarrowIs(IsOperand.alerted)],
        anchor: AnchorCode.newest, numBefore: 25, numAfter: 0,
        allowEmptyTopicName: true),
      getMessages(connection,
        narrow: [ApiNarrowIs(IsOperand.followed)],
        anchor: AnchorCode.newest, numBefore: 25, numAfter: 0,
        allowEmptyTopicName: true),
    ]);

    // Process results and update per-narrow pagination state
    _processResult(results[0], NarrowType.dm);
    _processResult(results[1], NarrowType.mentioned);
    _processResult(results[2], NarrowType.alerted);
    _processResult(results[3], NarrowType.followed);
  } finally {
    isBackfilling = false;
    notifyListeners();
  }
}
```

### Message Processing Logic
```dart
void _processMessages(List<Message> messages) {
  for (final message in messages) {
    // Cache preview data
    _previewCache[message.id] = extractPreviewText(message.content);
    _timestampCache[message.id] = message.timestamp;
    _senderCache[message.id] = message.senderId;

    // Add/update conversation in sorted list
    switch (message) {
      case StreamMessage():
        _updateTopicConversation(message);
      case DmMessage():
        _updateDmConversation(message);
    }
  }
}
```

### Scroll Detection Pattern (from MessageListView)
```dart
void _handleScrollMetrics(ScrollMetrics metrics) {
  // Trigger backfill when near bottom
  if (metrics.extentAfter < kFetchBufferPixels) {
    model.fetchOlder(store.connection);
  }
}
```

## Key Patterns from Codebase

- **Scroll detection**: `lib/widgets/message_list.dart:989-1012` - `_handleScrollMetrics()`
- **Fetch with backoff**: `lib/model/message_list.dart:930-975` - `_fetchMore()`
- **API call**: `lib/api/route/messages.dart:38-61` - `getMessages()`
- **Anchor types**: `lib/api/route/messages.dart:63-91` - `AnchorCode.newest`, `NumericAnchor`

## Sequence

1. App starts → `RecentConversationsView` created with empty preview caches
2. User navigates to Recent Conversations tab → widget mounts
3. `onNewStore()` triggers `fetchInitial()` → 4 parallel API calls
4. Results merged → conversations discovered (DMs, mentions, alerts, followed)
5. Previews populated → UI renders with content
6. User scrolls down → `fetchOlder()` triggered → 4 more parallel calls
7. Repeat until all 4 narrows have `foundOldest = true`

## Important Notes

- **is:followed** requires server FL 265+ (Zulip Server 9.0+)
- **is:dm** requires server FL 177+ (falls back to **is:private** for older servers)
- Use `Future.wait()` to run all 4 fetches in parallel for speed
- Each narrow tracks its own pagination state independently
