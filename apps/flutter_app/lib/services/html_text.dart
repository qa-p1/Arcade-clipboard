/// Renders copied HTML as plain text for the clip's preview and search (CB-7).
String htmlToPlainText(String html) {
  var text = html
      .replaceAll(
          RegExp(r'<(script|style)\b[^>]*>.*?</\1\s*>',
              caseSensitive: false, dotAll: true),
          '')
      .replaceAll(
          RegExp(r'<br\s*/?>|</(p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
          '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  return text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}
