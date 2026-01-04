# Signal-style Recent Conversations View

## Goal
Replace the Inbox tab with a Signal-style "Recent Conversations" view showing:
- Conversation title (stream+topic or DM participants)
- 2 lines of message preview text
- Recency indicator (e.g., "5m", "2h", "Yesterday")
- Flat list with each topic as its own row

## Implementation Overview

### New Files to Create

1. **`lib/model/recent_conversations.dart`** - Core data model
   - `RecentConversation` sealed class (topic vs DM variants)
   - `RecentConversationsView` class with sorted list + event handlers
   - Merges stream topics and DMs into unified chronological list

2. **`lib/model/content_preview.dart`** - HTML to plain text extraction
   - `extractPreviewText(String htmlContent)` function
   - Uses existing `html` package (already in pubspec)
   - Extracts ~150 chars, handles code blocks, images, etc.

3. **`lib/widgets/recent_conversations_page.dart`** - Main widget
   - `RecentConversationsPageBody` - list view with lazy loading
   - `RecentConversationItem` - individual row widget
   - `_RecencyIndicator` - relative timestamp display

### Files to Modify

1. **`lib/model/store.dart`**
   - Add `recentConversationsView` field to `PerAccountStore`
   - Initialize from initial snapshot
   - Route `MessageEvent`, `UpdateMessageEvent`, `DeleteMessageEvent` to model

2. **`lib/widgets/home.dart`** (lines 30-34, 95-100, 146-148)
   - Keep `_HomePageTab.inbox` enum value (for compatibility)
   - Replace `InboxPageBody()` with `RecentConversationsPageBody()` in pageBodies

## Model Design

```
RecentConversation (sealed)
├── RecentTopicConversation
│   - streamId, topic, latestMessageId, latestTimestamp, previewText?, senderId
└── RecentDmConversation
    - dmNarrow, latestMessageId, latestTimestamp, previewText?, senderId

RecentConversationsView
├── sorted: QueueList<RecentConversation>  (by latestMessageId desc)
├── _topicLatest: Map<(streamId, topic), int>  (message IDs)
├── _dmLatest: Map<DmNarrow, int>
├── _previewCache: Map<int, String>  (messageId -> preview text)
├── _timestampCache: Map<int, int>
├── _senderCache: Map<int, int>
├── oldestMessageIdSeen: int?  (for backfill pagination)
├── isBackfilling: bool  (prevent concurrent fetches)
└── hasReachedOldest: bool  (stop fetching when true)
```

## Data Flow

### Data Source Strategy: Hybrid Approach

**Server endpoints available:**
- **DMs**: Server provides `recentPrivateConversations` in initial snapshot (already sorted by recency)
- **Topics**: No server endpoint exists - must be assembled client-side

**Hybrid approach for topics:**
1. **Immediate**: Seed from `Unreads.streams` (topics with unread messages)
2. **Real-time**: Add new conversations as `MessageEvent`s arrive
3. **Backfill**: When user scrolls to bottom, fetch older messages via `getMessages(CombinedFeedNarrow)` to discover older read conversations

### Initialization
1. DMs: Copy from existing `RecentDmConversationsView.map` (server-provided)
2. Topics: Build initial list from `Unreads.streams` keys (topics with unreads)
3. Merge into sorted list by message ID (descending)
4. Previews: Initially null, fetched lazily as items become visible
5. Track `oldestMessageIdSeen` for backfill pagination

### Event Handling
- `MessageEvent`: Update/insert conversation, cache preview from `message.content`
- `UpdateMessageEvent`: Handle topic moves, content edits
- `DeleteMessageEvent`: Recalculate latest for affected conversation

### Backfill (Lazy Loading Older Conversations)
When user scrolls near bottom of list:
1. Call `getMessages(narrow: CombinedFeedNarrow, anchor: oldestMessageIdSeen, numBefore: 50, numAfter: 0)`
2. Extract unique (streamId, topic) pairs from results
3. Add any new conversations to the list (won't duplicate existing ones)
4. Update `oldestMessageIdSeen` for next fetch
5. Stop when `foundOldest: true` or reasonable limit reached

### Preview Fetching
1. New messages: Extract preview immediately from `MessageEvent.message.content`
2. Existing messages (on scroll): Use `getMessage()` API to fetch single message
3. Cache eviction: LRU with ~200 entry limit

## Widget Structure

```
RecentConversationsPageBody
└── ListView.builder
    └── RecentConversationItem
        ├── Row
        │   ├── Leading (channel icon or DM avatar)
        │   └── Column
        │       ├── Row (title + recency indicator)
        │       └── Text (2-line preview with sender name)
        └── onTap → MessageListPage(narrow)
```

### Title Display
- **Topic**: "#stream-name > topic" (styled with stream color)
- **DM**: "Alice, Bob" or "Alice" (single participant)

### Recency Display
- < 1 min: "Just now"
- < 60 min: "5m"
- < 24 hrs: "2h"
- Yesterday: "Yesterday"
- < 7 days: "Mon"
- Older: "Jan 5"

## Implementation Steps

### Phase 1: Core Model
1. Create `lib/model/content_preview.dart` with `extractPreviewText()`
2. Create `lib/model/recent_conversations.dart` with data classes
3. Add initialization from existing data (DMs from `RecentDmConversationsView`, topics from `Unreads`)

### Phase 2: Event Handling
1. Add `handleMessageEvent()` to update list and cache preview
2. Add `handleUpdateMessageEvent()` for moves/edits
3. Add `handleDeleteMessageEvent()` for removals

### Phase 3: Store Integration
1. Add field to `PerAccountStore`
2. Initialize in `fromInitialSnapshot()`
3. Route events in `handleEvent()`

### Phase 4: Widget
1. Create `RecentConversationsPageBody` with `PerAccountStoreAwareStateMixin`
2. Create `RecentConversationItem` with title/preview/timestamp display
3. Wire navigation to `MessageListPage`

### Phase 5: Integration
1. Update `lib/widgets/home.dart` to use new widget
2. Keep existing `inbox.dart` code unchanged (just unused)

## Key Patterns from Codebase

- Model: Follow `RecentDmConversationsView` pattern (ChangeNotifier, QueueList)
- Widget: Follow `InboxPageBody` pattern (PerAccountStoreAwareStateMixin)
- HTML parsing: Use `html` package like `lib/model/content.dart`
- Store: Follow existing event routing pattern in `store.dart:handleEvent()`
