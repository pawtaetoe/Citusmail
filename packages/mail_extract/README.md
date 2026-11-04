# mail_extract

Reads the [schema.org](https://schema.org) data that shops, carriers and
travel companies embed in the HTML of their emails, the same markup other
mail apps use for their order and booking cards. Pure Dart, entirely on
the device.

- **JSON-LD**: `<script type="application/ld+json">` holding one item, an
  array, or an `@graph` (references by `@id` are followed).
- **Microdata**: `itemscope itemtype="http://schema.org/..."` elements and
  their `itemprop` children.

Both become [`SchemaThing`](lib/src/schema_org.dart)s: a type list and a
map of property values (strings or nested items). Typed views read them:

- [`ParcelDeliveryInfo`](lib/src/orders.dart): tracking number, carrier,
  tracking page (`https` only), expected arrival, status, items shipped and
  the order (`partOfOrder`, or an `Order`'s `orderDelivery`).
- [`OrderInfo`](lib/src/orders.dart): order number, shop, items, status.

Reservations (flights, hotels, events, trains, rental cars, restaurants)
can get typed views the same way.

## Safety

The HTML must be the raw `text/html` part, before
[mail_view](../mail_view) sanitises it (it drops scripts). Nothing is run:
JSON-LD scripts are read as JSON text, and the HTML is parsed into a tree
that is never rendered. Malformed JSON is skipped; size, depth and item
limits ([`StructuredDataLimits`](lib/src/schema_org.dart)) keep huge or
hostile mail cheap to read. `extract` never throws.

```bash
dart test
```
