import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// Extract plain text preview from HTML message content.
///
/// Returns first [maxLength] characters, stripping HTML tags,
/// collapsing whitespace, handling code blocks and images.
String extractPreviewText(String htmlContent, {int maxLength = 150}) {
  final document = parseFragment(htmlContent);
  final buffer = StringBuffer();
  _extractText(document, buffer, maxLength);

  var result = buffer.toString();

  // Collapse whitespace
  result = result.replaceAll(RegExp(r'\s+'), ' ').trim();

  // Truncate with ellipsis if needed
  if (result.length > maxLength) {
    result = '${result.substring(0, maxLength - 1)}…';
  }

  return result;
}

void _extractText(dom.Node node, StringBuffer buffer, int maxLength) {
  if (buffer.length >= maxLength) return;

  if (node is dom.Text) {
    buffer.write(node.text);
    return;
  }

  if (node is dom.Element) {
    final tagName = node.localName?.toLowerCase();

    // Handle special elements
    switch (tagName) {
      case 'img':
        // Use photo emoji for images
        buffer.write('📷');
        return;

      case 'a':
        // Check if this is a file attachment (uploaded file link)
        final href = node.attributes['href'] ?? '';
        if (href.contains('/user_uploads/') ||
            node.classes.contains('message_inline_image')) {
          // Check if it's an image by extension
          final lowerHref = href.toLowerCase();
          if (lowerHref.endsWith('.png') ||
              lowerHref.endsWith('.jpg') ||
              lowerHref.endsWith('.jpeg') ||
              lowerHref.endsWith('.gif') ||
              lowerHref.endsWith('.webp')) {
            buffer.write('📷');
          } else {
            // Other file attachment
            buffer.write('📎');
          }
          return;
        }
        // Regular link - process children normally
        break;

      case 'pre':
      case 'code':
        // For code blocks, just indicate there's code
        if (tagName == 'pre') {
          buffer.write('[code]');
          return;
        }
        // Inline code - include the text
        break;

      case 'br':
        buffer.write(' ');
        return;

      case 'p':
      case 'div':
      case 'li':
        // Add space before block elements if buffer isn't empty
        if (buffer.isNotEmpty) {
          buffer.write(' ');
        }
        break;

      case 'script':
      case 'style':
        // Skip these entirely
        return;
    }
  }

  // Recurse into children
  for (final child in node.nodes) {
    _extractText(child, buffer, maxLength);
    if (buffer.length >= maxLength) return;
  }
}
