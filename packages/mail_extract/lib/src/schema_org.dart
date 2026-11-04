// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// One schema.org item read from an email: its types and properties.
///
/// JSON-LD and microdata both end up in this shape, so the typed views
/// ([ParcelDeliveryInfo], [OrderInfo], [ReservationInfo]) read them
/// the same way. Type and property names have the `schema.org` prefix
/// removed (`ParcelDelivery`, `trackingNumber`). A property value is a
/// [String] or a nested [SchemaThing]; numbers and booleans become strings.
final class SchemaThing {
  SchemaThing(Iterable<String> types, Map<String, List<Object>> properties)
    : types = List.unmodifiable(types),
      properties = Map.unmodifiable({
        for (final MapEntry(:key, :value) in properties.entries)
          key: List<Object>.unmodifiable(value),
      });

  final List<String> types;
  final Map<String, List<Object>> properties;

  /// Whether this item is of [type] (`ParcelDelivery`), by its own name.
  bool isA(String type) => types.contains(type);

  /// Whether it is of any of [names].
  bool isAny(Iterable<String> names) => names.any(types.contains);

  List<Object> values(String name) => properties[name] ?? const [];

  /// The property's first text: a string value, or the `name` of an item
  /// (`"carrier": {"@type": "Organization", "name": "UPS"}` gives `UPS`).
  String? text(String name) => texts(name).firstOrNull;

  /// Every text value of the property (see [text]), trimmed, non-empty.
  List<String> texts(String name) => [
    for (final v in values(name))
      if ((v is String ? v : (v as SchemaThing).text('name'))?.trim()
          case final t? when t.isNotEmpty)
        t,
  ];

  /// The property's first item value.
  SchemaThing? thing(String name) => things(name).firstOrNull;

  List<SchemaThing> things(String name) =>
      values(name).whereType<SchemaThing>().toList();

  /// The property as a date and time (ISO 8601: `2026-11-07`,
  /// `2026-11-07T20:00:00-08:00`), or null.
  DateTime? date(String name) {
    for (final v in values(name)) {
      if (v is String) {
        if (DateTime.tryParse(v.trim()) case final d?) return d;
      }
    }
    return null;
  }

  /// The property as an `https` address, or null (other schemes are never
  /// returned: the app may offer to open it).
  Uri? httpsUrl(String name) {
    for (final v in values(name)) {
      final s = v is String ? v : (v as SchemaThing).text('url');
      final uri = s == null ? null : Uri.tryParse(s.trim());
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return uri;
      }
    }
    return null;
  }

  @override
  String toString() => '$types $properties';
}

/// Limits that keep hostile or huge mail cheap to read.
final class StructuredDataLimits {
  const StructuredDataLimits({
    this.maxSourceLength = 3000000,
    this.maxScriptLength = 512 * 1024,
    this.maxScripts = 20,
    this.maxDepth = 12,
    this.maxItems = 200,
    this.maxValues = 100,
    this.maxTextLength = 2000,
  });

  /// HTML longer than this is cut before reading.
  final int maxSourceLength;

  /// A JSON-LD script longer than this is skipped.
  final int maxScriptLength;
  final int maxScripts;

  /// Items nested deeper are left out.
  final int maxDepth;

  /// Items read in all, nested ones included.
  final int maxItems;

  /// Values kept per property.
  final int maxValues;

  /// Longer texts are cut.
  final int maxTextLength;
}

/// Reads the schema.org data in an email's HTML: JSON-LD
/// (`<script type="application/ld+json">`, one object, an array or an
/// `@graph`) and microdata (`itemscope itemtype=...` with `itemprop`
/// children).
///
/// Nothing in the mail is run: the scripts are read as JSON text, the
/// HTML is parsed into a tree and never rendered. Malformed parts are
/// skipped; this never throws.
abstract final class StructuredData {
  static final _ldScript = RegExp(
    r'''<script\b[^>]*\btype\s*=\s*["']?application/ld\+json["']?[^>]*>([\s\S]*?)</script\s*>''',
    caseSensitive: false,
  );

  /// The top-level items in [source] (an email's HTML), JSON-LD first.
  static List<SchemaThing> extract(
    String source, {
    StructuredDataLimits limits = const StructuredDataLimits(),
  }) {
    try {
      final text = source.length > limits.maxSourceLength
          ? source.substring(0, limits.maxSourceLength)
          : source;
      final budget = _Budget(limits);
      return [
        ..._jsonLd(text, budget),
        if (_hasMicrodata(text)) ..._microdata(text, budget),
      ];
    } on Object {
      return const [];
    }
  }

  // --------------------------------------------------------------- JSON-LD

  static Iterable<SchemaThing> _jsonLd(String source, _Budget budget) sync* {
    var scripts = 0;
    for (final m in _ldScript.allMatches(source)) {
      if (++scripts > budget.limits.maxScripts) return;
      final body = m[1]!;
      if (body.length > budget.limits.maxScriptLength) continue;
      final json = _decode(_unwrap(body));
      if (json == null) continue;
      final graph = <String, Map<String, Object?>>{};
      _collectIds(json, graph, 0);
      yield* _things(json, graph, budget, 0);
    }
  }

  /// The JSON inside a script: without an HTML comment or CDATA wrapper.
  static String _unwrap(String body) {
    var s = body.trim();
    for (final (open, close) in [('<!--', '-->'), ('<![CDATA[', ']]>')]) {
      if (s.startsWith(open)) s = s.substring(open.length);
      if (s.endsWith(close)) s = s.substring(0, s.length - close.length);
      s = s.trim();
    }
    return s;
  }

  /// The JSON, or null when it is not JSON even without trailing commas
  /// (some senders end the last property with one).
  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      try {
        return jsonDecode(
          text.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!),
        );
      } on FormatException {
        return null;
      }
    }
  }

  /// Items with an `@id`, so references to them can be followed.
  static void _collectIds(
    Object? json,
    Map<String, Map<String, Object?>> ids,
    int depth,
  ) {
    if (depth > 12 || ids.length > 500) return;
    if (json is List) {
      for (final v in json) {
        _collectIds(v, ids, depth + 1);
      }
    } else if (json is Map<String, Object?>) {
      if (json['@id'] case final String id when json.length > 1) {
        ids.putIfAbsent(id, () => json);
      }
      for (final v in json.values) {
        _collectIds(v, ids, depth + 1);
      }
    }
  }

  static Iterable<SchemaThing> _things(
    Object? json,
    Map<String, Map<String, Object?>> ids,
    _Budget budget,
    int depth,
  ) sync* {
    if (depth > budget.limits.maxDepth) return;
    if (json is List) {
      for (final v in json) {
        yield* _things(v, ids, budget, depth + 1);
      }
    } else if (json is Map<String, Object?>) {
      if (json['@graph'] case final Object graph) {
        yield* _things(graph, ids, budget, depth + 1);
        if (!json.containsKey('@type')) return;
      }
      if (_thing(json, ids, budget, depth, const {}) case final t?) yield t;
    }
  }

  static SchemaThing? _thing(
    Map<String, Object?> json,
    Map<String, Map<String, Object?>> ids,
    _Budget budget,
    int depth,
    Set<String> following,
  ) {
    // A bare reference: {"@id": "#order"}.
    if (json['@id'] case final String id
        when json.length == 1 && !following.contains(id)) {
      final target = ids[id];
      if (target == null) return null;
      return _thing(target, ids, budget, depth, {...following, id});
    }
    if (depth > budget.limits.maxDepth || !budget.take()) return null;
    final types = [
      for (final t in switch (json['@type']) {
        final String s => [s],
        final List<Object?> l => l.whereType<String>(),
        _ => const <String>[],
      })
        _local(t),
    ];
    final properties = <String, List<Object>>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key.startsWith('@')) continue;
      final values = <Object>[];
      for (final v in value is List ? value : [value]) {
        if (values.length >= budget.limits.maxValues) break;
        final converted = switch (v) {
          final String s => budget.cut(s),
          final num n => '$n',
          final bool b => '$b',
          final Map<String, Object?> m => _thing(
            m,
            ids,
            budget,
            depth + 1,
            following,
          ),
          _ => null,
        };
        if (converted != null) values.add(converted);
      }
      if (values.isNotEmpty) properties[_local(key)] = values;
    }
    return SchemaThing(types, properties);
  }

  /// `http://schema.org/ParcelDelivery` -> `ParcelDelivery`.
  static String _local(String name) {
    final n = name.trim();
    for (final prefix in [
      'http://schema.org/',
      'https://schema.org/',
      'schema:',
    ]) {
      if (n.toLowerCase().startsWith(prefix)) return n.substring(prefix.length);
    }
    return n;
  }

  // ------------------------------------------------------------- microdata

  static bool _hasMicrodata(String source) =>
      source.contains(RegExp('itemscope', caseSensitive: false));

  static List<SchemaThing> _microdata(String source, _Budget budget) {
    final document = html.parse(source);
    final top = <SchemaThing>[];
    void walk(dom.Element e, int depth) {
      if (depth > 200) return;
      if (_isScope(e) && !e.attributes.containsKey('itemprop')) {
        if (_scope(e, budget, 0) case final t?) top.add(t);
        return;
      }
      for (final child in e.children) {
        walk(child, depth + 1);
      }
    }

    if (document.documentElement case final root?) walk(root, 0);
    return top;
  }

  static bool _isScope(dom.Element e) => e.attributes.containsKey('itemscope');

  static SchemaThing? _scope(dom.Element scope, _Budget budget, int depth) {
    if (depth > budget.limits.maxDepth || !budget.take()) return null;
    final types = [
      for (final t in (scope.attributes['itemtype'] ?? '').split(
        RegExp(r'\s+'),
      ))
        if (t.isNotEmpty) _local(t),
    ];
    final properties = <String, List<Object>>{};
    void add(dom.Element e, Object value) {
      for (final name in (e.attributes['itemprop'] ?? '').split(
        RegExp(r'\s+'),
      )) {
        if (name.isEmpty) continue;
        final list = properties.putIfAbsent(_local(name), () => []);
        if (list.length < budget.limits.maxValues) list.add(value);
      }
    }

    void walk(dom.Element e, int level) {
      if (level > 200) return;
      for (final child in e.children) {
        final isProp = child.attributes.containsKey('itemprop');
        if (_isScope(child)) {
          if (isProp) {
            if (_scope(child, budget, depth + 1) case final t?) add(child, t);
          }
          // Its own properties belong to it, not to this item.
          continue;
        }
        if (isProp) {
          if (_value(child, budget) case final v?) add(child, v);
        }
        walk(child, level + 1);
      }
    }

    walk(scope, 0);
    properties.removeWhere((_, v) => v.isEmpty);
    return SchemaThing(types, properties);
  }

  /// A property element's value, as the microdata rules read it.
  static String? _value(dom.Element e, _Budget budget) {
    final a = e.attributes;
    final raw = switch (e.localName) {
      'meta' => a['content'],
      'a' || 'link' || 'area' => a['href'],
      'img' || 'audio' || 'video' || 'source' || 'embed' => a['src'],
      'object' => a['data'],
      'time' => a['datetime'] ?? e.text,
      'data' || 'meter' => a['value'],
      _ => a['content'] ?? e.text,
    };
    if (raw == null) return null;
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : budget.cut(text);
  }
}

/// How many items are left to read in one email.
final class _Budget {
  _Budget(this.limits) : _left = limits.maxItems;

  final StructuredDataLimits limits;
  int _left;

  bool take() => _left-- > 0;

  String cut(String s) => s.length > limits.maxTextLength
      ? s.substring(0, limits.maxTextLength)
      : s;
}
