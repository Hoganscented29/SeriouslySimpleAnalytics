# Notices and attribution

SeriouslySimpleAnalytics is Copyright 2026 Logan Besecker, licensed under the
Functional Source License 1.1 with an Apache 2.0 future licence. See
[LICENSE.md](LICENSE.md).

## Third-party data

### DB-IP IP-to-City Lite

`mix geoip.download` fetches DB-IP's IP-to-City Lite database, which is
published under [Creative Commons Attribution 4.0 International][cc-by-4].
**That licence requires attribution, and the requirement passes to you when you
run this software with that database.**

> IP geolocation data by [DB-IP](https://db-ip.com)

The dashboard displays this attribution wherever it shows location, so a default
deployment satisfies the requirement without you doing anything. If you strip
that line out, put the attribution somewhere else. If you swap in MaxMind's
GeoLite2 instead, its own terms apply and this one does not.

No database file is distributed with this repository — it is downloaded at
install time and gitignored.

[cc-by-4]: https://creativecommons.org/licenses/by/4.0/

### IANA Time Zone Database

`lib/web_analytics/geo/countries.ex` is generated from `iso3166.tab` and
`zone.tab` in the [IANA Time Zone Database][tzdb], which is in the public
domain. No attribution is required; it is recorded here because the file is
generated rather than written, and anyone regenerating it should know where it
came from.

[tzdb]: https://www.iana.org/time-zones

### MaxMind DB file format

`lib/web_analytics/geo/mmdb.ex` is an independent implementation of the
[MaxMind DB file format specification][mmdb-spec], which MaxMind publishes under
[CC BY-SA 3.0][cc-by-sa-3]. The specification is documentation; this is original
code written from it, and contains no MaxMind source. MaxMind is not affiliated
with this project and does not endorse it.

[mmdb-spec]: https://maxmind.github.io/MaxMind-DB/
[cc-by-sa-3]: https://creativecommons.org/licenses/by-sa/3.0/

## Dependencies

Runtime dependencies are listed in `mix.exs` and are, at the time of writing,
Apache 2.0 or MIT licensed. `mix.lock` pins exact versions; run
`mix deps.get && mix hex.outdated` to review them.
