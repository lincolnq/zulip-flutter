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
        final alt = node.attributes['alt'];
        if (alt != null && alt.isNotEmpty) {
          buffer.write('[$alt]');
        } else {
          buffer.write('[image]');
        }
        return;

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
