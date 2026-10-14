# SQLite3

The SQLite amalgamation (`sqlite3.c`, `include/sqlite3.h`), vendored verbatim from
<https://sqlite.org/download.html> so that the package's `import SQLite3` also resolves where the platform SDK
does not ship the module. macOS builds keep using the SDK's own SQLite3 and never compile this directory; the
manifest declares this target only on Windows.

SQLite is in the public domain. See `THIRD_PARTY_NOTICES.txt` at the repository root.

To update: download the newest amalgamation, replace both files, and note the version here.

Current version: 3.54.0 (`sqlite-amalgamation-3540000.zip`).
