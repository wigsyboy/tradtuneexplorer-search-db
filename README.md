# TradTuneExplorer Search Database

The **TradTuneExplorer Search Database** is a PostgreSQL analytical platform powering **TradTuneExplorer**:

https://thesession.tradtuneexplorer.com/

It combines traditional relational modelling with advanced materialized-view analytics to support high-performance exploration of traditional Irish and Scottish music.

The database powers metadata search, melody search, statistical analysis, recommendation algorithms, session analysis, and relationship discovery across tunes, recordings, artists, albums, collections, countries, members, and performances.

---

## Features

The database includes infrastructure for:

- Tune metadata management
- Recording, artist, album, collection, and member relationships
- ABC notation storage, parsing, and normalization
- Melody fingerprint generation
- Interval, contour, rhythm, and coarse-interval fingerprinting
- Exact and fuzzy melodic search
- Melody fragment search
- N-gram melody indexing
- Edit-distance melody comparison
- Melody similarity scoring
- Recording recommendation algorithms
- Tune recommendation algorithms
- Hidden gem detection and scoring
- Tune popularity analytics
- Recording popularity analytics
- Recording pathway analysis
- Artist pathway analysis
- Tune transition networks
- Recording transition networks
- Set analysis and signature generation
- Tune versatility analysis
- Influence and connector scoring
- Country popularity and similarity analysis
- Member activity analytics
- Search ranking and relevance algorithms
- High-performance analytical materialized views
- Millisecond analytical queries over hundreds of thousands of musical relationships

---

## Repository Contents

This repository contains:

- PostgreSQL schema definitions
- Functions and stored procedures
- Views
- Materialized views
- Triggers
- Indexes
- Search infrastructure
- Melody search engine
- Melody fingerprint generation
- Similarity algorithms
- Recommendation algorithms
- Statistical models
- Analytical pipelines
- Performance optimizations

---

## Architecture

TradTuneExplorer is designed as both a search engine and an analytical platform.

Extensive use of PostgreSQL materialized views allows expensive analytical computations to be pre-calculated while maintaining extremely fast query performance.

The analytical layer supports exploration of:

- Tune popularity
- Hidden gems
- Recording history
- Recording influence
- Tune influence
- Recording diversity
- Artist diversity
- Album diversity
- Tune transitions
- Recording transitions
- Artist pathways
- Tune pathways
- Session behaviour
- Set structures
- Tune versatility
- Melody similarity
- Country trends
- Member activity
- Statistical rankings
- Recommendation signals

This architecture enables complex analytical queries to execute in milliseconds while operating across hundreds of thousands of interconnected musical relationships.

---

## Melody Search

The database contains a custom melody search engine built entirely in PostgreSQL.

Features include:

- ABC normalization
- Pitch extraction
- Interval fingerprint generation
- Contour fingerprint generation
- Coarse interval abstraction
- Rhythm fingerprint generation
- Exact melody fragment search
- Fuzzy n-gram matching
- Edit-distance similarity scoring
- Multi-stage candidate ranking
- Statistical rarity weighting
- Continuity scoring
- Coverage analysis

These algorithms allow short melodic fragments to identify likely tune matches while remaining tolerant of performance variation.

---

## Materialized View Analytics

The database contains a large collection of analytical materialized views covering topics including:

- Tune metadata
- Recording metadata
- Artist metadata
- Melody fragments
- Melody n-gram indexes
- Hidden gem analytics
- Tune popularity
- Recording popularity
- Transition graphs
- Pathway graphs
- Country statistics
- Member statistics
- Recommendation signals
- Search optimisation

Materialized views are refreshed independently to support fast interactive exploration.

---

## API Endpoints & Documentation

Trad Tune Explorer exposes its database analytics, melody search engines, and set-building tools via a public JSON API.

### API Documentation & Swagger UI
Interactive documentation and Swagger UI are available at:
* **Live API Docs**: [https://thesession.tradtuneexplorer.com/api/docs/swagger-ui.html](https://thesession.tradtuneexplorer.com/api/docs/swagger-ui.html)
* **OpenAPI Specification**: You can find the OpenAPI schema definition locally inside the main web repository.

### API Servers & Base URLs
* **Public Server (Rate-limited, Free)**: `https://api.tradtuneexplorer.com/public-api`
  * *Rate limits*: Strict rate-limiting is applied (1 request/sec average, burst 3 per client IP). Exceeding this returns an HTTP `429 Too Many Requests` error.
* **Production/Internal Server**: `https://api.tradtuneexplorer.com/webhook`
  * *Usage*: Internal or authenticated endpoints used by the main application stack.

### Key Endpoint Categories
1. **Tune Explorer & Discovery**
   * `/session/analytics/tunes/forgotten-classics` - Rediscover recorded tunes that have faded from modern session repertoire.
   * `/session/analytics/tunes/hidden-gems` - Discover highly-rated tunes that are rarely played in sessions.
   * `/session/analytics/tunes/most-influential` - Combine recording footprints with session popularity.
   * `/session/analytics/tunes/most-recorded` - Rank tunes by total commercial tracks.
   * `/session/analytics/tunes/session-staples` - Real-world session popularity rankings.
2. **Melody & Audio Snippet Identification**
   * `/session/tunes/snippet/match` - Exact 2-bar melody search.
   * `/session/tunes/snippet/match/fuzzysingle` - Single 2-bar fuzzy snippet search.
   * `/session/tunes/snippet/match/fuzzy` - Multi-window fuzzy melody matching.
3. **Transition Analytics (Tune Flow)**
   * `/session/artist/pathways` - Map collaboration networks showing artist connections.
   * `/session/analytics/tunes/most-versatile` - Find tunes that transition fluidly between different keys/tunes.
4. **Member Repertoire & Practice Tools**
   * `/session/tunes/summary` - Batch tune metadata lookup.
   * `/session/collection/overlap` - Calculate Jaccard similarity and overlaps between tune collections.

For custom integrations or to request an API key with higher limits, contact `martin@tradtuneexplorer.com`.

---

## Data

This repository intentionally contains **database structure only** and does **not** include:

- Tune data
- Recording data
- Settings
- Member data
- Comments
- User data
- Exports from The Session

Users wishing to populate the database should obtain the data directly from **The Session** and comply with its licence.

---

## License and Attribution

TradTuneExplorer performs its own analytical processing over the licensed dataset.

The following are original work developed for TradTuneExplorer:

- Statistical rankings
- Hidden gem algorithms
- Melody fingerprints
- Melody similarity algorithms
- Recommendation algorithms
- Search indexes
- Transition graphs
- Pathway analysis
- Influence scoring
- Connector scoring
- Popularity models
- Analytical materialized views
- Derived statistical datasets

The underlying tune data remains subject to **The Session** licence.

The Session dataset is available at:

https://github.com/adactio/TheSession-data

License:

https://github.com/adactio/TheSession-data/blob/main/LICENSE.md

---

## Purpose

This project is intended for developers interested in:

- Traditional music search
- Music Information Retrieval (MIR)
- PostgreSQL
- Query optimisation
- Materialized view design
- Search engine implementation
- Recommendation systems
- Graph-style relationship analysis
- Statistical analytics
- Melody similarity algorithms
- Large-scale relational database design
- High-performance analytical SQL
